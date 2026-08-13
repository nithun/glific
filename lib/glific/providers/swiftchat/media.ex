defmodule Glific.Providers.Swiftchat.Media do
  @moduledoc """
  Provider-side URL -> media-id resolution for SwiftChat
  (`docs/adrs/ADR-017-swiftchat-media-asset-registry.md`, PRD-005 T22).

  This is the ONLY module allowed to hold a raw SwiftChat media id past the
  point it's returned from `ApiClient.upload_media/3` — everything above
  `Glific.Providers.Swiftchat.*` continues to speak public URLs (ADR-006).
  Callers (media HSM templates and card/article image headers, arriving in
  PRD-005 Phases 3/5) resolve a `source_url` to a media id via
  `resolve_media_id/4`, use the id to build their SwiftChat send payload,
  and — if the send comes back with the provider's "invalid media id"
  error — call back through `send_with_media_id/4`'s self-healing hook
  rather than handling invalidation themselves.

  No live caller exists yet (Phases 3/5 ship the actual template/card
  sends); this module builds and tests the seam in isolation.
  """

  alias Glific.{
    Providers.MediaAssets,
    Providers.Swiftchat.ApiClient
  }

  @provider "swiftchat"

  # Cross-referenced with `Swiftchat.Message`'s identical `@max_media_bytes`
  # and `ApiClient`'s identical `@max_upload_bytes` (ADR-006, confirmed
  # `docs/prds/PRD-001-spike-notes.md` §4) — kept as its own module
  # attribute rather than a shared import so this module has no compile-time
  # dependency on `Swiftchat.Message`'s internals.
  @max_media_bytes 64 * 1024 * 1024

  @typedoc "A send attempt against SwiftChat, parameterized by the media id it embedded."
  @type send_fn :: (String.t() -> {:ok, term()} | {:error, term()})

  @doc """
  Resolves a public media URL to a SwiftChat media id, per ADR-017:

    1. Fetches the media bytes and computes their content identity
       (SHA-256) — this single download doubles as the 64 MB size check
       (ADR-006), rather than issuing a separate HEAD request.
    2. Looks up the registry for `(organization_id, "swiftchat", source_url,
       content_sha256)`.
    3. On a cache hit (and `force_reupload: false`), returns the cached id.
    4. On a cache miss (or `force_reupload: true`), uploads via
       `ApiClient.upload_media/3`, stores the mapping, and returns the new
       id.

  `force_reupload` (default `false`) is the **structural** retry-once bound
  for the self-healing path (see `send_with_media_id/4`): passing `true`
  unconditionally invalidates any existing mapping and re-uploads — this
  function never sets `force_reupload: true` on itself, so there is no
  internal recursion for this to loop on. The caller (currently only
  `send_with_media_id/4`) is what bounds the retry to exactly one call.
  """
  @spec resolve_media_id(non_neg_integer(), String.t(), String.t(), boolean()) ::
          {:ok, String.t()} | {:error, String.t()}
  def resolve_media_id(organization_id, source_url, content_type, force_reupload \\ false)

  def resolve_media_id(organization_id, source_url, content_type, force_reupload) do
    with {:ok, %{content: content, content_sha256: content_sha256}} <-
           fetch_content(source_url) do
      if force_reupload do
        :ok = MediaAssets.invalidate(@provider, source_url, content_sha256)
        upload_and_cache(organization_id, source_url, content_type, content, content_sha256)
      else
        case MediaAssets.fetch_by_content(@provider, source_url, content_sha256) do
          {:ok, asset} ->
            {:ok, asset.provider_media_id}

          {:error, _reason} ->
            upload_and_cache(organization_id, source_url, content_type, content, content_sha256)
        end
      end
    end
  end

  @doc """
  The self-healing hook point Phases 3/5's real send builders will call
  once they exist (ADR-017 Consequences): resolves a media id, calls the
  caller-supplied `send_fn` with it, and — if `send_fn` reports SwiftChat's
  "invalid media id" error (`%{"code" => 4}}`, per the official error
  table) — invalidates the cached mapping, re-uploads **exactly once**, and
  retries `send_fn` a second and final time. Whatever that second attempt
  returns (success OR another code-4 error) is returned as-is; there is no
  further retry, so a persistently-broken send cannot loop (GL-002).

  If the initial `resolve_media_id/4` call itself fails (fetch/upload
  error), `send_fn` is never invoked.
  """
  @spec send_with_media_id(non_neg_integer(), String.t(), String.t(), send_fn()) ::
          {:ok, term()} | {:error, term()} | {:error, String.t()}
  def send_with_media_id(organization_id, source_url, content_type, send_fn)
      when is_function(send_fn, 1) do
    with {:ok, media_id} <- resolve_media_id(organization_id, source_url, content_type) do
      case send_fn.(media_id) do
        {:error, %{"code" => 4}} ->
          retry_after_invalidation(organization_id, source_url, content_type, send_fn)

        result ->
          result
      end
    end
  end

  @spec retry_after_invalidation(non_neg_integer(), String.t(), String.t(), send_fn()) ::
          {:ok, term()} | {:error, term()} | {:error, String.t()}
  defp retry_after_invalidation(organization_id, source_url, content_type, send_fn) do
    Glific.log_error(
      "SwiftChat: media id for #{source_url} rejected as invalid (code 4) by org #{organization_id} — invalidating and re-uploading once"
    )

    case resolve_media_id(organization_id, source_url, content_type, true) do
      {:ok, media_id} -> send_fn.(media_id)
      {:error, _reason} = error -> error
    end
  end

  @spec upload_and_cache(non_neg_integer(), String.t(), String.t(), binary(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp upload_and_cache(organization_id, source_url, content_type, content, content_sha256) do
    with {:ok, provider_media_id} <-
           ApiClient.upload_media(organization_id, content, content_type),
         {:ok, _asset} <-
           MediaAssets.put_asset(%{
             organization_id: organization_id,
             provider: @provider,
             source_url: source_url,
             content_sha256: content_sha256,
             provider_media_id: provider_media_id,
             content_type: content_type
           }) do
      {:ok, provider_media_id}
    else
      {:error, %Ecto.Changeset{}} ->
        {:error, "SwiftChat media upload succeeded but the registry mapping could not be saved"}

      {:error, _reason} = error ->
        error
    end
  end

  @spec fetch_content(String.t()) ::
          {:ok, %{content: binary(), content_sha256: String.t()}} | {:error, String.t()}
  defp fetch_content(source_url) do
    case Tesla.get(source_url, opts: [adapter: [recv_timeout: 30_000]]) do
      {:ok, %Tesla.Env{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        validate_content_size(body)

      {:ok, env} ->
        Glific.log_error(
          "SwiftChat: could not fetch media for upload resolution, #{source_url} — " <>
            Glific.SafeLog.safe_inspect(env)
        )

        {:error, "Could not fetch media for SwiftChat upload"}

      {:error, reason} ->
        Glific.log_error(
          "SwiftChat: media fetch error during upload resolution, #{source_url} — " <>
            Glific.SafeLog.safe_inspect(reason)
        )

        {:error, "Could not fetch media for SwiftChat upload"}
    end
  end

  @spec validate_content_size(binary()) ::
          {:ok, %{content: binary(), content_sha256: String.t()}} | {:error, String.t()}
  defp validate_content_size(content) do
    if byte_size(content) > @max_media_bytes do
      {:error,
       "Media size exceeds the 64 MB SwiftChat limit (#{byte_size(content)} bytes) — upload rejected"}
    else
      {:ok, %{content: content, content_sha256: sha256_hex(content)}}
    end
  end

  @spec sha256_hex(binary()) :: String.t()
  defp sha256_hex(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
