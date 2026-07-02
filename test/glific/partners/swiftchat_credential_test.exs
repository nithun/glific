defmodule Glific.Partners.SwiftchatCredentialTest do
  @moduledoc """
  Covers the Q4 gap: `Glific.Partners.credential_update_callback/3` had no
  `"swiftchat"` clause, so updating/activating a SwiftChat credential never
  set `organization.bsp_id` — the org never became selectable end-to-end
  through Settings -> Integrations even with valid secrets saved.
  """
  use Glific.DataCase, async: false

  alias Glific.{
    Partners,
    Partners.Credential,
    Partners.Provider,
    Repo
  }

  describe "credential_update_callback/3 \"swiftchat\" clause" do
    test "sets organization.bsp_id when secrets are complete",
         %{organization_id: organization_id} = _attrs do
      {:ok, provider} = Repo.fetch_by(Provider, %{shortcode: "swiftchat"})

      {:ok, credential} =
        Partners.create_credential(%{
          organization_id: organization_id,
          shortcode: "swiftchat",
          keys: %{},
          secrets: %{
            "api_key" => "test_api_key",
            "bot_id" => "test_bot_id",
            "merchant_id" => "test_merchant_id"
          }
        })

      valid_update_attrs = %{
        keys: %{},
        shortcode: "swiftchat",
        secrets: %{
          "api_key" => "updated_api_key",
          "bot_id" => "updated_bot_id",
          "merchant_id" => "updated_merchant_id"
        },
        organization_id: organization_id
      }

      assert {:ok, %Credential{} = updated_credential} =
               Partners.update_credential(credential, valid_update_attrs)

      assert updated_credential.secrets["api_key"] == "updated_api_key"

      organization = Partners.get_organization!(organization_id)
      assert organization.bsp_id == provider.id
    end

    test "does not set organization.bsp_id when secrets are incomplete",
         %{organization_id: organization_id} = _attrs do
      {:ok, credential} =
        Partners.create_credential(%{
          organization_id: organization_id,
          shortcode: "swiftchat",
          keys: %{},
          secrets: %{
            "api_key" => "test_api_key"
            # bot_id / merchant_id missing -> validate_secrets?/2 is false
          }
        })

      organization_before = Partners.get_organization!(organization_id)

      valid_update_attrs = %{
        keys: %{},
        shortcode: "swiftchat",
        secrets: %{"api_key" => "test_api_key"},
        organization_id: organization_id
      }

      assert {:ok, %Credential{}} = Partners.update_credential(credential, valid_update_attrs)

      organization_after = Partners.get_organization!(organization_id)
      assert organization_after.bsp_id == organization_before.bsp_id
    end
  end
end
