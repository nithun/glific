defmodule GlificWeb.Providers.Swiftchat.Controllers.MessageControllerTest do
  @moduledoc """
  Controller + normalizer tests for the SwiftChat inbound stack
  (PRD-001-tasks T-05): webhook -> contact -> flow, through the full
  plug/router path. Payload shapes are the confirmed envelope from
  `docs/prds/PRD-001-spike-notes.md` §3 in the planning repo.
  """
  use GlificWeb.ConnCase

  import Ecto.Query, warn: false

  alias Glific.{
    Contacts,
    Contacts.Contact,
    Flows.FlowContext,
    Messages.Message,
    Messages.MessageMedia,
    Partners,
    Partners.Provider,
    Processor.ConsumerFlow,
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

  @multi_select_response_webhook %{
    "from" => "+919917443994",
    "type" => "multi_select_button_response",
    "timestamp" => 1_707_216_634,
    "message_id" => "swiftchat-msg-multi-1",
    "conversation_id" => "conv-1",
    "conversation_initiated_by" => "user",
    "multi_select_button_response" => [
      %{"button_index" => 1, "body" => "Class 1"},
      %{"button_index" => 2, "body" => "Class 2"}
    ]
  }

  @persistent_menu_response_webhook %{
    "from" => "+919917443994",
    "type" => "persistent_menu_response",
    "timestamp" => 1_707_216_634,
    "message_id" => "swiftchat-msg-menu-1",
    "conversation_id" => "conv-1",
    "conversation_initiated_by" => "user",
    "persistent_menu_response" => %{"id" => "menu-item-1", "body" => "Talk to a human"}
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

  describe "interactive (multi_select_button_response, T-09)" do
    test "inbound multi_select_button_response creates a message with the joined reply body",
         %{conn: conn, organization_id: organization_id} do
      conn = post(conn, "/swiftchat", @multi_select_response_webhook)
      assert conn.halted

      {:ok, message} =
        Repo.fetch_by(Message, %{
          bsp_message_id: "swiftchat-msg-multi-1",
          organization_id: organization_id
        })

      message = Repo.preload(message, [:sender])

      assert message.flow == :inbound
      assert message.body == "Class 1, Class 2"
      assert message.sender.phone == "+919917443994"

      assert message.interactive_content == %{
               "selections" => [
                 %{"button_index" => 1, "body" => "Class 1"},
                 %{"button_index" => 2, "body" => "Class 2"}
               ]
             }
    end

    test "unknown extra keys in the multi_select_button_response envelope do not crash the normalizer",
         %{conn: conn, organization_id: organization_id} do
      webhook =
        @multi_select_response_webhook
        |> Map.put("message_id", "swiftchat-msg-multi-unknown-keys")
        |> Map.put("a_future_field_swiftchat_might_add", %{"nested" => "value"})

      conn = post(conn, "/swiftchat", webhook)
      assert conn.halted

      {:ok, message} =
        Repo.fetch_by(Message, %{
          bsp_message_id: "swiftchat-msg-multi-unknown-keys",
          organization_id: organization_id
        })

      assert message.body == "Class 1, Class 2"
    end
  end

  describe "interactive (persistent_menu_response, T-09)" do
    test "inbound persistent_menu_response creates a message with the reply body",
         %{conn: conn, organization_id: organization_id} do
      conn = post(conn, "/swiftchat", @persistent_menu_response_webhook)
      assert conn.halted

      {:ok, message} =
        Repo.fetch_by(Message, %{
          bsp_message_id: "swiftchat-msg-menu-1",
          organization_id: organization_id
        })

      message = Repo.preload(message, [:sender])

      assert message.flow == :inbound
      assert message.body == "Talk to a human"
      assert message.sender.phone == "+919917443994"
      assert message.interactive_content["id"] == "menu-item-1"
    end

    test "unknown extra keys in the persistent_menu_response envelope do not crash the normalizer",
         %{conn: conn, organization_id: organization_id} do
      webhook =
        @persistent_menu_response_webhook
        |> Map.put("message_id", "swiftchat-msg-menu-unknown-keys")
        |> Map.put("a_future_field_swiftchat_might_add", %{"nested" => "value"})

      conn = post(conn, "/swiftchat", webhook)
      assert conn.halted

      {:ok, message} =
        Repo.fetch_by(Message, %{
          bsp_message_id: "swiftchat-msg-menu-unknown-keys",
          organization_id: organization_id
        })

      assert message.body == "Talk to a human"
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

    test "F-079: a malicious media_id shape is rejected before the authenticated BSP fetch, message still stored with a sentinel URL",
         %{conn: conn, organization_id: organization_id} do
      :ok = activate_swiftchat(organization_id)

      Tesla.Mock.mock(fn
        %{method: :get} ->
          flunk("BSP should not have been called with a non-conforming media_id")
      end)

      malicious_webhook =
        @image_webhook
        |> Map.put("message_id", "swiftchat-msg-image-malicious-id")
        |> put_in(["image", "id"], "../../merchants/other-merchant/templates")

      conn = post(conn, "/swiftchat", malicious_webhook)
      assert conn.halted

      {:ok, message} =
        Repo.fetch_by(Message, %{
          bsp_message_id: "swiftchat-msg-image-malicious-id",
          organization_id: organization_id
        })

      message = Repo.preload(message, :media)
      assert %MessageMedia{} = message.media
      assert message.media.url =~ "unresolved://"
      assert message.media.source_url =~ "unresolved://"
    end

    test "F-079 follow-up: a non-binary media_id (malformed webhook) does not crash the controller, message still stored with a sentinel URL",
         %{conn: conn, organization_id: organization_id} do
      :ok = activate_swiftchat(organization_id)

      Tesla.Mock.mock(fn
        %{method: :get} ->
          flunk("BSP should not have been called with a non-binary media_id")
      end)

      # A malformed/unexpected webhook body where the media id itself is a
      # map (not a string) — `ApiClient.get_media_url/2` already rejects
      # this shape (F-079's `is_binary` guard), but the controller's own
      # diagnostic-logging branch used to interpolate the raw `media_id`
      # into a Logger message (`#{media_id}`), which raises
      # `Protocol.UndefinedError` for a non-`String.Chars` term and crashed
      # the controller before it could fall through to the
      # `unresolved://` sentinel.
      malformed_webhook =
        @image_webhook
        |> Map.put("message_id", "swiftchat-msg-image-non-binary-id")
        |> put_in(["image", "id"], %{"unexpected" => "shape"})

      conn = post(conn, "/swiftchat", malformed_webhook)
      assert conn.halted

      {:ok, message} =
        Repo.fetch_by(Message, %{
          bsp_message_id: "swiftchat-msg-image-non-binary-id",
          organization_id: organization_id
        })

      message = Repo.preload(message, :media)
      assert %MessageMedia{} = message.media
      assert message.media.url =~ "unresolved://"
      assert message.media.source_url =~ "unresolved://"
    end
  end

  describe "flow advancement (T-05/T-09 AC: inbound reply advances a flow)" do
    @flow_keyword_webhook %{
      "from" => "+919917443995",
      "type" => "text",
      "timestamp" => 1_707_216_999,
      "message_id" => "swiftchat-msg-flow-1",
      "conversation_id" => "conv-flow-1",
      "conversation_initiated_by" => "user",
      "text" => %{"body" => "help"}
    }

    test "an inbound SwiftChat text reply that matches a flow keyword starts and advances the flow",
         %{conn: conn, organization_id: organization_id} do
      # "help" is a real, active trigger keyword seeded for org 1 (the
      # "Help Workflow" flow — confirmed via
      # `Glific.Flows.flow_keywords_map(1)["published"]`), and is the
      # same keyword `test/glific/processor/consumer_flow_test.exs`'s
      # "should start the flow" test drives through
      # `ConsumerFlow.process_message/2` directly (its `@checks` fixture,
      # index 0). Mirrored here through the real SwiftChat webhook plug
      # path instead of `Fixtures.message_fixture/1`, since T-05's AC is
      # specifically about the SwiftChat inbound path advancing a flow.
      conn = post(conn, "/swiftchat", @flow_keyword_webhook)
      assert conn.halted

      {:ok, message} =
        Repo.fetch_by(Message, %{
          bsp_message_id: "swiftchat-msg-flow-1",
          organization_id: organization_id
        })

      contact_id = message.contact_id

      # confirm no flow is active yet for this brand-new contact
      refute FlowContext.active_context(contact_id)

      message = Repo.preload(message, [:location, :media, :whatsapp_form_response, :contact])
      state = ConsumerFlow.load_state(organization_id)

      # drive the flow-execution step directly, the same way
      # `Processor.ConsumerWorker`'s GenServer does asynchronously in
      # production (see `consumer_worker.ex:process_message/2`) — tests
      # call this synchronously so the assertion isn't racing GenStage.
      ConsumerFlow.process_message({message, state}, message.body)

      flow_context = FlowContext.active_context(contact_id)

      # the flow genuinely started and advanced past its entry node for
      # this contact — a real FlowContext row now exists, scoped to this
      # contact, with a node_uuid placing it inside the flow's node graph
      # (not merely that an inbound Message row got persisted, which the
      # `message.flow == :inbound` assertions elsewhere in this file
      # already cover and which is a different field entirely).
      assert %FlowContext{} = flow_context
      assert flow_context.contact_id == contact_id
      assert flow_context.node_uuid != nil
    end

    @flow_start_webhook %{
      "from" => "+919917443997",
      "type" => "text",
      "timestamp" => 1_707_217_100,
      "message_id" => "swiftchat-msg-flow-interactive-start",
      "conversation_id" => "conv-flow-interactive",
      "conversation_initiated_by" => "user",
      "text" => %{"body" => "help"}
    }

    @flow_interactive_reply_webhook %{
      "from" => "+919917443997",
      "type" => "button_response",
      "timestamp" => 1_707_217_101,
      "message_id" => "swiftchat-msg-flow-interactive-reply",
      "conversation_id" => "conv-flow-interactive",
      "conversation_initiated_by" => "user",
      "button_response" => %{"button_index" => 1, "body" => "1"}
    }

    test "F-080: an inbound SwiftChat interactive reply advances an already-ACTIVE flow",
         %{conn: conn, organization_id: organization_id} do
      # Same "help" keyword as the text-path test above starts the seeded
      # "Help Workflow" flow, which lands on a `wait_for_response` node
      # that routes on the next reply's body (`has_any_word` on "1"/"2"/
      # "3" — `priv/data/flows/help.json`). Unlike the text-path test
      # (which only proves a flow can *start*), this drives a SECOND,
      # interactive-typed inbound message (`button_response`, T-09's
      # normalizer) at that already-active flow and asserts the
      # FlowContext moves past the wait node — the T-09 acceptance
      # criterion `message_controller_test.exs:158-263`'s Message-only
      # assertions never covered (F-080).
      start_conn = post(conn, "/swiftchat", @flow_start_webhook)
      assert start_conn.halted

      {:ok, start_message} =
        Repo.fetch_by(Message, %{
          bsp_message_id: "swiftchat-msg-flow-interactive-start",
          organization_id: organization_id
        })

      contact_id = start_message.contact_id
      state = ConsumerFlow.load_state(organization_id)

      start_message =
        Repo.preload(start_message, [:location, :media, :whatsapp_form_response, :contact])

      ConsumerFlow.process_message({start_message, state}, start_message.body)

      flow_context_before_reply = FlowContext.active_context(contact_id)
      assert %FlowContext{} = flow_context_before_reply
      assert flow_context_before_reply.node_uuid != nil

      reply_conn = post(conn, "/swiftchat", @flow_interactive_reply_webhook)
      assert reply_conn.halted

      {:ok, reply_message} =
        Repo.fetch_by(Message, %{
          bsp_message_id: "swiftchat-msg-flow-interactive-reply",
          organization_id: organization_id
        })

      assert reply_message.interactive_content["button_index"] == 1

      reply_message =
        Repo.preload(reply_message, [:location, :media, :whatsapp_form_response, :contact])

      ConsumerFlow.process_message({reply_message, state}, reply_message.body)

      flow_context_after_reply = FlowContext.active_context(contact_id)

      # The "1" branch of the seeded Help Workflow runs straight through
      # to completion (no further wait_for_response node) — so a
      # genuinely-advanced FlowContext ends up `nil` (completed) here,
      # not parked at a second node the way a single-hop flow's
      # node_uuid-diff assertion could check. Assert both halves of "the
      # interactive reply drove the router, not just persisted a Message
      # row": (1) the context is no longer active at the wait node it
      # was parked at (the flow completed), and (2) the option-1
      # branch's own outbound message was actually sent, proving the
      # router matched the interactive reply's body ("1") against its
      # `has_any_word` case rather than silently falling through.
      refute flow_context_after_reply

      assert Repo.exists?(
               from(m in Message,
                 where:
                   m.contact_id == ^contact_id and
                     m.flow == :outbound and
                     m.body == "Message for option 1"
               )
             )
    end
  end
end
