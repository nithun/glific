defmodule Glific.Providers.Gupshup.Enterprise.MessageTest do
  @moduledoc """
  F-085: `parse_interactive_message/2` had no catch-all — any interactive
  type outside `:quick_reply`/`:list` (notably the seeded
  `location_request_message` interactive template type,
  `Glific.Enums.InteractiveMessageType`) hit a `FunctionClauseError`
  instead of a clear, actionable error. Covers the new loud-reject clause
  and locks in that the existing `:quick_reply`/`:list` positive-behavior
  clauses are untouched (R2 — no change to existing provider behavior).
  """
  use Glific.DataCase, async: true

  alias Glific.{Fixtures, Providers.Gupshup.Enterprise.Message, Repo}

  describe "send_interactive/2 catch-all (F-085)" do
    test "an unmapped interactive type is rejected with a clear error, not a crash",
         %{organization_id: organization_id} do
      sender = Fixtures.contact_fixture(%{organization_id: organization_id})
      receiver = Fixtures.contact_fixture(%{organization_id: organization_id})

      message =
        Fixtures.message_fixture(%{
          organization_id: organization_id,
          sender_id: sender.id,
          receiver_id: receiver.id,
          type: :location_request_message,
          flow: :outbound
        })

      attrs = %{
        interactive_content: %{
          "type" => "location_request_message",
          "body" => %{"type" => "text", "text" => "Please share your location"},
          "action" => %{"name" => "send_location"}
        }
      }

      assert {:error, error_msg} = Message.send_interactive(message, attrs)
      assert error_msg =~ "location_request_message"
    end

    test "an unrecognized/future interactive type atom is also rejected cleanly",
         %{organization_id: organization_id} do
      sender = Fixtures.contact_fixture(%{organization_id: organization_id})
      receiver = Fixtures.contact_fixture(%{organization_id: organization_id})

      message =
        Fixtures.message_fixture(%{
          organization_id: organization_id,
          sender_id: sender.id,
          receiver_id: receiver.id,
          type: :text,
          flow: :outbound
        })

      # `message.type` is what `send_interactive/2` actually dispatches on
      # (not a key inside `interactive_content`) — force a type this
      # provider has never mapped, mirroring how a brand-new ADR-016 type
      # would arrive before Gupshup Enterprise declares support for it.
      message = %{message | type: :some_future_interactive_type}

      attrs = %{interactive_content: %{"type" => "some_future_interactive_type"}}

      assert {:error, error_msg} = Message.send_interactive(message, attrs)
      assert error_msg =~ "some_future_interactive_type"
    end
  end

  describe "send_interactive/2 positive behavior unchanged (R2 regression)" do
    test "quick_reply still builds the confirmed buttons payload", %{organization_id: org_id} do
      sender = Fixtures.contact_fixture(%{organization_id: org_id})
      receiver = Fixtures.contact_fixture(%{organization_id: org_id})

      message =
        Fixtures.message_fixture(%{
          organization_id: org_id,
          sender_id: sender.id,
          receiver_id: receiver.id,
          type: :quick_reply,
          flow: :outbound
        })
        |> Repo.preload([:receiver], force: true)

      attrs = %{
        interactive_content: %{
          "type" => "quick_reply",
          "content" => %{"type" => "text", "text" => "Pick one"},
          "options" => [%{"title" => "Option A"}, %{"title" => "Option B"}]
        }
      }

      assert {:ok, %Oban.Job{args: %{payload: %{"message" => encoded_message}}}} =
               Message.send_interactive(message, attrs)

      assert %{"interactive_content" => %{"buttons" => buttons}} = Jason.decode!(encoded_message)
      assert length(buttons) == 2
      assert Enum.all?(buttons, &(&1["type"] == "reply"))
    end

    test "list still builds the confirmed sections payload", %{organization_id: org_id} do
      sender = Fixtures.contact_fixture(%{organization_id: org_id})
      receiver = Fixtures.contact_fixture(%{organization_id: org_id})

      message =
        Fixtures.message_fixture(%{
          organization_id: org_id,
          sender_id: sender.id,
          receiver_id: receiver.id,
          type: :list,
          flow: :outbound
        })
        |> Repo.preload([:receiver], force: true)

      attrs = %{
        interactive_content: %{
          "type" => "list",
          "globalButtons" => [%{"title" => "Menu"}],
          "items" => [
            %{"title" => "Section 1", "options" => [%{"title" => "Row 1"}]}
          ]
        }
      }

      assert {:ok, %Oban.Job{args: %{payload: %{"message" => encoded_message}}}} =
               Message.send_interactive(message, attrs)

      assert %{"interactive_content" => %{"button" => "Menu", "sections" => [section]}} =
               Jason.decode!(encoded_message)

      assert section["title"] == "Section 1"
      assert [%{"title" => "Row 1"}] = section["rows"]
    end
  end
end
