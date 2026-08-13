defmodule Glific.Providers.Swiftchat.MessageTest do
  @moduledoc """
  Send-text happy path + error path for the SwiftChat outbound stack
  (PRD-001-tasks T-04). Mirrors `test/glific/communications_test.exs`'s
  `gupshup_messages` describe block, swapped to SwiftChat as org 1's
  active BSP.

  Endpoint, body, and response shapes confirmed from the official
  "SwiftChat Platform" Postman collection — see
  docs/prds/PRD-001-spike-notes.md in the planning repo: success is `201`
  with `{"id": "<uuid>"}`, and `to` is the recipient's real mobile number.
  """
  use Glific.DataCase, async: false
  use Oban.Pro.Testing, repo: Glific.Repo

  alias Glific.{
    Communications,
    Contacts,
    Fixtures,
    Messages,
    Partners,
    Partners.Provider,
    Providers.Swiftchat.Worker,
    Repo,
    Scripts.SwiftchatTemplates
  }

  setup %{organization_id: organization_id} = attrs do
    switch_active_bsp_to_swiftchat(organization_id)

    Tesla.Mock.mock(fn
      %{method: :post} ->
        # confirmed SwiftChat success shape: 201 {"id": "<uuid>"}
        %Tesla.Env{
          status: 201,
          body: Jason.encode!(%{"id" => Ecto.UUID.generate()})
        }
    end)

    attrs
  end

  # Swaps org `organization_id`'s active BSP credential to `swiftchat`, the
  # way `Fixtures.organization_fixture/1` wires up gupshup_enterprise as an
  # inactive alternate credential. We call `Partners.create_credential/1`
  # directly (bypassing `update_credential/2`'s `credential_update_callback`,
  # which has no "swiftchat" clause yet and falls through to the default
  # `{:ok, credential}` no-op) and set `bsp_id` + refresh the cache exactly
  # like `verify_gupshup_credentials/2` does for Gupshup.
  @spec switch_active_bsp_to_swiftchat(non_neg_integer()) :: Partners.Organization.t()
  defp switch_active_bsp_to_swiftchat(organization_id) do
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

    organization
    |> Partners.update_organization(%{bsp_id: swiftchat_provider.id})

    organization = Partners.get_organization!(organization_id)
    Partners.remove_organization_cache(organization.id, organization.shortcode)
    Partners.fill_cache(organization)
  end

  describe "send_text/2" do
    test "send message should update the provider message id", attrs do
      sender = Fixtures.contact_fixture(attrs)
      receiver = Fixtures.contact_fixture(attrs)

      message =
        Fixtures.message_fixture(%{
          organization_id: attrs.organization_id,
          sender_id: sender.id,
          receiver_id: receiver.id,
          body: "hello via swiftchat",
          type: :text,
          flow: :outbound
        })

      assert {:ok, _message} = Communications.Message.send_message(message)
      assert_enqueued(worker: Worker, prefix: attrs.global_schema)
      Oban.drain_queue(queue: :swiftchat)

      message = Messages.get_message!(message.id)
      assert message.bsp_message_id != nil
      assert message.sent_at != nil
      assert message.bsp_status == :enqueued
      assert message.flow == :outbound
    end

    test "send message should return error when characters limit is reached", attrs do
      sender = Fixtures.contact_fixture(attrs)
      receiver = Fixtures.contact_fixture(attrs)

      message =
        Fixtures.message_fixture(%{
          organization_id: attrs.organization_id,
          sender_id: sender.id,
          receiver_id: receiver.id,
          body: Faker.Lorem.sentence(4097),
          type: :text,
          flow: :outbound
        })

      assert {:error, error_msg} = Communications.Message.send_message(message)
      assert error_msg == "Message size greater than 4096 characters"
    end

    test "send message should error gracefully when the receiver has no phone" do
      # A hand-built message whose receiver carries no phone — the guard in
      # put_destination/2 must fail the send before any Oban job is created.
      # (A persisted contact always has a phone, so this protects against
      # unloaded/nil receivers, not a realistic DB state.)
      message = %Glific.Messages.Message{
        body: "hello",
        uuid: Ecto.UUID.generate(),
        receiver_id: 0,
        receiver: %Glific.Contacts.Contact{phone: nil}
      }

      assert {:error, error_msg} = Glific.Providers.Swiftchat.Message.send_text(message)
      assert error_msg =~ "no phone"
    end

    test "send message to a simulator contact is faked, not sent over the wire", attrs do
      sender = Fixtures.contact_fixture(attrs)

      receiver =
        Fixtures.contact_fixture(Map.put(attrs, :phone, Contacts.simulator_phone_prefix() <> "1"))

      message =
        Fixtures.message_fixture(%{
          organization_id: attrs.organization_id,
          sender_id: sender.id,
          receiver_id: receiver.id,
          body: "hello simulator",
          type: :text,
          flow: :outbound
        })

      assert {:ok, _message} = Communications.Message.send_message(message)
      assert_enqueued(worker: Worker, prefix: attrs.global_schema)
      Oban.drain_queue(queue: :swiftchat)

      message = Messages.get_message!(message.id)
      assert message.bsp_message_id =~ "simu-"
    end
  end

  describe "send_interactive/2 (T-09): quick_reply -> button" do
    @quick_reply_content %{
      "type" => "quick_reply",
      "content" => %{
        "text" => "What do you want to do today?",
        "type" => "text",
        "header" => "Profile Selection"
      },
      "options" => [
        %{"type" => "text", "title" => "Create New Profile"},
        %{"type" => "text", "title" => "Select Profile"}
      ]
    }

    test "builds the confirmed button payload field-by-field and enqueues the send", attrs do
      sender = Fixtures.contact_fixture(attrs)
      receiver = Fixtures.contact_fixture(attrs)

      message =
        Fixtures.message_fixture(%{
          organization_id: attrs.organization_id,
          sender_id: sender.id,
          receiver_id: receiver.id,
          type: :quick_reply,
          interactive_content: @quick_reply_content,
          flow: :outbound
        })
        |> Repo.preload([:receiver], force: true)

      assert {:ok, %Oban.Job{args: %{payload: payload}} = job} =
               Glific.Providers.Swiftchat.Message.send_interactive(message)

      assert payload["type"] == "button"
      assert payload["rating_type"] == "thumb"
      assert get_in(payload, ["button", "body", "type"]) == "text"

      assert get_in(payload, ["button", "body", "text", "body"]) ==
               "What do you want to do today?"

      assert get_in(payload, ["button", "allow_custom_response"]) == false

      # button "type" is the visual style — live API enum is [solid, dotted]
      # (400 code-1 discovered in the 2026-07-02 live round-trip)
      assert get_in(payload, ["button", "buttons"]) == [
               %{
                 "icon" => "registration",
                 "type" => "solid",
                 "body" => "Create New Profile",
                 "reply" => "Create New Profile"
               },
               %{
                 "icon" => "registration",
                 "type" => "solid",
                 "body" => "Select Profile",
                 "reply" => "Select Profile"
               }
             ]

      assert_enqueued(worker: Worker, prefix: attrs.global_schema)
      Oban.drain_queue(queue: :swiftchat)

      message = Messages.get_message!(message.id)
      assert message.bsp_message_id != nil
      assert job.args.payload["to"] == receiver.phone
    end
  end

  describe "send_interactive/2 (T-09): list -> multi_select_button" do
    @list_content %{
      "type" => "list",
      "title" => "Interactive list",
      "body" => "Please choose an option",
      "globalButtons" => [%{"type" => "text", "title" => "Menu"}],
      "items" => [
        %{
          "title" => "Item Title",
          "subtitle" => "Subtitle",
          "options" => [
            %{"type" => "text", "title" => "Option 1"},
            %{"type" => "text", "title" => "Option 2"}
          ]
        }
      ]
    }

    test "builds the confirmed multi_select_button payload field-by-field", attrs do
      sender = Fixtures.contact_fixture(attrs)
      receiver = Fixtures.contact_fixture(attrs)

      message =
        Fixtures.message_fixture(%{
          organization_id: attrs.organization_id,
          sender_id: sender.id,
          receiver_id: receiver.id,
          type: :list,
          interactive_content: @list_content,
          flow: :outbound
        })
        |> Repo.preload([:receiver], force: true)

      assert {:ok, %Oban.Job{args: %{payload: payload}}} =
               Glific.Providers.Swiftchat.Message.send_interactive(message)

      assert payload["type"] == "button"
      assert payload["rating_type"] == "thumb"

      assert get_in(payload, ["multi_select_button", "body", "text", "body"]) ==
               "Please choose an option"

      assert get_in(payload, ["multi_select_button", "allow_custom_response"]) == false

      # single section: no section-title prefix applied
      assert get_in(payload, ["multi_select_button", "multi_select_button"]) == [
               %{
                 "icon" => "registration",
                 "type" => "solid",
                 "body" => "Option 1",
                 "reply" => "Option 1"
               },
               %{
                 "icon" => "registration",
                 "type" => "solid",
                 "body" => "Option 2",
                 "reply" => "Option 2"
               }
             ]

      assert_enqueued(worker: Worker, prefix: attrs.global_schema)
    end

    test "flattens multiple sections and prefixes each option with its section title", attrs do
      sender = Fixtures.contact_fixture(attrs)
      receiver = Fixtures.contact_fixture(attrs)

      multi_section_content =
        put_in(@list_content["items"], [
          %{
            "title" => "Classes",
            "options" => [%{"type" => "text", "title" => "Class 1"}]
          },
          %{
            "title" => "Grades",
            "options" => [%{"type" => "text", "title" => "Grade A"}]
          }
        ])

      message =
        Fixtures.message_fixture(%{
          organization_id: attrs.organization_id,
          sender_id: sender.id,
          receiver_id: receiver.id,
          type: :list,
          interactive_content: multi_section_content,
          flow: :outbound
        })
        |> Repo.preload([:receiver], force: true)

      assert {:ok, %Oban.Job{args: %{payload: payload}}} =
               Glific.Providers.Swiftchat.Message.send_interactive(message)

      assert get_in(payload, ["multi_select_button", "multi_select_button"]) == [
               %{
                 "icon" => "registration",
                 "type" => "solid",
                 "body" => "Classes: Class 1",
                 "reply" => "Classes: Class 1"
               },
               %{
                 "icon" => "registration",
                 "type" => "solid",
                 "body" => "Grades: Grade A",
                 "reply" => "Grades: Grade A"
               }
             ]
    end
  end

  describe "send_interactive/2 (T-09): unmappable variant fails loudly" do
    test "location_request_message has no SwiftChat equivalent and is rejected, not guessed",
         attrs do
      sender = Fixtures.contact_fixture(attrs)
      receiver = Fixtures.contact_fixture(attrs)

      message =
        Fixtures.message_fixture(%{
          organization_id: attrs.organization_id,
          sender_id: sender.id,
          receiver_id: receiver.id,
          type: :location_request_message,
          interactive_content: %{
            "type" => "location_request_message",
            "body" => %{"type" => "text", "text" => "Please share your location"},
            "action" => %{"name" => "send_location"}
          },
          flow: :outbound
        })

      assert {:error, error_msg} = Glific.Providers.Swiftchat.Message.send_interactive(message)
      assert error_msg =~ "unsupported interactive"
      assert error_msg =~ "location_request_message"
      refute_enqueued(worker: Worker, prefix: attrs.global_schema)
    end

    test "F-086(b): any other unmapped interactive_content type also returns a proper {:error, reason} tuple, not a bare log-call result",
         attrs do
      sender = Fixtures.contact_fixture(attrs)
      receiver = Fixtures.contact_fixture(attrs)

      message =
        Fixtures.message_fixture(%{
          organization_id: attrs.organization_id,
          sender_id: sender.id,
          receiver_id: receiver.id,
          type: :quick_reply,
          interactive_content: %{"type" => "a_future_swiftchat_type_not_yet_mapped"},
          flow: :outbound
        })

      result = Glific.Providers.Swiftchat.Message.send_interactive(message)

      assert {:error, error_msg} = result
      assert is_binary(error_msg)
      assert error_msg =~ "a_future_swiftchat_type_not_yet_mapped"
      refute_enqueued(worker: Worker, prefix: attrs.global_schema)
    end

    test "F-086(b): a nil interactive_content type is also rejected cleanly, not with a crash",
         attrs do
      sender = Fixtures.contact_fixture(attrs)
      receiver = Fixtures.contact_fixture(attrs)

      message =
        Fixtures.message_fixture(%{
          organization_id: attrs.organization_id,
          sender_id: sender.id,
          receiver_id: receiver.id,
          type: :quick_reply,
          interactive_content: %{},
          flow: :outbound
        })

      assert {:error, error_msg} = Glific.Providers.Swiftchat.Message.send_interactive(message)
      assert error_msg =~ "nil"
      refute_enqueued(worker: Worker, prefix: attrs.global_schema)
    end
  end

  describe "media sends (T-08 scope): send_image/2, send_video/2, send_document/2, send_audio/2" do
    # Builds a message with a media association attached (mirrors
    # `Fixtures.message_media_fixture/1` + `message_fixture/1`, since
    # neither fixture wires the two together and no existing Gupshup test
    # does either — the media/message association has to be built by
    # hand here).
    @spec media_message_fixture(map(), atom(), String.t()) :: Glific.Messages.Message.t()
    defp media_message_fixture(attrs, type, source_url) do
      sender = Fixtures.contact_fixture(attrs)
      receiver = Fixtures.contact_fixture(attrs)

      message_media =
        Fixtures.message_media_fixture(%{
          organization_id: attrs.organization_id,
          source_url: source_url,
          url: source_url,
          caption: "a caption"
        })

      message =
        Fixtures.message_fixture(%{
          organization_id: attrs.organization_id,
          sender_id: sender.id,
          receiver_id: receiver.id,
          type: type,
          media_id: message_media.id,
          flow: :outbound
        })

      Repo.preload(message, [:media, :receiver], force: true)
    end

    @spec mock_media_send(non_neg_integer()) :: :ok
    defp mock_media_send(content_length) do
      Tesla.Mock.mock(fn
        %{method: :post} ->
          %Tesla.Env{status: 201, body: Jason.encode!(%{"id" => Ecto.UUID.generate()})}

        %{method: :get} ->
          %Tesla.Env{
            status: 200,
            headers: [{"content-length", Integer.to_string(content_length)}],
            body: ""
          }
      end)
    end

    test "send_image/2 builds the confirmed image payload and enqueues the send", attrs do
      message = media_message_fixture(attrs, :image, "https://example.com/photo.png")
      mock_media_send(1024)

      assert {:ok, _job} = Glific.Providers.Swiftchat.Message.send_image(message)
      assert_enqueued(worker: Worker, prefix: attrs.global_schema)
      Oban.drain_queue(queue: :swiftchat)

      message = Messages.get_message!(message.id)
      assert message.bsp_message_id != nil
    end

    test "send_video/2 builds the confirmed video payload (title, not body) and enqueues",
         attrs do
      message = media_message_fixture(attrs, :video, "https://example.com/clip.mp4")
      mock_media_send(1024)

      assert {:ok, _job} = Glific.Providers.Swiftchat.Message.send_video(message)
      assert_enqueued(worker: Worker, prefix: attrs.global_schema)
      Oban.drain_queue(queue: :swiftchat)

      message = Messages.get_message!(message.id)
      assert message.bsp_message_id != nil
    end

    test "send_document/2 builds the confirmed document payload (name + body) and enqueues",
         attrs do
      message = media_message_fixture(attrs, :document, "https://example.com/file.pdf")
      mock_media_send(1024)

      assert {:ok, _job} = Glific.Providers.Swiftchat.Message.send_document(message)
      assert_enqueued(worker: Worker, prefix: attrs.global_schema)
      Oban.drain_queue(queue: :swiftchat)

      message = Messages.get_message!(message.id)
      assert message.bsp_message_id != nil
    end

    test "send_audio/2 sends natively as type audio (no ADR-002 document fallback)", attrs do
      message = media_message_fixture(attrs, :audio, "https://example.com/note.mp3")
      mock_media_send(1024)

      assert {:ok, _job} = Glific.Providers.Swiftchat.Message.send_audio(message)
      assert_enqueued(worker: Worker, prefix: attrs.global_schema)
      Oban.drain_queue(queue: :swiftchat)

      message = Messages.get_message!(message.id)
      assert message.bsp_message_id != nil
    end

    test "the outbound image payload shape matches the confirmed Postman body", attrs do
      message = media_message_fixture(attrs, :image, "https://example.com/photo.png")
      mock_media_send(1024)

      assert {:ok, %Oban.Job{args: %{payload: payload}}} =
               Glific.Providers.Swiftchat.Message.send_image(message)

      assert payload["type"] == "image"
      assert payload["image"]["url"] == "https://example.com/photo.png"
      assert payload["image"]["body"] == "a caption"
    end

    test "the outbound video payload shape uses 'title', not 'body', for the caption", attrs do
      message = media_message_fixture(attrs, :video, "https://example.com/clip.mp4")
      mock_media_send(1024)

      assert {:ok, %Oban.Job{args: %{payload: payload}}} =
               Glific.Providers.Swiftchat.Message.send_video(message)

      assert payload["type"] == "video"
      assert payload["video"]["url"] == "https://example.com/clip.mp4"
      assert payload["video"]["title"] == "a caption"
      refute Map.has_key?(payload["video"], "body")
    end

    test "the outbound document payload shape carries both name and body", attrs do
      message = media_message_fixture(attrs, :document, "https://example.com/file.pdf")
      mock_media_send(1024)

      assert {:ok, %Oban.Job{args: %{payload: payload}}} =
               Glific.Providers.Swiftchat.Message.send_document(message)

      assert payload["type"] == "document"
      assert payload["document"]["url"] == "https://example.com/file.pdf"
      assert payload["document"]["name"] == "a caption"
      assert payload["document"]["body"] == "a caption"
    end

    test "the outbound audio payload shape carries both title and body", attrs do
      message = media_message_fixture(attrs, :audio, "https://example.com/note.mp3")
      mock_media_send(1024)

      assert {:ok, %Oban.Job{args: %{payload: payload}}} =
               Glific.Providers.Swiftchat.Message.send_audio(message)

      assert payload["type"] == "audio"
      assert payload["audio"]["url"] == "https://example.com/note.mp3"
      assert payload["audio"]["title"] == "a caption"
      assert payload["audio"]["body"] == "a caption"
    end

    test "send_sticker/2 falls back to image with a logged error (ADR-002)", attrs do
      message = media_message_fixture(attrs, :sticker, "https://example.com/sticker.webp")
      mock_media_send(1024)

      assert {:ok, %Oban.Job{args: %{payload: payload}}} =
               Glific.Providers.Swiftchat.Message.send_sticker(message)

      assert payload["type"] == "image"
      assert payload["image"]["url"] == "https://example.com/sticker.webp"
    end

    test "oversize media (> 64 MB) is rejected fast with a logged, user-visible error", attrs do
      message = media_message_fixture(attrs, :image, "https://example.com/huge.png")
      # 70 MB, over the 64 MB confirmed limit
      mock_media_send(70 * 1024 * 1024)

      assert {:error, error_msg} = Glific.Providers.Swiftchat.Message.send_image(message)
      assert error_msg =~ "64 MB"
      refute_enqueued(worker: Worker, prefix: attrs.global_schema)
    end

    test "media size check tolerates an unreachable size-check URL and still sends", attrs do
      # Distinct URL from every other test in this describe block (F-082(b)
      # caches the size-check result per source_url) — reusing an already
      # cached-`:ok` URL here would let this test pass without ever
      # exercising the timeout branch it's named for.
      message = media_message_fixture(attrs, :image, "https://example.com/photo-unreachable.png")

      Tesla.Mock.mock(fn
        %{method: :post} ->
          %Tesla.Env{status: 201, body: Jason.encode!(%{"id" => Ecto.UUID.generate()})}

        %{method: :get} ->
          {:error, :timeout}
      end)

      assert {:ok, _job} = Glific.Providers.Swiftchat.Message.send_image(message)
    end

    test "F-082(b): the size-check result is cached per source_url — a second send to the same URL issues no new GET",
         attrs do
      source_url = "https://example.com/cached-size-check.png"

      {:ok, get_call_count} = Agent.start_link(fn -> 0 end)

      Tesla.Mock.mock(fn
        %{method: :post} ->
          %Tesla.Env{status: 201, body: Jason.encode!(%{"id" => Ecto.UUID.generate()})}

        %{method: :get} ->
          Agent.update(get_call_count, &(&1 + 1))
          %Tesla.Env{status: 200, headers: [{"content-length", "1024"}], body: ""}
      end)

      first_message = media_message_fixture(attrs, :image, source_url)
      assert {:ok, _job} = Glific.Providers.Swiftchat.Message.send_image(first_message)
      assert Agent.get(get_call_count, & &1) == 1

      second_message = media_message_fixture(attrs, :image, source_url)
      assert {:ok, _job} = Glific.Providers.Swiftchat.Message.send_image(second_message)

      # a second send against the SAME source_url (mirroring a broadcast
      # to a second recipient) must not issue a second GET.
      assert Agent.get(get_call_count, & &1) == 1
    end

    test "F-082(b): an oversize result is also cached — a second send to the same URL is rejected without a new GET",
         attrs do
      source_url = "https://example.com/cached-oversize.png"

      {:ok, get_call_count} = Agent.start_link(fn -> 0 end)

      Tesla.Mock.mock(fn
        %{method: :post} ->
          %Tesla.Env{status: 201, body: Jason.encode!(%{"id" => Ecto.UUID.generate()})}

        %{method: :get} ->
          Agent.update(get_call_count, &(&1 + 1))
          %Tesla.Env{status: 200, headers: [{"content-length", "#{70 * 1024 * 1024}"}], body: ""}
      end)

      first_message = media_message_fixture(attrs, :image, source_url)
      assert {:error, error_msg} = Glific.Providers.Swiftchat.Message.send_image(first_message)
      assert error_msg =~ "64 MB"
      assert Agent.get(get_call_count, & &1) == 1

      second_message = media_message_fixture(attrs, :image, source_url)
      assert {:error, ^error_msg} = Glific.Providers.Swiftchat.Message.send_image(second_message)
      assert Agent.get(get_call_count, & &1) == 1
    end
  end

  describe "receive_media/1 (F-082(d): direct unit coverage — previously controller-only)" do
    test "normalizes an image payload with a resolved_url into the standard inbound-media map" do
      payload = %{
        "from" => "+919917443994",
        "type" => "image",
        "message_id" => "swiftchat-msg-image-1",
        "resolved_url" => "https://s3.example.com/presigned-image?X-Amz-Expires=900",
        "image" => %{"id" => "media-id-1", "body" => "a caption", "content_type" => "image/png"}
      }

      assert %{
               bsp_message_id: "swiftchat-msg-image-1",
               caption: "a caption",
               url: "https://s3.example.com/presigned-image?X-Amz-Expires=900",
               source_url: "https://s3.example.com/presigned-image?X-Amz-Expires=900",
               content_type: "image/png",
               sender: %{phone: "+919917443994", name: "+919917443994"}
             } = Glific.Providers.Swiftchat.Message.receive_media(payload)
    end

    test "video falls back to 'title' for the caption (no 'body' key in the confirmed shape)" do
      payload = %{
        "from" => "+919917443994",
        "type" => "video",
        "message_id" => "swiftchat-msg-video-1",
        "resolved_url" => "https://s3.example.com/presigned-video",
        "video" => %{"id" => "media-id-3", "title" => "a clip", "content_type" => "video/mp4"}
      }

      assert %{caption: "a clip", url: "https://s3.example.com/presigned-video"} =
               Glific.Providers.Swiftchat.Message.receive_media(payload)
    end

    test "a missing resolved_url falls back to the unresolved:// sentinel, keyed by media id" do
      payload = %{
        "from" => "+919917443994",
        "type" => "document",
        "message_id" => "swiftchat-msg-document-1",
        "document" => %{
          "id" => "media-id-2",
          "name" => "report.pdf",
          "body" => "a report",
          "content_type" => "application/pdf"
        }
      }

      assert %{
               bsp_message_id: "swiftchat-msg-document-1",
               caption: "a report",
               url: "unresolved://media-id-2",
               source_url: "unresolved://media-id-2",
               content_type: "application/pdf"
             } = Glific.Providers.Swiftchat.Message.receive_media(payload)
    end

    test "a blank resolved_url also falls back to the sentinel, not an empty URL" do
      payload = %{
        "from" => "+919917443994",
        "type" => "audio",
        "message_id" => "swiftchat-msg-audio-1",
        "resolved_url" => "",
        "audio" => %{"id" => "media-id-4", "title" => "a note", "content_type" => "audio/mpeg"}
      }

      assert %{url: "unresolved://media-id-4", source_url: "unresolved://media-id-4"} =
               Glific.Providers.Swiftchat.Message.receive_media(payload)
    end
  end

  describe "receive_text/1 (T-05 scope)" do
    test "normalizes the confirmed SwiftChat text webhook envelope" do
      payload = %{
        "from" => "+919917443994",
        "type" => "text",
        "timestamp" => 1_707_216_634,
        "message_id" => "swiftchat-msg-1",
        "conversation_id" => "conv-1",
        "conversation_initiated_by" => "user",
        "text" => %{"body" => "Hi"}
      }

      assert %{
               bsp_message_id: "swiftchat-msg-1",
               body: "Hi",
               sender: %{phone: "+919917443994", name: "+919917443994"}
             } = Glific.Providers.Swiftchat.Message.receive_text(payload)
    end

    test "tolerates unknown/new envelope keys without crashing" do
      payload = %{
        "from" => "+919917443994",
        "type" => "text",
        "message_id" => "swiftchat-msg-2",
        "text" => %{"body" => "Hi"},
        "a_future_field" => %{"nested" => "value"}
      }

      assert %{bsp_message_id: "swiftchat-msg-2", body: "Hi"} =
               Glific.Providers.Swiftchat.Message.receive_text(payload)
    end
  end

  describe "receive_interactive/1 (T-05 scope: button_response only)" do
    test "normalizes a button_response webhook" do
      payload = %{
        "from" => "+919917443994",
        "type" => "button_response",
        "message_id" => "swiftchat-msg-3",
        "button_response" => %{"button_index" => 1, "body" => "Class 1"}
      }

      assert %{
               bsp_message_id: "swiftchat-msg-3",
               body: "Class 1",
               interactive_content: %{"button_index" => 1, "body" => "Class 1"},
               sender: %{phone: "+919917443994"}
             } = Glific.Providers.Swiftchat.Message.receive_interactive(payload)
    end
  end

  describe "receive_interactive/1 (T-09: multi_select_button_response)" do
    test "joins selected bodies into one comma-separated reply text" do
      payload = %{
        "from" => "+919917443994",
        "type" => "multi_select_button_response",
        "message_id" => "swiftchat-msg-4",
        "multi_select_button_response" => [
          %{"button_index" => 1, "body" => "Class 1"},
          %{"button_index" => 2, "body" => "Class 2"}
        ]
      }

      assert %{
               bsp_message_id: "swiftchat-msg-4",
               body: "Class 1, Class 2",
               interactive_content: %{
                 "selections" => [
                   %{"button_index" => 1, "body" => "Class 1"},
                   %{"button_index" => 2, "body" => "Class 2"}
                 ]
               },
               sender: %{phone: "+919917443994"}
             } = Glific.Providers.Swiftchat.Message.receive_interactive(payload)
    end

    test "a single selection still joins cleanly (no trailing separator)" do
      payload = %{
        "from" => "+919917443994",
        "type" => "multi_select_button_response",
        "message_id" => "swiftchat-msg-5",
        "multi_select_button_response" => [%{"button_index" => 1, "body" => "Only Option"}]
      }

      assert %{body: "Only Option"} =
               Glific.Providers.Swiftchat.Message.receive_interactive(payload)
    end

    test "tolerates unknown/new keys inside the selection entries without crashing" do
      payload = %{
        "from" => "+919917443994",
        "type" => "multi_select_button_response",
        "message_id" => "swiftchat-msg-6",
        "multi_select_button_response" => [
          %{"button_index" => 1, "body" => "Class 1", "a_future_field" => "value"}
        ],
        "another_new_envelope_key" => %{"nested" => true}
      }

      assert %{body: "Class 1"} = Glific.Providers.Swiftchat.Message.receive_interactive(payload)
    end
  end

  describe "receive_interactive/1 (T-09: persistent_menu_response)" do
    test "normalizes a persistent_menu_response webhook, using body as the reply text" do
      payload = %{
        "from" => "+919917443994",
        "type" => "persistent_menu_response",
        "message_id" => "swiftchat-msg-7",
        "persistent_menu_response" => %{"id" => "menu-item-1", "body" => "Talk to a human"}
      }

      assert %{
               bsp_message_id: "swiftchat-msg-7",
               body: "Talk to a human",
               interactive_content: %{"id" => "menu-item-1", "body" => "Talk to a human"},
               sender: %{phone: "+919917443994"}
             } = Glific.Providers.Swiftchat.Message.receive_interactive(payload)
    end

    test "tolerates unknown/new keys in the persistent_menu_response payload without crashing" do
      payload = %{
        "from" => "+919917443994",
        "type" => "persistent_menu_response",
        "message_id" => "swiftchat-msg-8",
        "persistent_menu_response" => %{
          "id" => "menu-item-1",
          "body" => "Talk to a human",
          "a_future_field" => "value"
        }
      }

      assert %{body: "Talk to a human"} =
               Glific.Providers.Swiftchat.Message.receive_interactive(payload)
    end
  end

  describe "send_text/2 HSM/template branch (T-10, ADR-005 phase 1)" do
    @spec approved_swiftchat_template(non_neg_integer(), String.t()) ::
            Glific.Templates.SessionTemplate.t()
    defp approved_swiftchat_template(organization_id, template_name) do
      {:ok, session_template} =
        SwiftchatTemplates.upsert_template(
          organization_id,
          template_name,
          "Order Confirmation",
          "Hi {{1}}, your order {{2}} has shipped.",
          2
        )

      session_template
    end

    test "builds the confirmed template payload (name from bsp_id, positional params)", attrs do
      session_template = approved_swiftchat_template(attrs.organization_id, "order_confirmation")
      contact = Fixtures.contact_fixture(attrs)

      message =
        Fixtures.message_fixture(%{
          organization_id: attrs.organization_id,
          sender_id: Partners.organization_contact_id(attrs.organization_id),
          receiver_id: contact.id,
          type: :text,
          is_hsm: true,
          flow: :outbound
        })
        |> Repo.preload([:receiver], force: true)

      assert {:ok, %Oban.Job{args: %{payload: payload}}} =
               Glific.Providers.Swiftchat.Message.send_text(message, %{
                 is_hsm: true,
                 template_id: session_template.id,
                 params: ["Priya", "ORD-123"]
               })

      assert payload["type"] == "template"
      assert payload["template"]["name"] == "order_confirmation"
      assert payload["template"]["parameters"] == ["Priya", "ORD-123"]
      assert payload["to"] == contact.phone

      assert_enqueued(worker: Worker, prefix: attrs.global_schema)
      Oban.drain_queue(queue: :swiftchat)

      message = Messages.get_message!(message.id)
      assert message.bsp_message_id != nil
      assert message.bsp_status == :enqueued
    end

    test "errors when the template row has no bsp_id set (seed helper not run yet)", attrs do
      language = Fixtures.language_fixture()

      {:ok, unmapped_template} =
        Glific.Templates.do_create_session_template(%{
          label: "Unmapped Template",
          shortcode: "unmapped_template",
          body: "Hi {{1}}",
          type: :text,
          is_hsm: true,
          status: "APPROVED",
          number_parameters: 1,
          language_id: language.id,
          organization_id: attrs.organization_id
        })

      contact = Fixtures.contact_fixture(attrs)

      message =
        Fixtures.message_fixture(%{
          organization_id: attrs.organization_id,
          sender_id: Partners.organization_contact_id(attrs.organization_id),
          receiver_id: contact.id,
          type: :text,
          is_hsm: true,
          flow: :outbound
        })
        |> Repo.preload([:receiver], force: true)

      assert {:error, error_msg} =
               Glific.Providers.Swiftchat.Message.send_text(message, %{
                 is_hsm: true,
                 template_id: unmapped_template.id,
                 params: ["Priya"]
               })

      assert error_msg =~ "no bsp_id set"
      refute_enqueued(worker: Worker, prefix: attrs.global_schema)
    end

    test "errors when template_id is missing from attrs", attrs do
      contact = Fixtures.contact_fixture(attrs)

      message =
        Fixtures.message_fixture(%{
          organization_id: attrs.organization_id,
          sender_id: Partners.organization_contact_id(attrs.organization_id),
          receiver_id: contact.id,
          type: :text,
          is_hsm: true,
          flow: :outbound
        })
        |> Repo.preload([:receiver], force: true)

      assert {:error, error_msg} =
               Glific.Providers.Swiftchat.Message.send_text(message, %{is_hsm: true, params: []})

      assert error_msg =~ "missing a template_id"
    end

    test "end-to-end via Messages.create_and_send_hsm_message/1 (HSM gating enforced, no SwiftChat-specific code)",
         attrs do
      session_template = approved_swiftchat_template(attrs.organization_id, "order_confirmation")
      # bsp_status: :session_and_hsm + optin_time set by the default contact
      # fixture — Contacts.can_send_message_to?/2's existing, provider-agnostic
      # gate (lib/glific/contacts.ex) allows this HSM send with zero
      # SwiftChat-specific gating code.
      contact = Fixtures.contact_fixture(attrs)

      assert {:ok, message} =
               %{
                 template_id: session_template.id,
                 receiver_id: contact.id,
                 parameters: ["Priya", "ORD-123"]
               }
               |> Messages.create_and_send_hsm_message()

      assert_enqueued(worker: Worker, prefix: attrs.global_schema)
      Oban.drain_queue(queue: :swiftchat)

      message = Messages.get_message!(message.id)
      assert message.is_hsm == true
      assert message.flow == :outbound
      assert message.bsp_message_id != nil
      assert message.bsp_status == :enqueued
    end

    test "HSM gating blocks a send to a contact with no active session/opt-in (provider-agnostic gate)",
         attrs do
      session_template = approved_swiftchat_template(attrs.organization_id, "order_confirmation")

      contact =
        Fixtures.contact_fixture(
          Map.merge(attrs, %{bsp_status: :none, optin_time: nil, optin_status: false})
        )

      assert {:error, error_message} =
               %{
                 template_id: session_template.id,
                 receiver_id: contact.id,
                 parameters: ["Priya", "ORD-123"]
               }
               |> Messages.create_and_send_hsm_message()

      assert error_message =~ "invalid BSP status"
      refute_enqueued(worker: Worker, prefix: attrs.global_schema)
    end
  end
end
