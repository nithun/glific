defmodule GlificWeb.Providers.Swiftchat.Controllers.MessageControllerTest do
  @moduledoc """
  Controller + normalizer tests for the SwiftChat inbound stack
  (PRD-001-tasks T-05): webhook -> contact -> flow, through the full
  plug/router path. Payload shapes are the confirmed envelope from
  `docs/prds/PRD-001-spike-notes.md` §3 in the planning repo.
  """
  use GlificWeb.ConnCase

  alias Glific.{
    Contacts,
    Contacts.Contact,
    Messages.Message,
    Messages.MessageMedia,
    Partners,
    Partners.Provider,
    Repo
  }

  @text_webhook %{
    "from" => "+919917443994",
    "type" => "text",
    "timestamp" => 1_707_216_634,
    "message_id" => "swiftchat-msg-1",
    "conversation_id" => "conv-1",
    "conversation_initiated_by" => "user",
    "text" => %{"body" => "Hello SwiftChat"}
  }

  @button_response_webhook %{
    "from" => "+919917443994",
    "type" => "button_response",
    "timestamp" => 1_707_216_634,
    "message_id" => "swiftchat-msg-2",
    "conversation_id" => "conv-1",
    "conversation_initiated_by" => "user",
    "button_response" => %{"button_index" => 1, "body" => "Class 1"}
  }

  describe "text" do
    test "inbound text creates a contact with the real phone in the right org",
         %{conn: conn, organization_id: organization_id} do
      conn = post(conn, "/swiftchat", @text_webhook)
      assert conn.halted

      {:ok, message} =
        Repo.fetch_by(Message, %{
          bsp_message_id: "swiftchat-msg-1",
          organization_id: organization_id
        })

      message = Repo.preload(message, [:sender])

      assert message.flow == :inbound
      assert message.body == "Hello SwiftChat"
      assert message.sender.phone == "+919917443994"
      assert message.sender.organization_id == organization_id
    end

    test "first inbound message sets implicit opt-in + session_and_hsm per ADR-004",
         %{conn: conn, organization_id: organization_id} do
      conn = post(conn, "/swiftchat", @text_webhook)
      assert conn.halted

      {:ok, contact} =
        Repo.fetch_by(Contact, %{phone: "+919917443994", organization_id: organization_id})

      assert contact.optin_status == true
      assert contact.optin_method == "swiftchat-link"
      assert contact.optin_time != nil
      assert contact.last_message_at != nil
      assert contact.bsp_status == :session_and_hsm
    end

    test "second inbound message from the same contact does not re-run opt-in",
         %{conn: conn, organization_id: organization_id} do
      conn = post(conn, "/swiftchat", @text_webhook)
      assert conn.halted

      {:ok, contact} =
        Repo.fetch_by(Contact, %{phone: "+919917443994", organization_id: organization_id})

      first_optin_time = contact.optin_time

      second_webhook =
        @text_webhook
        |> Map.put("message_id", "swiftchat-msg-1b")
        |> put_in(["text", "body"], "second message")

      fresh_conn =
        build_conn()
        |> Plug.Conn.assign(:organization_id, organization_id)

      conn2 = post(fresh_conn, "/swiftchat", second_webhook)
      assert conn2.halted

      {:ok, contact} =
        Repo.fetch_by(Contact, %{phone: "+919917443994", organization_id: organization_id})

      assert contact.optin_time == first_optin_time
      assert contact.bsp_status == :session_and_hsm

      {:ok, message} =
        Repo.fetch_by(Message, %{
          bsp_message_id: "swiftchat-msg-1b",
          organization_id: organization_id
        })

      assert message.body == "second message"
    end

    test "unknown extra keys in the envelope do not crash the normalizer",
         %{conn: conn, organization_id: organization_id} do
      webhook_with_unknown_keys =
        @text_webhook
        |> Map.put("message_id", "swiftchat-msg-unknown-keys")
        |> Map.put("a_future_field_swiftchat_might_add", %{"nested" => "value"})
        |> Map.put("another_new_key", ["some", "list"])

      conn = post(conn, "/swiftchat", webhook_with_unknown_keys)
      assert conn.halted

      {:ok, message} =
        Repo.fetch_by(Message, %{
          bsp_message_id: "swiftchat-msg-unknown-keys",
          organization_id: organization_id
        })

      assert message.body == "Hello SwiftChat"
    end
  end

  describe "interactive (button_response)" do
    test "inbound button_response creates a message with the reply body",
         %{conn: conn, organization_id: organization_id} do
      conn = post(conn, "/swiftchat", @button_response_webhook)
      assert conn.halted

      {:ok, message} =
        Repo.fetch_by(Message, %{
          bsp_message_id: "swiftchat-msg-2",
          organization_id: organization_id
        })

      message = Repo.preload(message, [:sender])

      assert message.flow == :inbound
      assert message.body == "Class 1"
      assert message.sender.phone == "+919917443994"
      assert message.interactive_content["button_index"] == 1
    end
  end

  describe "unknown/unhandled payload types" do
    test "message_rated events get 200, not dropped", %{conn: conn} do
      rated_webhook = %{
        "from" => "+919917443994",
        "type" => "message_rated",
        "timestamp" => 1_707_216_634,
        "message_id" => "swiftchat-msg-rated",
        "conversation_id" => "conv-1",
        "conversation_initiated_by" => "user",
        "rating" => %{"type" => "star", "star" => %{"value" => 1}, "review" => "great"}
      }

      conn = post(conn, "/swiftchat", rated_webhook)
      assert response(conn, 200) == ""
    end

    test "multi_select_button_response (T-09 scope) gets 200, not dropped", %{conn: conn} do
      multi_select_webhook = %{
        "from" => "+919917443994",
        "type" => "multi_select_button_response",
        "timestamp" => 1_707_216_634,
        "message_id" => "swiftchat-msg-multi",
        "conversation_id" => "conv-1",
        "conversation_initiated_by" => "user",
        "multi_select_button_response" => [%{"button_index" => 1, "body" => "Option A"}]
      }

      conn = post(conn, "/swiftchat", multi_select_webhook)
      assert response(conn, 200) == ""
    end

    test "a completely unrecognized type gets 200, not dropped", %{conn: conn} do
      unrecognized_webhook = %{
        "from" => "+919917443994",
        "type" => "some_brand_new_type_swiftchat_adds_later",
        "timestamp" => 1_707_216_634,
        "message_id" => "swiftchat-msg-future"
      }

      conn = post(conn, "/swiftchat", unrecognized_webhook)
      assert response(conn, 200) == ""
    end

    test "a payload with no type at all gets 200, not dropped", %{conn: conn} do
      conn = post(conn, "/swiftchat", %{"unexpected" => "shape"})
      assert response(conn, 200) == ""
    end
  end

  describe "org scoping" do
    test "inbound message is attributed to the org from conn.assigns (ADR-003)",
         %{conn: conn, organization_id: organization_id} do
      conn = post(conn, "/swiftchat", @text_webhook)
      assert conn.halted

      {:ok, contact} =
        Repo.fetch_by(Contact, %{phone: "+919917443994", organization_id: organization_id})

      assert contact.organization_id == organization_id
    end
  end

  describe "blocked contact" do
    test "inbound text for a blocked contact is not stored", %{conn: conn} do
      [contact | _tail] = Contacts.list_contacts(%{})
      {:ok, contact} = Contacts.update_contact(contact, %{status: :blocked})

      webhook =
        @text_webhook
        |> Map.put("from", contact.phone)
        |> Map.put("message_id", "swiftchat-msg-blocked")

      conn = post(conn, "/swiftchat", webhook)
      assert conn.halted

      assert {:error, ["Elixir.Glific.Messages.Message", "Resource not found"]} =
               Repo.fetch_by(Message, %{
                 bsp_message_id: "swiftchat-msg-blocked",
                 organization_id: conn.assigns[:organization_id]
               })
    end
  end

  describe "media (T-08): image/document/video/audio through the full controller path" do
    # Activates the swiftchat credential so `ApiClient.get_media_url/2`
    # has bot_id/api_key to resolve against — the ConnCase default BSP is
    # gupshup, mirroring `Swiftchat.MessageTest`'s setup helper.
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

    @image_webhook %{
      "from" => "+919917443994",
      "type" => "image",
      "timestamp" => 1_707_216_634,
      "message_id" => "swiftchat-msg-image",
      "conversation_id" => "conv-1",
      "conversation_initiated_by" => "user",
      "image" => %{"id" => "media-id-1", "body" => "a caption", "content_type" => "image/png"}
    }

    @document_webhook %{
      "from" => "+919917443994",
      "type" => "document",
      "timestamp" => 1_707_216_634,
      "message_id" => "swiftchat-msg-document",
      "conversation_id" => "conv-1",
      "conversation_initiated_by" => "user",
      "document" => %{
        "id" => "media-id-2",
        "name" => "report.pdf",
        "body" => "a report",
        "content_type" => "application/pdf"
      }
    }

    @video_webhook %{
      "from" => "+919917443994",
      "type" => "video",
      "timestamp" => 1_707_216_634,
      "message_id" => "swiftchat-msg-video",
      "conversation_id" => "conv-1",
      "conversation_initiated_by" => "user",
      "video" => %{"id" => "media-id-3", "title" => "a clip", "content_type" => "video/mp4"}
    }

    @audio_webhook %{
      "from" => "+919917443994",
      "type" => "audio",
      "timestamp" => 1_707_216_634,
      "message_id" => "swiftchat-msg-audio",
      "conversation_id" => "conv-1",
      "conversation_initiated_by" => "user",
      "audio" => %{
        "id" => "media-id-4",
        "title" => "a note",
        "body" => "a voice note",
        "content_type" => "audio/mpeg"
      }
    }

    @spec mock_media_url_resolution(String.t()) :: :ok
    defp mock_media_url_resolution(resolved_url) do
      Tesla.Mock.mock(fn
        %{method: :get} ->
          %Tesla.Env{status: 200, body: Jason.encode!(%{"url" => resolved_url})}
      end)
    end

    test "inbound image resolves the media id to a URL and stores the message + media",
         %{conn: conn, organization_id: organization_id} do
      :ok = activate_swiftchat(organization_id)
      mock_media_url_resolution("https://s3.example.com/presigned-image?X-Amz-Expires=900")

      conn = post(conn, "/swiftchat", @image_webhook)
      assert conn.halted

      {:ok, message} =
        Repo.fetch_by(Message, %{
          bsp_message_id: "swiftchat-msg-image",
          organization_id: organization_id
        })

      message = Repo.preload(message, [:media, :sender])
      assert message.type == :image
      assert message.sender.phone == "+919917443994"
      assert message.media.url == "https://s3.example.com/presigned-image?X-Amz-Expires=900"
      assert message.media.source_url == message.media.url
      assert message.media.caption == "a caption"
      assert message.media.content_type == "image/png"
    end

    test "inbound document resolves the media id and stores name/caption in the media caption",
         %{conn: conn, organization_id: organization_id} do
      :ok = activate_swiftchat(organization_id)
      mock_media_url_resolution("https://s3.example.com/presigned-document")

      conn = post(conn, "/swiftchat", @document_webhook)
      assert conn.halted

      {:ok, message} =
        Repo.fetch_by(Message, %{
          bsp_message_id: "swiftchat-msg-document",
          organization_id: organization_id
        })

      message = Repo.preload(message, :media)
      assert message.type == :document
      assert message.media.caption == "a report"
      assert message.media.content_type == "application/pdf"
    end

    test "inbound video resolves the media id and falls back to the title as caption",
         %{conn: conn, organization_id: organization_id} do
      :ok = activate_swiftchat(organization_id)
      mock_media_url_resolution("https://s3.example.com/presigned-video")

      conn = post(conn, "/swiftchat", @video_webhook)
      assert conn.halted

      {:ok, message} =
        Repo.fetch_by(Message, %{
          bsp_message_id: "swiftchat-msg-video",
          organization_id: organization_id
        })

      message = Repo.preload(message, :media)
      assert message.type == :video
      assert message.media.caption == "a clip"
    end

    test "inbound audio resolves the media id and stores natively as type audio",
         %{conn: conn, organization_id: organization_id} do
      :ok = activate_swiftchat(organization_id)
      mock_media_url_resolution("https://s3.example.com/presigned-audio")

      conn = post(conn, "/swiftchat", @audio_webhook)
      assert conn.halted

      {:ok, message} =
        Repo.fetch_by(Message, %{
          bsp_message_id: "swiftchat-msg-audio",
          organization_id: organization_id
        })

      message = Repo.preload(message, :media)
      assert message.type == :audio
      assert message.media.caption == "a voice note"
    end

    test "media-URL resolution failure still stores the message, with a sentinel media URL",
         %{conn: conn, organization_id: organization_id} do
      :ok = activate_swiftchat(organization_id)

      Tesla.Mock.mock(fn
        %{method: :get} -> {:error, :timeout}
      end)

      webhook = Map.put(@image_webhook, "message_id", "swiftchat-msg-image-unresolvable")

      conn = post(conn, "/swiftchat", webhook)
      assert conn.halted

      {:ok, message} =
        Repo.fetch_by(Message, %{
          bsp_message_id: "swiftchat-msg-image-unresolvable",
          organization_id: organization_id
        })

      message = Repo.preload(message, :media)
      assert %MessageMedia{} = message.media
      assert message.media.url == "unresolved://media-id-1"
      assert message.media.source_url == "unresolved://media-id-1"
    end
  end
end
