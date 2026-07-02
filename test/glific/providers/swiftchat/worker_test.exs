defmodule Glific.Providers.Swiftchat.WorkerTest do
  @moduledoc """
  Multi-tenancy invariant (lesson L-001, blocking): `perform/1` MUST call
  `Repo.put_process_state(org_id)` as its first line, because a fresh Oban
  process has no organization context in the process dictionary. This test
  runs the worker in a brand-new process (via `Task.async`) that has never
  called `Repo.put_organization_id/1`, to prove the worker seeds its own
  context rather than relying on a caller having done so.
  """
  use Glific.DataCase, async: false
  use Oban.Pro.Testing, repo: Glific.Repo

  alias Glific.{
    Fixtures,
    Messages.Message,
    Partners,
    Partners.Provider,
    Providers.Swiftchat.Worker,
    Repo
  }

  setup %{organization_id: organization_id} = attrs do
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

  describe "perform/1 multi-tenancy (L-001, blocking)" do
    test "seeds organization context in a fresh process with none set", attrs do
      sender = Fixtures.contact_fixture(attrs)

      receiver = Fixtures.contact_fixture(attrs)

      message =
        Fixtures.message_fixture(%{
          organization_id: attrs.organization_id,
          sender_id: sender.id,
          receiver_id: receiver.id,
          body: "hello",
          type: :text
        })
        |> Repo.preload([:receiver, :sender, :media])

      # Real Oban args are JSON-round-tripped (string keys), so build the
      # job args the same way to match what perform/1 actually receives.
      job_args =
        %{
          "message" => Message.to_minimal_map(message),
          "payload" => %{
            "type" => "text",
            "text" => %{"body" => "hello"},
            "to" => receiver.phone
          },
          "attrs" => %{}
        }
        |> Jason.encode!()
        |> Jason.decode!()

      # Run inside a brand new process (Task) that never called
      # Repo.put_organization_id/1 — this is what a real Oban process looks
      # like. If Worker.perform/1 forgot Repo.put_process_state/1 first,
      # any downstream call reading the process dictionary (e.g.
      # Partners.organization/1 caching Repo.put_organization_id) would
      # blow up or silently operate with no org scoping.
      task =
        Task.async(fn ->
          assert Repo.get_organization_id() == nil
          result = Worker.perform(%Oban.Job{args: job_args})
          {result, Repo.get_organization_id()}
        end)

      {result, organization_id_seen_inside_worker} = Task.await(task)

      assert result == :ok
      assert organization_id_seen_inside_worker == attrs.organization_id
    end
  end
end
