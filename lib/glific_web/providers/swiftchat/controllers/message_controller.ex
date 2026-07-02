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

  alias Glific.{
    Communications,
    Contacts,
    Providers.Swiftchat
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
