defmodule Glific.Providers.Swiftchat.ApiClient do
  @moduledoc """
  Https API client to interact with SwiftChat.

  SwiftChat auth is Bearer-token (unlike Gupshup's `apikey` header) and the
  request/response bodies are JSON (unlike Gupshup's form-urlencoded body).
  See `docs/prds/PRD-001-swiftchat-bsp-integration.md` §2 and
  `docs/adrs/ADR-002-swiftchat-fourth-bsp.md`.
  """
  alias Glific.Partners
  alias Tesla.Multipart
  use Gettext, backend: GlificWeb.Gettext

  # Confirmed from the official "SwiftChat Platform" Postman collection
  # (collection variable `URL`; see docs/prds/PRD-001-spike-notes.md in the
  # planning repo). Single global base URL for all merchants.
  @swiftchat_url "https://v1-api.swiftchat.ai/api"

  use Tesla
  # you can add , log_level: :debug to the below if you want debugging info.
  # filter_headers is NOT optional: without it, Tesla's debug logging prints
  # the full `authorization: Bearer <api-key>` request header into the dev
  # log (observed live 2026-07-02) — an L-003-class credential leak that
  # SafeLog can't catch because it happens inside Tesla's own middleware,
  # not in our error handling.
  plug(Tesla.Middleware.Logger, filter_headers: ["authorization"])
  plug(Tesla.Middleware.JSON)

  defmodule Error do
    @moduledoc """
    Custom error module for SwiftChat API failures.
    Reporting these failures to AppSignal lets us detect and fix issues.
    """
    defexception [:message, :status_code, :reason, :organization_id]
  end

  @doc """
  Making a Tesla GET call with the SwiftChat Bearer token in the header.
  """
  @spec swiftchat_get(String.t(), String.t()) :: Tesla.Env.result()
  def swiftchat_get(url, api_key),
    do: get(url, headers: [{"authorization", "Bearer " <> api_key}])

  @doc """
  Making a Tesla POST call with the SwiftChat Bearer token in the header.
  """
  @spec swiftchat_post(String.t(), any(), String.t()) :: Tesla.Env.result()
  def swiftchat_post(url, payload, api_key),
    do: post(url, payload, headers: [{"authorization", "Bearer " <> api_key}])

  @doc """
  Resolves the org's SwiftChat credentials for callers outside this module
  (`Swiftchat.Template`'s submit/sync/delete flows all need `merchant_id` +
  `api_key`, neither of which `send_message/2`/`get_media_url/2` expose).
  Kept as a thin public wrapper around the existing private lookup rather
  than duplicating the credential-fetch logic (PRD-002 T-02).
  """
  @spec get_credentials(non_neg_integer()) :: {:error, String.t()} | {:ok, map()}
  def get_credentials(org_id) do
    organization = Partners.organization(org_id)

    if is_nil(organization.services["bsp"]) do
      {:error, dgettext("errors", "No active BSP available")}
    else
      bsp_credentials = organization.services["bsp"]

      with false <- is_nil(bsp_credentials.secrets["api_key"]),
           false <- is_nil(bsp_credentials.secrets["bot_id"]) do
        {:ok,
         %{
           api_key: bsp_credentials.secrets["api_key"],
           bot_id: bsp_credentials.secrets["bot_id"],
           merchant_id: bsp_credentials.secrets["merchant_id"]
         }}
      else
        _ ->
          {:error,
           "Please check your credential settings and ensure you have added the API Key and Bot ID"}
      end
    end
  end

  @doc """
  Sending a message to a SwiftChat bot user.

  Path confirmed from the official Postman collection:
  `POST {URL}/bots/{Bot-ID}/messages` with Bearer `{API-Key}` auth.
  Success response is `201` with `{"id": "<uuid>"}` — the BSP message id.
  """
  @spec send_message(non_neg_integer(), map()) :: Tesla.Env.result() | {:error, String.t()}
  def send_message(org_id, payload) do
    with {:ok, credentials} <- get_credentials(org_id) do
      url = @swiftchat_url <> "/bots/" <> credentials.bot_id <> "/messages"
      swiftchat_post(url, payload, credentials.api_key)
    end
  end

  @doc """
  Resolves an inbound SwiftChat media id to a downloadable URL.

  Path confirmed from the official Postman collection:
  `GET {URL}/bots/{Bot-ID}/media/{Media-ID}` with Bearer `{API-Key}` auth,
  returning `{"url": "<presigned S3 URL>"}`. The presigned URL expires in
  ~15 minutes (`X-Amz-Expires=900`) — see
  `docs/prds/PRD-001-spike-notes.md` §4 in the planning repo. Callers must
  resolve promptly (T-08 resolves at receive time, in the controller) —
  do not cache/store this call's result for later reuse.

  **F-079 (security):** `media_id` originates from the UNSIGNED inbound
  SwiftChat webhook (`message_controller.ex:116-131` reads
  `params[type]["id"]` straight off the request body — URL-obscurity is
  the only protection, per spike-notes Q3) and is string-concatenated
  below into an authenticated GET carrying the org's live Bearer token —
  a confused-deputy/path-injection vector unique to SwiftChat (Gupshup/
  Maytapi never build outbound URLs from webhook data). `media_id` is
  therefore validated against the expected opaque-identifier shape
  (bounded-length alphanumeric/hyphen/underscore, the actual SwiftChat
  media-id shape not being documented anywhere more specifically) before
  it ever reaches the URL; anything else is rejected and safe-logged
  rather than interpolated.
  """
  @spec get_media_url(non_neg_integer(), term()) :: Tesla.Env.result() | {:error, String.t()}
  def get_media_url(org_id, media_id) do
    with {:ok, safe_media_id} <- validate_media_id(media_id, org_id),
         {:ok, credentials} <- get_credentials(org_id) do
      url = @swiftchat_url <> "/bots/" <> credentials.bot_id <> "/media/" <> safe_media_id
      swiftchat_get(url, credentials.api_key)
    end
  end

  # F-079: opaque-identifier shape — alphanumeric, hyphen, underscore only,
  # bounded length. SwiftChat's docs never pin down the exact media-id
  # format (no UUID/other pattern confirmed live), so this is a defensive
  # allowlist rather than a format we can cite chapter-and-verse for;
  # anything containing `/`, `?`, `.`, whitespace, or other URL-structural
  # characters (path traversal, query-string injection, a second host via
  # `//evil.example.com`, etc.) is rejected before it can be interpolated
  # into the authenticated GET above.
  # `\A`/`\z` (not `^`/`$`) deliberately: in PCRE (and Elixir's `Regex`,
  # which wraps PCRE), `$` matches immediately before a trailing newline,
  # so `^...$` would let a media_id like `"abc123\n"` through — `\A`/`\z`
  # anchor to the true start/end of the string with no such exception.
  @media_id_pattern ~r/\A[A-Za-z0-9_-]{1,128}\z/

  @spec validate_media_id(term(), non_neg_integer()) :: {:ok, String.t()} | {:error, String.t()}
  defp validate_media_id(media_id, org_id)
       when is_binary(media_id) do
    if Regex.match?(@media_id_pattern, media_id) do
      {:ok, media_id}
    else
      reject_media_id(media_id, org_id)
    end
  end

  defp validate_media_id(media_id, org_id), do: reject_media_id(media_id, org_id)

  @spec reject_media_id(term(), non_neg_integer()) :: {:error, String.t()}
  defp reject_media_id(media_id, org_id) do
    Glific.log_error(
      "SwiftChat: rejected non-conforming media_id before authenticated media-URL fetch, " <>
        "org #{org_id} — " <> Glific.SafeLog.safe_inspect(media_id)
    )

    {:error, "Invalid SwiftChat media id"}
  end

  @doc """
  Fetches a SwiftChat bot's configuration — the cheapest authenticated
  endpoint that validates both `api_key` and `bot_id` in a single call.

  Path confirmed live 2026-07-02 (PRD-003 F-2 / Q1):
  `GET {URL}/bots/{Bot-ID}/configuration` with Bearer `{API-Key}` auth,
  returning `200` with the bot's configuration JSON on success.

  Takes `bot_id`/`api_key` directly (not an `org_id`) because
  `Partners.credential_update_callback/3`'s `"swiftchat"` clause must
  verify the credential being saved *before* it is committed as the
  org's active BSP — `get_credentials/1` reads from the already-cached
  `organization.services["bsp"]`, which is the wrong (stale/not-yet-set)
  source at that point in the save flow. Mirrors `verify_gupshup_credentials/2`
  reading straight off `credential.secrets` rather than the org cache.
  """
  @spec get_bot_configuration(String.t(), String.t()) :: Tesla.Env.result()
  def get_bot_configuration(bot_id, api_key) do
    url = @swiftchat_url <> "/bots/" <> bot_id <> "/configuration"
    swiftchat_get(url, api_key)
  end

  @doc """
  Creates (submits for approval) a SwiftChat template.

  Path confirmed from the official Postman collection / PRD-001 spike notes
  ("Bonus findings" -> Templates):
  `POST {URL}/merchants/{Merchant-ID}/templates` with Bearer `{API-Key}`
  auth. Success is `201 Created`; the response body is not confirmed to be
  JSON on a live call (may be the literal non-JSON string `"Created"`) — see
  `Swiftchat.Template.submit_for_approval/1`, which handles both shapes.
  """
  @spec create_template(non_neg_integer(), map()) :: Tesla.Env.result() | {:error, String.t()}
  def create_template(org_id, payload) do
    with {:ok, credentials} <- get_credentials(org_id) do
      url = @swiftchat_url <> "/merchants/" <> credentials.merchant_id <> "/templates"
      swiftchat_post(url, payload, credentials.api_key)
    end
  end

  @doc """
  Lists all templates for the org's SwiftChat merchant.

  Path confirmed: `GET {URL}/merchants/{Merchant-ID}/templates` with Bearer
  `{API-Key}` auth. See `Swiftchat.Template`'s poll-sync
  (`update_hsm_templates/1`, PRD-002 T-03/T-04) for response-shape handling
  (the confirmed sample nests `data` one level deeper than expected).
  """
  @spec list_templates(non_neg_integer()) :: Tesla.Env.result() | {:error, String.t()}
  def list_templates(org_id) do
    with {:ok, credentials} <- get_credentials(org_id) do
      url = @swiftchat_url <> "/merchants/" <> credentials.merchant_id <> "/templates"
      swiftchat_get(url, credentials.api_key)
    end
  end

  @doc """
  Fetches a single SwiftChat template by name (F-114).

  Path confirmed live: `GET {URL}/merchants/{Merchant-ID}/templates/{Template-Name}`
  with Bearer `{API-Key}` auth, returning `200` with
  `{"template": {"type": "text", "text": {"body": "..."}}, "status": "...",
  "status_reason": ..., "created_at": "..."}`.

  Unlike `list_templates/1` — whose LIST response was live-verified (F-114)
  to carry ONLY `name`/`type`/`status`/`created_at`/`status_reason`, no
  `body` — this single-template call is what actually returns the body.
  `Swiftchat.Template.import_dashboard_template/3` (T-04 pull-sync) calls
  this for every dashboard-created template not yet known to Glific, since
  the LIST pass alone cannot build a valid `SessionTemplate` (a text
  template with no body fails `SessionTemplate.changeset/2`'s
  `validate_body/2`).

  `template_name` is validated against SwiftChat's documented name charset
  (`[a-z0-9_]{1,50}`, `\\A`/`\\z`-anchored per L-027) before being
  interpolated into the URL — same defensive-boundary discipline as
  `get_media_url/2`'s media-id segment (L-024); template names here
  originate from SwiftChat's own list response rather than an unsigned
  webhook, but validating before building an authenticated URL costs
  nothing and closes off the same vector class regardless of source.
  """
  @spec get_template(non_neg_integer(), String.t()) :: Tesla.Env.result() | {:error, String.t()}
  def get_template(org_id, template_name) do
    with {:ok, safe_name} <- validate_template_name(template_name),
         {:ok, credentials} <- get_credentials(org_id) do
      url =
        @swiftchat_url <>
          "/merchants/" <>
          credentials.merchant_id <>
          "/templates/" <>
          safe_name

      swiftchat_get(url, credentials.api_key)
    end
  end

  # SwiftChat template-name constraint per the official docs: [a-z0-9_]{1,50}.
  # `\A`/`\z` (not `^`/`$`) per L-027 — in PCRE, `$` matches immediately
  # before a trailing newline, so `^...$` would let e.g. "abc\n" through.
  @template_name_pattern ~r/\A[a-z0-9_]{1,50}\z/

  @spec validate_template_name(term()) :: {:ok, String.t()} | {:error, String.t()}
  defp validate_template_name(name) when is_binary(name) do
    if Regex.match?(@template_name_pattern, name) do
      {:ok, name}
    else
      reject_template_name(name)
    end
  end

  defp validate_template_name(name), do: reject_template_name(name)

  @spec reject_template_name(term()) :: {:error, String.t()}
  defp reject_template_name(name) do
    Glific.log_error(
      "SwiftChat: rejected non-conforming template name before single-template GET — " <>
        Glific.SafeLog.safe_inspect(name)
    )

    {:error, "Invalid SwiftChat template name"}
  end

  @doc """
  Deletes a SwiftChat template by name.

  Path confirmed: `DELETE {URL}/merchants/{Merchant-ID}/templates/{Template-Name}`
  with Bearer `{API-Key}` auth. `template_name` is the value stored in
  `SessionTemplate.bsp_id` (SwiftChat templates are keyed by name, not a
  numeric id).
  """
  @spec delete_template(non_neg_integer(), String.t()) ::
          Tesla.Env.result() | {:error, String.t()}
  def delete_template(org_id, template_name) do
    with {:ok, credentials} <- get_credentials(org_id) do
      url =
        @swiftchat_url <>
          "/merchants/" <>
          credentials.merchant_id <>
          "/templates/" <>
          template_name

      delete(url, headers: [{"authorization", "Bearer " <> credentials.api_key}])
    end
  end

  # 64 MB, confirmed max media size (`docs/prds/PRD-001-spike-notes.md` §4,
  # ADR-006). `Swiftchat.Message.check_media_size/2` enforces this for the
  # already-implemented URL-pass-through send path via a HEAD-equivalent
  # Content-Length check (there is no local copy of the bytes to measure
  # there); here we already hold the full content in memory (T22's resolver
  # downloads it once to compute the content-sha256 key), so the cap is
  # enforced directly against `byte_size/1` instead of re-issuing a network
  # request — same limit, same ADR-006 "fail fast at enqueue" contract,
  # cheaper check for this call shape.
  @max_upload_bytes 64 * 1024 * 1024

  @doc """
  Uploads media to SwiftChat's Media API (ADR-017 T21).

  Path confirmed from the official Postman collection (`Media > Upload-Media`):
  `POST {URL}/bots/{Bot-ID}/media` with Bearer `{API-Key}` auth, multipart
  body: field `type` (the MIME type string) + field `file` (the raw bytes).
  Success is `201` with `{"id": "<21-char url-safe token>"}` — confirmed
  live via the D3 probe (`docs/adrs/ADR-017-swiftchat-media-asset-registry.md`
  Audit table, 2026-08-13): ids are unique per upload with **no server-side
  dedup** (re-uploading identical bytes returns a DIFFERENT id), which is
  exactly why the registry keys on content hash rather than trusting the
  provider to dedup for us.

  The returned id is provider-internal state (ADR-006/ADR-017) — this
  function is the only place in Glific that produces one; callers outside
  `Glific.Providers.Swiftchat.*` must never see it (the registry, not the
  raw id, is what crosses that boundary).
  """
  @spec upload_media(non_neg_integer(), binary(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def upload_media(org_id, file_content, content_type)
      when is_binary(file_content) and is_binary(content_type) do
    if byte_size(file_content) > @max_upload_bytes do
      {:error,
       "Media size exceeds the 64 MB SwiftChat limit (#{byte_size(file_content)} bytes) — upload rejected"}
    else
      do_upload_media(org_id, file_content, content_type)
    end
  end

  @spec do_upload_media(non_neg_integer(), binary(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp do_upload_media(org_id, file_content, content_type) do
    with {:ok, credentials} <- get_credentials(org_id) do
      url = @swiftchat_url <> "/bots/" <> credentials.bot_id <> "/media"

      multipart =
        Multipart.new()
        |> Multipart.add_field("type", content_type)
        |> Multipart.add_file_content(file_content, "upload",
          name: "file",
          headers: [{"content-type", content_type}]
        )

      url
      |> post(multipart, headers: [{"authorization", "Bearer " <> credentials.api_key}])
      |> handle_upload_response(org_id)
    end
  end

  @spec handle_upload_response(Tesla.Env.result(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp handle_upload_response({:ok, %Tesla.Env{status: status, body: body}}, org_id)
       when status in 200..299 do
    case decode_media_id(body) do
      {:ok, id} ->
        {:ok, id}

      :error ->
        Glific.log_error(
          "SwiftChat: Upload-Media returned #{status} with an unexpected body shape, org #{org_id}"
        )

        {:error, "SwiftChat media upload returned an unexpected response"}
    end
  end

  defp handle_upload_response({:ok, env}, org_id) do
    Glific.log_error(
      "SwiftChat: Upload-Media failed for org #{org_id} — " <> Glific.SafeLog.safe_inspect(env)
    )

    {:error, "SwiftChat media upload failed"}
  end

  defp handle_upload_response({:error, reason}, org_id) do
    Glific.log_error(
      "SwiftChat: Upload-Media request error for org #{org_id} — " <>
        Glific.SafeLog.safe_inspect(reason)
    )

    {:error, "SwiftChat media upload failed"}
  end

  # Response bodies come back as raw JSON strings, not pre-decoded maps —
  # `Tesla.Middleware.JSON` only decodes when the response carries a
  # `content-type: application/json` header, which `Tesla.Mock`'s
  # `%Tesla.Env{}` fixtures (and, per the T-08 test above, live SwiftChat
  # responses observed so far) don't reliably set. Handles both shapes
  # defensively rather than assuming one.
  @spec decode_media_id(term()) :: {:ok, String.t()} | :error
  defp decode_media_id(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decode_media_id(decoded)
      {:error, _reason} -> :error
    end
  end

  defp decode_media_id(%{"id" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp decode_media_id(_body), do: :error

  @doc """
  Deletes an uploaded media asset from SwiftChat (ADR-017 T21).

  Path confirmed: `DELETE {URL}/bots/{Bot-ID}/media/{Media-ID}` with Bearer
  `{API-Key}` auth. Confirmed live via the D3 probe (ADR-017 Audit table,
  2026-08-13): the call returns `200`, but deletion is **soft/lazy** — the
  id still resolves immediately after the delete call. Treat this as
  best-effort cleanup, not a synchronous guarantee the id stops working
  (ADR-017's registry-invalidation path does not depend on this call
  succeeding or on the delete actually taking effect).

  `media_id` is validated with the SAME F-079 opaque-identifier allowlist
  `get_media_url/2` uses (`validate_media_id/2`) before it is interpolated
  into the URL — this id is expected to originate from our own registry
  (T20/T22), not an unsigned webhook, but reusing one shape contract for
  every place a SwiftChat media id reaches a URL costs nothing and closes
  off a second path to the same F-079 vector class if a future caller ever
  passes an externally-sourced id here.
  """
  @spec delete_media(non_neg_integer(), term()) :: Tesla.Env.result() | {:error, String.t()}
  def delete_media(org_id, media_id) do
    with {:ok, safe_media_id} <- validate_media_id(media_id, org_id),
         {:ok, credentials} <- get_credentials(org_id) do
      url = @swiftchat_url <> "/bots/" <> credentials.bot_id <> "/media/" <> safe_media_id
      delete(url, headers: [{"authorization", "Bearer " <> credentials.api_key}])
    end
  end
end
