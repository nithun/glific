defmodule Glific.Providers.SwiftchatContacts do
  @moduledoc """
  Contacts API layer between application and SwiftChat.

  Per ADR-004 ("SwiftChat session-window and opt-in model"), SwiftChat has
  no BSP-side opt-in registry or consent API — a contact's first inbound
  message is itself the opt-in (`optin_method: "swiftchat-link"`, see
  `GlificWeb.Providers.Swiftchat.Controllers.MessageController.maybe_opt_in/2`,
  which already sets this on the inbound webhook path directly).

  This module exists for the **other** opt-in entry point: a flow's
  `optin` action (`Glific.Flows.ContactAction.optin/2`) calls
  `Glific.Contacts.optin_contact/1`, which dispatches to
  `Glific.Partners.Provider.bsp_module(org_id, :contact)` — before this
  module existed, that dispatch had no `"swiftchat"` clause and raised
  `"swiftchat Provider Not found."` (live bug: a user tapped a button
  whose flow's next node was an `optin` action).

  Mirroring `Glific.Providers.GupshupContacts.optin_contact/1` exactly:
  that function is **already 100% local** — `Contacts.contact_opted_in/4`
  is a DB-only operation (create/update the contact row, set
  `optin_time`/`optin_status`/`optin_method`, flip `bsp_status` via
  `set_session_status/2`, write a `ContactHistory` row) with no BSP HTTP
  call anywhere in its call chain. So the "local side of what Gupshup's
  does" *is* the whole of what Gupshup's does — there is no remote call to
  omit. The only SwiftChat-specific difference is the default
  `optin_method`, set to `"swiftchat-link"` (matching the inbound webhook
  path's convention) instead of Gupshup's default `"BSP"`, since there is
  no actual BSP-initiated opt-in event for SwiftChat.
  """

  @behaviour Glific.Providers.ContactBehaviour

  alias Glific.{
    Contacts,
    Contacts.Contact
  }

  @doc """
  Update a contact phone as opted in.

  Purely local (no BSP API call) per ADR-004 — SwiftChat opt-in is
  implicit, there is no remote opt-in endpoint to call.
  """
  @spec optin_contact(map()) ::
          {:ok, Contact.t()} | {:error, Ecto.Changeset.t()} | {:error, list()}
  def optin_contact(%{organization_id: organization_id} = attrs) do
    Contacts.contact_opted_in(
      attrs,
      organization_id,
      attrs[:optin_time] || DateTime.utc_now(),
      method: attrs[:method] || "swiftchat-link"
    )
  end
end
