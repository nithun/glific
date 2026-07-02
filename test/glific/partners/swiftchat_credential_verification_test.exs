defmodule Glific.Partners.SwiftchatCredentialVerificationTest do
  @moduledoc """
  PRD-003 F-2: live credential-verification ping in
  `Glific.Partners.credential_update_callback/3`'s `"swiftchat"` clause.

  Covers `Glific.Partners.verify_swiftchat_credentials/1` directly, plus
  the end-to-end `Partners.update_credential/2` path for each mapped error
  (all confirmed live 2026-07-02, PRD-003 audit row):

    - 401 / code 110 -> "Invalid API key"
    - 400 / code 2   -> "Invalid Bot ID"
    - 403 / code 108 -> SwiftChat account inactive
    - network/transport failure -> can't-reach message

  Also asserts `organization.bsp_id` is left unset on every failure path,
  and that the api_key never appears in the returned error string
  (L-003/L-011).
  """
  use Glific.DataCase, async: false

  alias Glific.{
    Partners,
    Partners.Credential,
    Partners.Provider,
    Repo
  }

  setup %{organization_id: organization_id} = attrs do
    {:ok, credential} =
      Partners.create_credential(%{
        organization_id: organization_id,
        shortcode: "swiftchat",
        keys: %{},
        secrets: %{
          "api_key" => "super-secret-api-key",
          "bot_id" => "test_bot_id",
          "merchant_id" => "test_merchant_id"
        }
      })

    Map.put(attrs, :credential, credential)
  end

  defp update_attrs(organization_id, secrets_overrides \\ %{}) do
    %{
      keys: %{},
      shortcode: "swiftchat",
      secrets:
        Map.merge(
          %{
            "api_key" => "super-secret-api-key",
            "bot_id" => "test_bot_id",
            "merchant_id" => "test_merchant_id"
          },
          secrets_overrides
        ),
      organization_id: organization_id
    }
  end

  describe "verify_swiftchat_credentials/1 (unit)" do
    test "returns {:ok, body} on a 200", %{credential: credential} do
      Tesla.Mock.mock(fn %{method: :get} ->
        %Tesla.Env{status: 200, body: %{"bot_id" => "test_bot_id"}}
      end)

      assert {:ok, _body} = Partners.verify_swiftchat_credentials(credential)
    end

    test "maps 401/code 110 to an invalid-API-key error", %{credential: credential} do
      Tesla.Mock.mock(fn %{method: :get} ->
        %Tesla.Env{status: 401, body: %{"code" => 110}}
      end)

      assert {:error, message} = Partners.verify_swiftchat_credentials(credential)
      assert message == "Invalid API key"
      refute message =~ credential.secrets["api_key"]
    end

    test "maps 400/code 2 to an invalid-Bot-ID error", %{credential: credential} do
      Tesla.Mock.mock(fn %{method: :get} ->
        %Tesla.Env{status: 400, body: %{"code" => 2}}
      end)

      assert {:error, message} = Partners.verify_swiftchat_credentials(credential)
      assert message == "Invalid Bot ID"
      refute message =~ credential.secrets["api_key"]
    end

    test "maps 403/code 108 to an account-inactive error", %{credential: credential} do
      Tesla.Mock.mock(fn %{method: :get} ->
        %Tesla.Env{status: 403, body: %{"code" => 108}}
      end)

      assert {:error, message} = Partners.verify_swiftchat_credentials(credential)
      assert message =~ "inactive"
      refute message =~ credential.secrets["api_key"]
    end

    test "maps a network/transport failure to a can't-reach message", %{credential: credential} do
      Tesla.Mock.mock(fn %{method: :get} -> {:error, :econnrefused} end)

      assert {:error, message} = Partners.verify_swiftchat_credentials(credential)
      assert message =~ "Could not reach SwiftChat"
      refute message =~ credential.secrets["api_key"]
    end
  end

  describe "credential_update_callback/3 \"swiftchat\" clause end-to-end (via update_credential/2)" do
    test "ping success sets organization.bsp_id", %{
      organization_id: organization_id,
      credential: credential
    } do
      {:ok, provider} = Repo.fetch_by(Provider, %{shortcode: "swiftchat"})

      Tesla.Mock.mock(fn %{method: :get} ->
        %Tesla.Env{status: 200, body: %{"bot_id" => "test_bot_id"}}
      end)

      assert {:ok, %Credential{}} =
               Partners.update_credential(credential, update_attrs(organization_id))

      organization = Partners.get_organization!(organization_id)
      assert organization.bsp_id == provider.id
    end

    test "401/code 110 leaves bsp_id unset and surfaces the mapped message", %{
      organization_id: organization_id,
      credential: credential
    } do
      organization_before = Partners.get_organization!(organization_id)

      Tesla.Mock.mock(fn %{method: :get} ->
        %Tesla.Env{status: 401, body: %{"code" => 110}}
      end)

      assert {:error, "Invalid API key"} =
               Partners.update_credential(credential, update_attrs(organization_id))

      organization_after = Partners.get_organization!(organization_id)
      assert organization_after.bsp_id == organization_before.bsp_id
    end

    test "400/code 2 leaves bsp_id unset and surfaces the mapped message", %{
      organization_id: organization_id,
      credential: credential
    } do
      organization_before = Partners.get_organization!(organization_id)

      Tesla.Mock.mock(fn %{method: :get} ->
        %Tesla.Env{status: 400, body: %{"code" => 2}}
      end)

      assert {:error, "Invalid Bot ID"} =
               Partners.update_credential(credential, update_attrs(organization_id))

      organization_after = Partners.get_organization!(organization_id)
      assert organization_after.bsp_id == organization_before.bsp_id
    end

    test "403/code 108 leaves bsp_id unset and surfaces the mapped message", %{
      organization_id: organization_id,
      credential: credential
    } do
      organization_before = Partners.get_organization!(organization_id)

      Tesla.Mock.mock(fn %{method: :get} ->
        %Tesla.Env{status: 403, body: %{"code" => 108}}
      end)

      assert {:error, message} =
               Partners.update_credential(credential, update_attrs(organization_id))

      assert message =~ "inactive"

      organization_after = Partners.get_organization!(organization_id)
      assert organization_after.bsp_id == organization_before.bsp_id
    end

    test "network failure leaves bsp_id unset and surfaces a can't-reach message", %{
      organization_id: organization_id,
      credential: credential
    } do
      organization_before = Partners.get_organization!(organization_id)

      Tesla.Mock.mock(fn %{method: :get} -> {:error, :econnrefused} end)

      assert {:error, message} =
               Partners.update_credential(credential, update_attrs(organization_id))

      assert message =~ "Could not reach SwiftChat"

      organization_after = Partners.get_organization!(organization_id)
      assert organization_after.bsp_id == organization_before.bsp_id
    end

    test "no api_key leaks into the error string on any failure path", %{
      organization_id: organization_id,
      credential: credential
    } do
      Tesla.Mock.mock(fn %{method: :get} ->
        %Tesla.Env{status: 401, body: %{"code" => 110}}
      end)

      assert {:error, message} =
               Partners.update_credential(credential, update_attrs(organization_id))

      refute message =~ "super-secret-api-key"
    end
  end
end
