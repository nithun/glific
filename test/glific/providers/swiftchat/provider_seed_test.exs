defmodule Glific.Providers.Swiftchat.ProviderSeedTest do
  @moduledoc """
  T-02 acceptance criterion: "provider row seeds on fresh DB; credential
  form fields render (verify via GraphQL provider query); seed test
  passes." The DB-level assertions run here; the seed itself already ran
  as part of `mix test`'s DB setup (`priv/repo/seeds/20260702000001_add_swiftchat_provider.exs`).
  """
  use Glific.DataCase, async: true

  alias Glific.{Partners.Provider, Repo}

  test "the swiftchat provider row exists with the expected shape" do
    assert {:ok, provider} =
             Repo.fetch_by(Provider, %{shortcode: "swiftchat"}, skip_organization_id: true)

    assert provider.name == "SwiftChat"
    assert provider.group == "bsp"

    # keys names the handler/worker modules Communications.provider_handler/1
    # and provider_worker/1 resolve at runtime (lesson L-005) — no
    # communications.ex change needed, only this row has to be correct.
    assert provider.keys["handler"]["default"] == "Glific.Providers.Swiftchat.Message"
    assert provider.keys["worker"]["default"] == "Glific.Providers.Swiftchat.Worker"

    # secrets shape drives the credential form fields rendered by
    # Settings -> Integrations with zero frontend code.
    assert Map.has_key?(provider.secrets, "api_key")
    assert Map.has_key?(provider.secrets, "bot_id")
    assert Map.has_key?(provider.secrets, "merchant_id")
  end

  test "the handler and worker module names resolve to real, loaded modules" do
    assert {:ok, provider} =
             Repo.fetch_by(Provider, %{shortcode: "swiftchat"}, skip_organization_id: true)

    # mirrors Glific.Communications.provider_handler/1's own resolution:
    # module-name strings are stored without the "Elixir." prefix.
    handler_module =
      ("Elixir." <> provider.keys["handler"]["default"]) |> String.to_existing_atom()

    worker_module = ("Elixir." <> provider.keys["worker"]["default"]) |> String.to_existing_atom()

    assert Code.ensure_loaded?(handler_module)
    assert Code.ensure_loaded?(worker_module)
    assert function_exported?(handler_module, :send_text, 2)
    assert function_exported?(worker_module, :perform, 1)
  end
end
