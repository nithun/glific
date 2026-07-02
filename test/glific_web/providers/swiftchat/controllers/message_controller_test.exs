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
    test "media types (T-08 scope) get 200, not dropped", %{conn: conn} do
      image_webhook = %{
        "from" => "+919917443994",
        "type" => "image",
        "timestamp" => 1_707_216_634,
        "message_id" => "swiftchat-msg-image",
        "conversation_id" => "conv-1",
        "conversation_initiated_by" => "user",
        "image" => %{"id" => "media-id-1", "body" => "a caption", "content_type" => "image/png"}
      }

      conn = post(conn, "/swiftchat", image_webhook)
      assert response(conn, 200) == ""
    end

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
end
