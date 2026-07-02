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
  # you can add , log_level: :debug to the below if you want debugging info
  plug(Tesla.Middleware.Logger)
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

  @spec get_credentials(non_neg_integer()) :: {:error, String.t()} | {:ok, map()}
  defp get_credentials(org_id) do
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
end
