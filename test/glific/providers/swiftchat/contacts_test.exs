defmodule Glific.Providers.SwiftchatContactsTest do
  @moduledoc """
  Covers the live bug fix: a flow's `optin` action
  (`Glific.Flows.ContactAction.optin/2`) calls `Contacts.optin_contact/1`,
  which dispatches to `Provider.bsp_module(org_id, :contact)` — before
  this module existed, a swiftchat-BSP org raised
  `"swiftchat Provider Not found."`.
  """
  use Glific.DataCase, async: false

  alias Glific.{
    Contacts.Contact,
    Fixtures,
    Partners,
    Partners.Provider,
    Providers.SwiftchatContacts,
    Repo
  }

  setup %{organization_id: organization_id} = attrs do
    {:ok, swiftchat_provider} = Repo.fetch_by(Provider, %{shortcode: "swiftchat"})

    organization = Partners.get_organization!(organization_id)
    Partners.update_organization(organization, %{bsp_id: swiftchat_provider.id})

    organization = Partners.get_organization!(organization_id)
    Partners.remove_organization_cache(organization.id, organization.shortcode)
    Partners.fill_cache(organization)

    attrs
  end

  describe "optin_contact/1" do
    test "opts in a contact purely locally, defaulting optin_method to swiftchat-link",
         %{organization_id: organization_id} = attrs do
      contact = Fixtures.contact_fixture(attrs)

      assert {:ok, updated_contact} =
               SwiftchatContacts.optin_contact(%{
                 phone: contact.phone,
                 organization_id: organization_id
               })

      assert %Contact{} = updated_contact
      assert updated_contact.optin_status == true
      assert updated_contact.optin_method == "swiftchat-link"
      refute is_nil(updated_contact.optin_time)
    end

    test "honors an explicit :method override", %{organization_id: organization_id} = attrs do
      contact = Fixtures.contact_fixture(attrs)

      assert {:ok, updated_contact} =
               SwiftchatContacts.optin_contact(%{
                 phone: contact.phone,
                 organization_id: organization_id,
                 method: "flow"
               })

      assert updated_contact.optin_method == "flow"
    end

    test "creates a new contact when phone is not already known",
         %{organization_id: organization_id} do
      phone = "919900#{System.unique_integer([:positive])}"

      assert {:ok, contact} =
               SwiftchatContacts.optin_contact(%{
                 phone: phone,
                 organization_id: organization_id
               })

      assert contact.phone == phone
      assert contact.optin_status == true
    end
  end

  describe "Provider.bsp_module(org_id, :contact) resolution" do
    test "resolves to Glific.Providers.SwiftchatContacts for a swiftchat-BSP org",
         %{organization_id: organization_id} do
      assert Provider.bsp_module(organization_id, :contact) == Glific.Providers.SwiftchatContacts
    end
  end

  describe "Contacts.optin_contact/1 end-to-end via the flow optin action's dispatch path" do
    test "no longer raises 'swiftchat Provider Not found.' (regression test for the live bug)",
         %{organization_id: organization_id} = attrs do
      contact = Fixtures.contact_fixture(attrs)

      assert {:ok, %Contact{} = updated_contact} =
               Glific.Contacts.optin_contact(%{
                 phone: contact.phone,
                 organization_id: organization_id
               })

      assert updated_contact.optin_status == true
    end
  end
end
