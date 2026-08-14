defmodule Glific.Providers.Swiftchat.ApiClientTest do
  @moduledoc """
  Covers `ApiClient.send_message/2`'s credential-resolution and Bearer-auth
  request construction (T-04 acceptance criterion: "ExVCR test covers the
  send + error path").

  Endpoint confirmed from the official Postman collection:
  `POST https://v1-api.swiftchat.ai/api/bots/{Bot-ID}/messages`.
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
          assert url == "https://v1-api.swiftchat.ai/api/bots/test_bot_id/messages"
          assert {"authorization", "Bearer test_swiftchat_api_key"} in headers

          %Tesla.Env{
            status: 201,
            body: Jason.encode!(%{"id" => "swiftchat-msg-1"})
          }
      end)

      assert {:ok, %Tesla.Env{status: 201}} =
               ApiClient.send_message(attrs.organization_id, %{
                 "type" => "text",
                 "text" => %{"body" => "hi"},
                 "to" => "+919876543210"
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

  describe "get_media_url/2 (T-08: inbound media-id -> presigned URL resolution)" do
    @spec activate_swiftchat(non_neg_integer()) :: :ok
    defp activate_swiftchat(organization_id) do
      {:ok, swiftchat_provider} = Repo.fetch_by(Provider, %{shortcode: "swiftchat"})

      {:ok, _credential} =
        Partners.create_credential(%{
          organization_id: organization_id,
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

      organization = Partners.get_organization!(organization_id)
      Partners.update_organization(organization, %{bsp_id: swiftchat_provider.id})

      organization = Partners.get_organization!(organization_id)
      Partners.remove_organization_cache(organization.id, organization.shortcode)
      Partners.fill_cache(organization)
      :ok
    end

    test "resolves the bot-scoped media endpoint with a Bearer token header and returns the presigned URL",
         attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Tesla.Mock.mock(fn
        %{method: :get, url: url, headers: headers} ->
          assert url == "https://v1-api.swiftchat.ai/api/bots/test_bot_id/media/media-id-1"
          assert {"authorization", "Bearer test_swiftchat_api_key"} in headers

          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "url" => "https://s3.example.com/presigned?X-Amz-Expires=900"
              })
          }
      end)

      assert {:ok, %Tesla.Env{status: 200, body: body}} =
               ApiClient.get_media_url(attrs.organization_id, "media-id-1")

      assert Jason.decode!(body)["url"] =~ "s3.example.com"
    end

    test "returns a credential error when no swiftchat credential is active", attrs do
      assert {:error, error_msg} =
               ApiClient.get_media_url(attrs.organization_id, "media-id-1")

      assert error_msg =~ "API Key and Bot ID"
    end

    test "F-079: rejects a malicious/non-conforming media_id before ever calling the BSP",
         attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Tesla.Mock.mock(fn _env ->
        flunk("BSP should not have been called with a non-conforming media_id")
      end)

      # path traversal / host-confusion attempt smuggled through the
      # unsigned inbound webhook's media id field.
      assert {:error, error_msg} =
               ApiClient.get_media_url(
                 attrs.organization_id,
                 "../../merchants/other-merchant/templates"
               )

      assert error_msg =~ "Invalid SwiftChat media id"
    end

    test "F-079: rejects a media_id carrying a second host / query-string injection", attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Tesla.Mock.mock(fn _env ->
        flunk("BSP should not have been called with a non-conforming media_id")
      end)

      assert {:error, error_msg} =
               ApiClient.get_media_url(
                 attrs.organization_id,
                 "abc?redirect=https://evil.example.com"
               )

      assert error_msg =~ "Invalid SwiftChat media id"
    end

    test "F-079: rejects a non-binary media_id (unexpected webhook shape) without raising",
         attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Tesla.Mock.mock(fn _env ->
        flunk("BSP should not have been called with a non-binary media_id")
      end)

      assert {:error, error_msg} =
               ApiClient.get_media_url(attrs.organization_id, %{"unexpected" => "shape"})

      assert error_msg =~ "Invalid SwiftChat media id"
    end

    test "F-079 follow-up: rejects a media_id with a trailing newline (PCRE `$` matches before it, `\\z` does not)",
         attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Tesla.Mock.mock(fn _env ->
        flunk("BSP should not have been called with a media_id carrying a trailing newline")
      end)

      assert {:error, error_msg} =
               ApiClient.get_media_url(attrs.organization_id, "abc123\n")

      assert error_msg =~ "Invalid SwiftChat media id"
    end
  end

  describe "get_template/2 (F-114: single-template GET for pull-sync body)" do
    test "resolves the merchant-scoped single-template endpoint with a Bearer token header",
         attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Tesla.Mock.mock(fn
        %{method: :get, url: url, headers: headers} ->
          assert url ==
                   "https://v1-api.swiftchat.ai/api/merchants/test_merchant_id/templates/order_confirmation"

          assert {"authorization", "Bearer test_swiftchat_api_key"} in headers

          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "template" => %{"type" => "text", "text" => %{"body" => "Hi {1}."}},
                "status" => "PENDING_REVIEW",
                "status_reason" => nil
              })
          }
      end)

      assert {:ok, %Tesla.Env{status: 200}} =
               ApiClient.get_template(attrs.organization_id, "order_confirmation")
    end

    test "returns a credential error when no swiftchat credential is active", attrs do
      assert {:error, error_msg} =
               ApiClient.get_template(attrs.organization_id, "order_confirmation")

      assert error_msg =~ "API Key and Bot ID"
    end

    test "rejects a non-conforming template name before ever calling the BSP", attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Tesla.Mock.mock(fn _env ->
        flunk("BSP should not have been called with a non-conforming template name")
      end)

      assert {:error, error_msg} =
               ApiClient.get_template(
                 attrs.organization_id,
                 "../../merchants/other-merchant/templates"
               )

      assert error_msg =~ "Invalid SwiftChat template name"
    end

    test "rejects an uppercase/invalid-charset template name before calling the BSP", attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Tesla.Mock.mock(fn _env ->
        flunk("BSP should not have been called with an invalid-charset template name")
      end)

      assert {:error, error_msg} = ApiClient.get_template(attrs.organization_id, "Invalid Name!")

      assert error_msg =~ "Invalid SwiftChat template name"
    end

    test "rejects a non-binary template name without raising", attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Tesla.Mock.mock(fn _env ->
        flunk("BSP should not have been called with a non-binary template name")
      end)

      assert {:error, error_msg} = ApiClient.get_template(attrs.organization_id, nil)

      assert error_msg =~ "Invalid SwiftChat template name"
    end

    test "rejects a template name with a trailing newline (`\\z`, not `$`, per L-027)", attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Tesla.Mock.mock(fn _env ->
        flunk("BSP should not have been called with a template name carrying a trailing newline")
      end)

      assert {:error, error_msg} =
               ApiClient.get_template(attrs.organization_id, "order_confirmation\n")

      assert error_msg =~ "Invalid SwiftChat template name"
    end

    test "propagates a non-200 response for the caller to handle (e.g. skip-and-retry)", attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Tesla.Mock.mock(fn %{method: :get} ->
        %Tesla.Env{status: 404, body: Jason.encode!(%{"code" => 118})}
      end)

      assert {:ok, %Tesla.Env{status: 404}} =
               ApiClient.get_template(attrs.organization_id, "missing_template")
    end
  end

  describe "upload_media/3 and delete_media/2 (ADR-017 T21)" do
    test "posts a multipart body with type + file fields and returns the provider media id",
         attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Tesla.Mock.mock(fn
        %{method: :post, url: url, headers: headers, body: %Tesla.Multipart{} = multipart} ->
          assert url == "https://v1-api.swiftchat.ai/api/bots/test_bot_id/media"
          assert {"authorization", "Bearer test_swiftchat_api_key"} in headers

          field_names =
            multipart.parts
            |> Enum.map(fn part -> Keyword.get(part.dispositions, :name) end)

          assert "type" in field_names
          assert "file" in field_names

          %Tesla.Env{
            status: 201,
            body: Jason.encode!(%{"id" => "provider-media-id-abc123"})
          }
      end)

      assert {:ok, "provider-media-id-abc123"} =
               ApiClient.upload_media(attrs.organization_id, "fake image bytes", "image/png")
    end

    test "rejects an upload over the 64 MB cap before making any network call", attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Tesla.Mock.mock(fn _env ->
        flunk("SwiftChat should not have been called for an oversize upload")
      end)

      oversize_content = :binary.copy(<<0>>, 64 * 1024 * 1024 + 1)

      assert {:error, error_msg} =
               ApiClient.upload_media(attrs.organization_id, oversize_content, "image/png")

      assert error_msg =~ "exceeds the 64 MB SwiftChat limit"
    end

    test "returns an error when the upload response is a non-2xx status", attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Tesla.Mock.mock(fn %{method: :post} ->
        %Tesla.Env{status: 400, body: Jason.encode!(%{"code" => 1, "message" => "bad request"})}
      end)

      assert {:error, error_msg} =
               ApiClient.upload_media(attrs.organization_id, "fake image bytes", "image/png")

      assert error_msg =~ "SwiftChat media upload failed"
    end

    test "returns an error when the success response body has no id", attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Tesla.Mock.mock(fn %{method: :post} ->
        %Tesla.Env{status: 201, body: Jason.encode!(%{"unexpected" => "shape"})}
      end)

      assert {:error, error_msg} =
               ApiClient.upload_media(attrs.organization_id, "fake image bytes", "image/png")

      assert error_msg =~ "unexpected response"
    end

    test "returns a credential error when no swiftchat credential is active for upload", attrs do
      assert {:error, error_msg} =
               ApiClient.upload_media(attrs.organization_id, "fake image bytes", "image/png")

      assert error_msg =~ "API Key and Bot ID"
    end

    test "DELETEs the bot-scoped media endpoint with a Bearer token header", attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Tesla.Mock.mock(fn
        %{method: :delete, url: url, headers: headers} ->
          assert url ==
                   "https://v1-api.swiftchat.ai/api/bots/test_bot_id/media/provider-media-id-abc123"

          assert {"authorization", "Bearer test_swiftchat_api_key"} in headers

          %Tesla.Env{status: 200, body: ""}
      end)

      assert {:ok, %Tesla.Env{status: 200}} =
               ApiClient.delete_media(attrs.organization_id, "provider-media-id-abc123")
    end

    test "F-079: rejects a non-conforming media_id before ever calling the BSP delete endpoint",
         attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Tesla.Mock.mock(fn _env ->
        flunk("BSP should not have been called with a non-conforming media_id")
      end)

      assert {:error, error_msg} =
               ApiClient.delete_media(
                 attrs.organization_id,
                 "../../merchants/other-merchant/templates"
               )

      assert error_msg =~ "Invalid SwiftChat media id"
    end
  end

  describe "get_bot_configuration/2 (PRD-003 F-2: live credential-verification ping)" do
    test "GETs the bot-scoped configuration endpoint with a Bearer token header" do
      Tesla.Mock.mock(fn
        %{method: :get, url: url, headers: headers} ->
          assert url == "https://v1-api.swiftchat.ai/api/bots/test_bot_id/configuration"
          assert {"authorization", "Bearer test_swiftchat_api_key"} in headers

          %Tesla.Env{status: 200, body: Jason.encode!(%{"bot_id" => "test_bot_id"})}
      end)

      assert {:ok, %Tesla.Env{status: 200}} =
               ApiClient.get_bot_configuration("test_bot_id", "test_swiftchat_api_key")
    end

    test "propagates a non-2xx response for the caller to map" do
      Tesla.Mock.mock(fn %{method: :get} ->
        %Tesla.Env{status: 401, body: Jason.encode!(%{"code" => 110})}
      end)

      assert {:ok, %Tesla.Env{status: 401}} =
               ApiClient.get_bot_configuration("test_bot_id", "bad_api_key")
    end
  end
end
