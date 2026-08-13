defmodule Glific.Communications.MessageInteractiveCapabilityTest do
  @moduledoc """
  PRD-005 T14 / ADR-016 rule 3: capability is declared, not inferred. An
  unsupported (provider, interactive type) pair must be rejected loudly at
  the `Communications.Message.send_message/2` dispatch chokepoint, before
  the provider module is ever reached — and every currently-supported
  (provider, type) pair must keep sending exactly as before (R2).
  """
  use Glific.DataCase, async: false
  use Oban.Pro.Testing, repo: Glific.Repo

  alias Glific.{
    Communications,
    Contacts,
    Messages,
    Messages.Message,
    Notifications,
    Partners,
    Partners.Provider,
    Repo,
    Seeds.SeedsDev,
    Templates.InteractiveTemplate
  }

  setup %{organization_id: organization_id} = attrs do
    organization = SeedsDev.seed_organizations()
    SeedsDev.seed_contacts(organization)
    SeedsDev.seed_interactives(organization)

    Tesla.Mock.mock(fn
      %{method: :post} ->
        %Tesla.Env{
          status: 200,
          body: Jason.encode!(%{"status" => "submitted", "messageId" => Faker.String.base64(36)})
        }
    end)

    receiver_attrs = %{
      name: "some receiver",
      phone: "101013131" <> Integer.to_string(System.unique_integer([:positive])),
      optin_time: ~U[2010-04-17 14:00:00Z],
      last_message_at: DateTime.utc_now(),
      bsp_status: :session_and_hsm,
      organization_id: organization_id
    }

    {:ok, receiver} = Contacts.create_contact(receiver_attrs)

    Map.put(attrs, :receiver_id, receiver.id)
  end

  @spec fetch_seeded_interactive(non_neg_integer(), String.t()) :: InteractiveTemplate.t()
  defp fetch_seeded_interactive(organization_id, label) do
    {:ok, interactive_template} =
      Repo.fetch_by(InteractiveTemplate, %{label: label, organization_id: organization_id})

    interactive_template
  end

  describe "gupshup (default org bsp): all 3 existing types still send — R2 regression lock-in" do
    test "quick_reply, list, location_request_message all still succeed", %{
      organization_id: organization_id,
      receiver_id: receiver_id
    } do
      for {label, type} <- [
            {"Quick Reply Text", :quick_reply},
            {"Interactive list", :list},
            {"Send Location", :location_request_message}
          ] do
        interactive_template = fetch_seeded_interactive(organization_id, label)

        message_attrs = %{
          body: nil,
          flow: :outbound,
          receiver_id: receiver_id,
          organization_id: organization_id,
          interactive_template_id: interactive_template.id,
          type: type
        }

        assert {:ok, _message} = Messages.create_and_send_message(message_attrs)
      end
    end
  end

  describe "maytapi (never implements MessageBehaviour's send_interactive/2): rejected loudly, before dispatch" do
    setup %{organization_id: organization_id} do
      {:ok, maytapi_provider} = Repo.fetch_by(Provider, %{shortcode: "maytapi"})

      organization = Partners.get_organization!(organization_id)
      Partners.update_organization(organization, %{bsp_id: maytapi_provider.id})

      organization = Partners.get_organization!(organization_id)
      Partners.remove_organization_cache(organization.id, organization.shortcode)
      Partners.fill_cache(organization)

      :ok
    end

    test "quick_reply send is rejected with a clear, actionable error — not the generic 'Check Gupshup Setting' rescue message",
         %{organization_id: organization_id, receiver_id: receiver_id} do
      interactive_template = fetch_seeded_interactive(organization_id, "Quick Reply Text")

      notification_count_before =
        Notifications.count_notifications(%{filter: %{organization_id: organization_id}})

      message_attrs = %{
        body: nil,
        flow: :outbound,
        receiver_id: receiver_id,
        organization_id: organization_id,
        interactive_template_id: interactive_template.id,
        type: :quick_reply
      }

      assert {:error, error_msg} = Messages.create_and_send_message(message_attrs)
      assert error_msg =~ "maytapi"
      assert error_msg =~ "quick_reply"
      refute error_msg =~ "Check Gupshup Setting"

      # T18: the rejection must leave the message at status :error (never stuck
      # :enqueued) and must produce a Notifications row — the same outcome an
      # NGO admin would see for any other failed send. Fetched fresh from the
      # DB (not the in-memory struct handed to send_message/2) so the
      # assertion actually exercises the `Messages.update_message/2` write in
      # `Communications.Message`'s private `log_error/2`.
      persisted_message = Repo.get_by!(Message, receiver_id: receiver_id)
      assert persisted_message.status == :error

      notification_count_after =
        Notifications.count_notifications(%{filter: %{organization_id: organization_id}})

      assert notification_count_after == notification_count_before + 1

      [notification | _] =
        Notifications.list_notifications(%{
          filter: %{organization_id: organization_id},
          opts: %{order: :desc, limit: 1, offset: 0}
        })

      assert notification.message =~ "maytapi"
      assert notification.message =~ "quick_reply"
    end

    test "send_message/2 itself returns the rejection directly, confirming the provider module is never reached",
         %{organization_id: organization_id, receiver_id: receiver_id} do
      interactive_template = fetch_seeded_interactive(organization_id, "Interactive list")

      {:ok, message} =
        %{
          body: nil,
          flow: :outbound,
          receiver_id: receiver_id,
          organization_id: organization_id,
          sender_id: Partners.organization_contact_id(organization_id),
          interactive_template_id: interactive_template.id,
          interactive_content: interactive_template.interactive_content,
          type: :list
        }
        |> Messages.create_message()

      assert {:error, error_msg} = Communications.Message.send_message(message)
      assert error_msg =~ "maytapi"
      assert error_msg =~ "list"
    end
  end
end
