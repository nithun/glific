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
    Repo
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

  describe "unimplemented callbacks (T-05/T-08/T-09/T-10 scope, not built here)" do
    test "send_image/2 fails loudly instead of guessing an unconfirmed payload shape", attrs do
      message = Fixtures.message_fixture(attrs)
      assert {:error, error_msg} = Glific.Providers.Swiftchat.Message.send_image(message)
      assert error_msg =~ "not implemented"
    end

    test "receive_text/1 raises instead of silently normalizing an unconfirmed webhook shape" do
      assert_raise RuntimeError, ~r/not implemented/, fn ->
        Glific.Providers.Swiftchat.Message.receive_text(%{"payload" => %{}})
      end
    end
  end
end
