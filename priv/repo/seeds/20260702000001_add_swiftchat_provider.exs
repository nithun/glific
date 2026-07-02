defmodule Glific.Seeds.Seeds20260702000001AddSwiftchatProvider do
  @moduledoc """
  Seeds the SwiftChat BSP Provider row (PRD-001-tasks T-02, ADR-002).

  Mirrors the seeded Gupshup Provider row's `keys`/`secrets` shape
  (`20200723172939_add_glific_data.exs`, `providers/0`) — `keys` names the
  handler/worker modules the runtime dispatch in
  `Glific.Communications.provider_handler/1` /`provider_worker/1` resolves
  (lesson L-005: no code change to `communications.ex` needed); `secrets`
  describes the org-supplied credential fields rendered by Settings ->
  Integrations.
  """
  use Glific.Seeds.Seed

  import Ecto.Query

  alias Glific.{
    Partners.Provider,
    Repo
  }

  envs([:dev, :test, :prod])

  tags([:swiftchat])

  def up(_repo, _opts) do
    add_swiftchat()
  end

  def down(_repo, _opts) do
    from(p in Provider, where: p.shortcode == "swiftchat")
    |> Repo.delete_all()
  end

  @spec add_swiftchat() :: any()
  defp add_swiftchat() do
    query = from(p in Provider, where: p.shortcode == "swiftchat")

    # add only if it does not exist
    if !Repo.exists?(query),
      do:
        Repo.insert!(%Provider{
          name: "SwiftChat",
          shortcode: "swiftchat",
          description: "Setup SwiftChat to send and receive WhatsApp messages",
          group: "bsp",
          is_required: false,
          keys: %{
            url: %{
              type: :string,
              label: "BSP Home Page",
              default: "https://dashboard.swiftchat.ai/",
              view_only: true
            },
            api_end_point: %{
              type: :string,
              label: "API End Point",
              # Confirmed from the official Postman collection (variable
              # `URL`); keep in sync with
              # `Glific.Providers.Swiftchat.ApiClient`'s @swiftchat_url.
              default: "https://v1-api.swiftchat.ai/api",
              view_only: false
            },
            handler: %{
              type: :string,
              label: "Inbound Message Handler",
              default: "Glific.Providers.Swiftchat.Message",
              view_only: true
            },
            worker: %{
              type: :string,
              label: "Outbound Message Worker",
              default: "Glific.Providers.Swiftchat.Worker",
              view_only: true
            }
          },
          secrets: %{
            api_key: %{
              type: :string,
              label: "API Key",
              default: nil,
              view_only: false
            },
            bot_id: %{
              type: :string,
              label: "Bot ID",
              default: nil,
              view_only: false
            },
            merchant_id: %{
              type: :string,
              label: "Merchant ID",
              default: nil,
              view_only: false
            }
          }
        })
  end
end
