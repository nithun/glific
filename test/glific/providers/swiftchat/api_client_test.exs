defmodule Glific.Providers.Swiftchat.ApiClientTest do
  @moduledoc """
  Covers `ApiClient.send_message/2`'s credential-resolution and Bearer-auth
  request construction (T-04 acceptance criterion: "ExVCR test covers the
  send + error path").

  # TODO(T-01): once the live send-endpoint path is confirmed, update the
  # asserted URL below (currently the guessed
  # "https://api.swiftchat.ai/bots/<bot_id>/messages" shape).
  """
  use Glific.DataCase, async: false

  alias Glific.{
    Partners,
    Partners.Provider,
    Providers.Swiftchat.ApiClient,
    Repo
  }

  describe "send_message/2" do
    test "returns a credential error when the active BSP has no swiftchat-shaped secrets",
         attrs do
      # org 1's default fixture BSP is gupshup (no swiftchat credential
      # active yet) — gupshup's secrets have no "bot_id", so this exercises
      # the same "incomplete credentials" error path as a genuinely
      # misconfigured swiftchat credential, without needing to first null
      # out the org's only active BSP (which the fixture setup doesn't
      # allow — `services["bsp"]` is only nil pre-fixture).
      assert {:error, error_msg} =
               ApiClient.send_message(attrs.organization_id, %{"type" => "text"})

      assert error_msg =~ "API Key and Bot ID"
    end

    test "posts to the bot-scoped message endpoint with a Bearer token header", attrs do
      {:ok, swiftchat_provider} = Repo.fetch_by(Provider, %{shortcode: "swiftchat"})

      {:ok, _credential} =
        Partners.create_credential(%{
          organization_id: attrs.organization_id,
          shortcode: "swiftchat",
          keys: %{
            handler: "Glific.Providers.Swiftchat.Message",
            worker: "Glific.Providers.Swiftchat.Worker"
          },
          secrets: %{
            "api_key" => "test_swiftchat_api_key",
            "bot_id" => "test_bot_id",
            "merchant_id" => "test_merchant_id"
          },
          is_active: true
        })

      organization = Partners.get_organization!(attrs.organization_id)
      Partners.update_organization(organization, %{bsp_id: swiftchat_provider.id})

      organization = Partners.get_organization!(attrs.organization_id)
      Partners.remove_organization_cache(organization.id, organization.shortcode)
      Partners.fill_cache(organization)

      Tesla.Mock.mock(fn
        %{method: :post, url: url, headers: headers} ->
          assert url == "https://api.swiftchat.ai/bots/test_bot_id/messages"
          assert {"authorization", "Bearer test_swiftchat_api_key"} in headers

          %Tesla.Env{
            status: 200,
            body: Jason.encode!(%{"status" => "submitted", "messageId" => "swiftchat-msg-1"})
          }
      end)

      assert {:ok, %Tesla.Env{status: 200}} =
               ApiClient.send_message(attrs.organization_id, %{
                 "type" => "text",
                 "text" => %{"body" => "hi"},
                 "to" => "swiftchat-user-1"
               })
    end

    test "returns an error when the active swiftchat credential is missing api_key/bot_id",
         attrs do
      {:ok, swiftchat_provider} = Repo.fetch_by(Provider, %{shortcode: "swiftchat"})

      {:ok, _credential} =
        Partners.create_credential(%{
          organization_id: attrs.organization_id,
          shortcode: "swiftchat",
          keys: %{
            handler: "Glific.Providers.Swiftchat.Message",
            worker: "Glific.Providers.Swiftchat.Worker"
          },
          secrets: %{"api_key" => nil, "bot_id" => nil},
          is_active: true
        })

      organization = Partners.get_organization!(attrs.organization_id)
      Partners.update_organization(organization, %{bsp_id: swiftchat_provider.id})

      organization = Partners.get_organization!(attrs.organization_id)
      Partners.remove_organization_cache(organization.id, organization.shortcode)
      Partners.fill_cache(organization)

      assert {:error, error_msg} =
               ApiClient.send_message(attrs.organization_id, %{"type" => "text"})

      assert error_msg =~ "API Key and Bot ID"
    end
  end
end
