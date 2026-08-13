defmodule Glific.Providers.Swiftchat.ApiClient do
  @moduledoc """
  Https API client to interact with SwiftChat.

  SwiftChat auth is Bearer-token (unlike Gupshup's `apikey` header) and the
  request/response bodies are JSON (unlike Gupshup's form-urlencoded body).
  See `docs/prds/PRD-001-swiftchat-bsp-integration.md` §2 and
  `docs/adrs/ADR-002-swiftchat-fourth-bsp.md`.
  """
  alias Glific.Partners
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
end
