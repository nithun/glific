defmodule Glific.Providers.Swiftchat.ResponseHandlerTest do
  @moduledoc """
  Covers the send + error paths (T-04 acceptance criterion) and the
  lesson L-003 invariant: a raw `Tesla.Env`/error term must never be
  `inspect/1`-ed directly (bearer-token leak risk) — every error log line
  must go through `Glific.SafeLog.safe_inspect/1`.
  """
  use Glific.DataCase, async: false

  alias Glific.{
    Fixtures,
    Messages,
    Providers.Swiftchat.ResponseHandler
  }

  describe "handle_response/2" do
    test "success (201, JSON-string body) updates the message with the bsp_message_id",
         attrs do
      message = Fixtures.message_fixture(attrs)

      # confirmed SwiftChat success shape: 201 {"id": "<uuid>"} — body as a
      # raw JSON string, the shape Tesla hands over when no content-type
      # header triggers the JSON middleware's decode.
      response = %Tesla.Env{
        status: 201,
        body: Jason.encode!(%{"id" => "swiftchat-msg-1"})
      }

      assert :ok = ResponseHandler.handle_response({:ok, response}, message)

      updated_message = Messages.get_message!(message.id)
      assert updated_message.bsp_message_id == "swiftchat-msg-1"
      assert updated_message.bsp_status == :enqueued
    end

    test "success (201, already-decoded map body) also lands the bsp_message_id", attrs do
      message = Fixtures.message_fixture(attrs)

      # on a real response, Tesla.Middleware.JSON decodes application/json
      # bodies to a map before the handler sees them — both shapes must work.
      response = %Tesla.Env{
        status: 201,
        body: %{"id" => "swiftchat-msg-2"}
      }

      assert :ok = ResponseHandler.handle_response({:ok, response}, message)

      updated_message = Messages.get_message!(message.id)
      assert updated_message.bsp_message_id == "swiftchat-msg-2"
      assert updated_message.bsp_status == :enqueued
    end

    test "client error (4xx) marks the message as errored without retrying", attrs do
      message = Fixtures.message_fixture(attrs)

      response = %Tesla.Env{
        status: 401,
        body: Jason.encode!(%{"error" => "Invalid Bearer token"})
      }

      assert :ok = ResponseHandler.handle_response({:ok, response}, message)

      updated_message = Messages.get_message!(message.id)
      assert updated_message.bsp_status == :error
    end

    test "server error (5xx HTTP response) marks the message as errored and triggers an Oban retry",
         attrs do
      message = Fixtures.message_fixture(attrs)

      # a genuine `{:ok, %Tesla.Env{status: 500}}` HTTP response (as opposed
      # to a transport-level `{:error, ...}` failure) falls through to the
      # `_ ->` clause, mirroring Gupshup's response_handler.ex line-for-line:
      # handle_error_response/2 always returns `{:error, response.body}`, so
      # this is a non-:ok, retry-triggering result — Oban will retry the job.
      response = %Tesla.Env{
        status: 500,
        body: Jason.encode!(%{"error" => "Internal Server Error"})
      }

      assert {:error, _reason} = ResponseHandler.handle_response({:ok, response}, message)

      updated_message = Messages.get_message!(message.id)
      assert updated_message.bsp_status == :error
    end

    test "a raw Tesla error term never leaks a bearer token in the logged error body",
         attrs do
      message = Fixtures.message_fixture(attrs)

      # simulate a Tesla.Env carrying a live Authorization header the way a
      # real SwiftChat request would build its client (lesson L-003) —
      # handle_response must route this through SafeLog.safe_inspect/1,
      # never raw inspect/1, before it reaches Messages.update_message/2's
      # `errors` field or the Logger line.
      leaky_env = %Tesla.Env{
        status: 500,
        body: "boom",
        __client__: %Tesla.Client{
          pre: [{Tesla.Middleware.Headers, :call, [[{"authorization", "Bearer super-secret"}]]}]
        }
      }

      assert :ok = ResponseHandler.handle_response({:error, leaky_env}, message)

      updated_message = Messages.get_message!(message.id)
      serialized_errors = Jason.encode!(updated_message.errors)

      refute serialized_errors =~ "super-secret"
      assert updated_message.bsp_status == :error
    end

    test "a timeout error triggers Oban retry (returns an :error tuple)", attrs do
      message = Fixtures.message_fixture(attrs)

      assert {:error, _reason} = ResponseHandler.handle_response({:error, :timeout}, message)
    end
  end
end
