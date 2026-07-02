defmodule GlificWeb.Providers.Swiftchat.Controllers.MessageController do
  @moduledoc """
  Dedicated controller to handle inbound SwiftChat message-type webhooks
  (`text`, `button_response`/`multi_select_button_response`/
  `persistent_menu_response`), mirroring
  `Providers.Maytapi.Controllers.MessageController`.

  ADR-004 semantics on inbound:

  - `last_message_at` and message persistence/`bsp_status` transition to
    `:session`/`:session_and_hsm` are already handled by the shared
    `Communications.Message.receive_message/2` pipeline (a DB trigger
    sets `last_message_at` on every inbound message insert;
    `Contacts.set_session_status/2` sets `bsp_status` based on whether
    `optin_time` is present) — verified against `lib/glific/contacts.ex`
    and `priv/repo/structure.sql`, not assumed from the ADR text. No
    duplication needed here.
  - What's genuinely missing: SwiftChat has no separate opt-in webhook
    event (unlike Gupshup's `user-event/opted-in`), so implicit opt-in
    on first inbound (`optin_method: "swiftchat-link"`) must be set
    explicitly, before the shared pipeline runs, so the very first
    inbound message already lands as `:session_and_hsm` rather than
    `:session` (see `Contacts.set_session_status/2`, which reads
    `optin_time` on the contact struct passed to it).
  """

  use GlificWeb, :controller

  require Logger

  alias Glific.{
    Communications,
    Contacts,
    Providers.Swiftchat,
    Providers.Swiftchat.ApiClient
  }

  @doc false
  @spec handler(Plug.Conn.t(), map(), String.t()) :: Plug.Conn.t()
  def handler(conn, _params, _msg) do
    conn
    |> Plug.Conn.send_resp(200, "")
    |> Plug.Conn.halt()
  end

  @doc """
  Parse an inbound SwiftChat text message payload and convert it into a
  Glific message.
  """
  @spec text(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def text(conn, params) do
    organization_id = conn.assigns[:organization_id]

    params
    |> Swiftchat.Message.receive_text()
    |> maybe_opt_in(organization_id)
    |> update_message_params(organization_id)
    |> Communications.Message.receive_message()

    handler(conn, params, "text handler")
  end

  @doc """
  Parse an inbound SwiftChat `button_response` payload (the only
  interactive-reply shape implemented in T-05 — `multi_select_button_response`
  and `persistent_menu_response` are scoped to T-09).
  """
  @spec interactive(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def interactive(conn, %{"type" => "button_response"} = params) do
    organization_id = conn.assigns[:organization_id]

    params
    |> Swiftchat.Message.receive_interactive()
    |> maybe_opt_in(organization_id)
    |> update_message_params(organization_id)
    |> Communications.Message.receive_message(:quick_reply)

    handler(conn, params, "interactive handler")
  end

  # multi_select_button_response / persistent_menu_response: T-09 scope,
  # not implemented here. Ack with 200 rather than drop/crash — SwiftChat's
  # retry behavior on non-200s is undocumented.
  def interactive(conn, params), do: handler(conn, params, "interactive handler (T-09 scope)")

  @doc """
  Parse an inbound SwiftChat media message payload (`image`, `document`,
  `video`, `audio`) and convert it into a Glific message.

  The webhook payload carries only a SwiftChat media id (no URL) — this
  action resolves the id to a downloadable URL via
  `ApiClient.get_media_url/2` (`GET /bots/{Bot-ID}/media/{Media-ID}`)
  *before* calling `Swiftchat.Message.receive_media/1`, since the
  normalizer itself has no access to org credentials. See
  `Swiftchat.Message.receive_media/1`'s moduledoc for the full trade-off
  writeup on the resolved URL's ~15-minute expiry.
  """
  @spec media(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def media(conn, params) do
    organization_id = conn.assigns[:organization_id]
    type = params["type"]
    media_id = get_in(params, [type, "id"])

    resolved_url = resolve_media_url(organization_id, media_id)

    params
    |> Map.put("resolved_url", resolved_url)
    |> Swiftchat.Message.receive_media()
    |> maybe_opt_in(organization_id)
    |> update_message_params(organization_id)
    |> Communications.Message.receive_message(media_type(type))

    handler(conn, params, "media handler")
  end

  @spec media_type(String.t()) :: atom()
  defp media_type("image"), do: :image
  defp media_type("document"), do: :document
  defp media_type("video"), do: :video
  defp media_type("audio"), do: :audio
  defp media_type(_type), do: :document

  @spec resolve_media_url(non_neg_integer(), String.t() | nil) :: String.t() | nil
  defp resolve_media_url(_organization_id, nil), do: nil

  defp resolve_media_url(organization_id, media_id) do
    case ApiClient.get_media_url(organization_id, media_id) do
      {:ok, %Tesla.Env{status: status, body: body}} when status in 200..299 ->
        decoded = if is_binary(body), do: Jason.decode!(body), else: body
        decoded["url"]

      error ->
        Logger.error(
          "SwiftChat: media URL resolution failed for media_id #{media_id}, org #{organization_id} — #{Glific.SafeLog.safe_inspect(error)}"
        )

        nil
    end
  end

  @spec maybe_opt_in(map(), non_neg_integer()) :: map()
  defp maybe_opt_in(message_payload, organization_id) do
    phone = message_payload.sender.phone

    already_opted_in? =
      case Glific.Repo.get_by(Contacts.Contact, %{
             phone: phone,
             organization_id: organization_id
           }) do
        nil -> false
        contact -> not is_nil(contact.optin_time)
      end

    unless already_opted_in? do
      Contacts.contact_opted_in(
        %{phone: phone},
        organization_id,
        DateTime.utc_now(),
        method: "swiftchat-link"
      )
    end

    message_payload
  end

  @spec update_message_params(map(), non_neg_integer()) :: map()
  defp update_message_params(message_payload, organization_id) do
    message_payload
    |> Map.put(:organization_id, organization_id)
  end
end
