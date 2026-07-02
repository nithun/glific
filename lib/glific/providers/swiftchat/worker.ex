defmodule Glific.Providers.Swiftchat.Worker do
  @moduledoc """
  A worker to handle send message processes for SwiftChat.
  """

  use Oban.Worker,
    queue: :swiftchat,
    max_attempts: 2,
    priority: 0

  alias Glific.{
    Contacts,
    Partners,
    Partners.Organization,
    Providers.Swiftchat.ApiClient,
    Providers.Swiftchat.ResponseHandler,
    Providers.Worker,
    Repo
  }

  # TODO(T-01): SwiftChat's real per-organization send-rate limit is
  # unknown (PRD-001-tasks Open Questions Q2). `bsp_limit` is not yet
  # seeded on the swiftchat Provider row's `keys` (unlike Gupshup's
  # `keys["bsp_limit"]`), so this mirrors Maytapi's fallback-constant
  # pattern until it's confirmed and, if needed, seeded.
  @default_bsp_limit 30

  @doc """
  Creates a Oban job changeset with args and Oban job options.
  """
  @spec create_changeset(map(), Keyword.t()) :: Oban.Job.changeset()
  def create_changeset(args, opts), do: __MODULE__.new(args, opts)

  @doc """
  Standard perform method to use Oban worker.

  Per lesson L-001 / ADR-002: `Repo.put_process_state(org_id)` MUST be the
  first line — a fresh Oban process has no organization context in the
  process dictionary, and every downstream call (Partners.organization/1,
  Messages.update_message/2, etc.) relies on it being set.
  """
  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, String.t()} | {:snooze, pos_integer()}
  def perform(%Oban.Job{args: %{"message" => message}} = job) do
    Repo.put_process_state(message["organization_id"])

    organization = Partners.organization(message["organization_id"])

    if is_nil(organization.services["bsp"]) do
      Worker.handle_credential_error(message)
    else
      perform(job, organization)
    end
  end

  @spec perform(Oban.Job.t(), Organization.t()) ::
          :ok | {:error, String.t()} | {:snooze, pos_integer()}
  defp perform(
         %Oban.Job{args: %{"message" => message, "payload" => payload}},
         organization
       ) do
    # ensure that we are under the rate limit, all rate limits are in requests/minutes
    case ExRated.check_rate(
           organization.shortcode <> ":swiftchat",
           # the bsp limit is per organization per shortcode
           1000,
           @default_bsp_limit
         ) do
      {:ok, _} ->
        if Contacts.simulator_contact?(payload["destination"] || "") do
          Worker.process_simulator(message)
        else
          process_swiftchat(organization.id, payload, message)
        end

      _ ->
        Worker.default_send_rate_handler()
    end
  end

  @spec process_swiftchat(non_neg_integer(), map(), map()) ::
          :ok | {:error, String.t()}
  defp process_swiftchat(org_id, payload, message) do
    # "destination" is Glific-internal bookkeeping (used above for
    # simulator detection since SwiftChat's "to" is a bot-scoped user id,
    # not a phone) — strip it before it reaches the SwiftChat API body.
    payload = Map.delete(payload, "destination")

    ApiClient.send_message(org_id, payload)
    |> ResponseHandler.handle_response(message)
  end
end
