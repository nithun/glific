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

  # TODO(Q2-rate-limit): SwiftChat's per-organization send-rate limit is
  # still unpublished (the official Postman collection documents a 429
  # response but no numeric limit — PRD-001-tasks Open Question Q2).
  # `bsp_limit` is not yet seeded on the swiftchat Provider row's `keys`
  # (unlike Gupshup's `keys["bsp_limit"]`), so this mirrors Maytapi's
  # fallback-constant pattern until confirmed against a live account.
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
        # SwiftChat's "to" is the recipient's real mobile number (confirmed
        # via the Postman collection), so it doubles as the simulator check —
        # same as Gupshup's payload["destination"].
        if Contacts.simulator_contact?(payload["to"] || "") do
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
    ApiClient.send_message(org_id, payload)
    |> ResponseHandler.handle_response(message)
  end
end
