defmodule Glific.Providers.Swiftchat.ResponseHandler do
  @moduledoc """
  Module for handling response from the SwiftChat API
  or handling response for simulators.
  """
  alias Glific.{
    Communications,
    Messages.Message
  }

  require Logger

  @doc false
  @spec handle_response({:ok, Tesla.Env.t()}, Message.t() | {:error, any()}) ::
          :ok | {:error, String.t()}
  def handle_response({:ok, response}, message) do
    case response do
      %Tesla.Env{status: status} when status in 200..299 ->
        Communications.Message.handle_success_response(response, message)
        :ok

      # Not authorized, job succeeded, we should return an ok, so we don't retry
      %Tesla.Env{status: status} when status in 400..499 ->
        Communications.Message.handle_error_response(response, message)
        :ok

      _ ->
        Communications.Message.handle_error_response(response, message)
    end
  end

  @default_tesla_error %{
    "payload" => %{
      "payload" => %{
        "reason" => "Error sending message due to network issues or SwiftChat Outage"
      }
    }
  }

  def handle_response(error, message) do
    # never inspect a raw Tesla.Env / BSP error term directly — it may carry
    # the Bearer token (lesson L-003) — always go through safe_inspect_error/1.
    Logger.error(
      "Error calling API Client for org_id: #{message["organization_id"]} error: #{safe_inspect_error(error)}"
    )

    err =
      Communications.Message.handle_error_response(
        %{
          body:
            put_in(
              @default_tesla_error,
              ["payload", "payload", "error"],
              safe_inspect_error(error)
            )
        },
        message
      )

    case error do
      {:error, reason} when reason in [:timeout, :closed_timeout, :closed] ->
        # This will kick off the Oban retry mechanism for timeout-related errors
        err

      _ ->
        :ok
    end
  end

  # `Glific.SafeLog.safe_inspect/1` only strips `__client__` off a bare
  # `%Tesla.Env{}` — it does NOT unwrap a `{:ok | :error, %Tesla.Env{}}`
  # tuple, which is exactly the shape ApiClient.send_message/2's `with`
  # fallthrough (credential errors) or a raw Tesla transport failure
  # produces here. Unwrap those shapes first so the Bearer token embedded
  # in `__client__`'s middleware chain never reaches a log line or the
  # `errors` column (lesson L-003).
  @spec safe_inspect_error(term()) :: String.t()
  defp safe_inspect_error({:ok, %Tesla.Env{} = env}),
    do: "{:ok, #{Glific.SafeLog.safe_inspect(env)}}"

  defp safe_inspect_error({:error, %Tesla.Env{} = env}),
    do: "{:error, #{Glific.SafeLog.safe_inspect(env)}}"

  defp safe_inspect_error(term), do: Glific.SafeLog.safe_inspect(term)
end
