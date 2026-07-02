defmodule Glific.Providers.Swiftchat.Message do
  @moduledoc """
  Message API layer between application and SwiftChat.

  Scope (PRD-001-tasks T-04): `send_text/2` only. Media, interactive,
  sticker/audio-fallback, and template sends are separate later tasks
  (T-08/T-09/T-10) and are NOT implemented here — each unimplemented
  callback returns a logged `{:error, "not implemented"}` rather than
  silently building a wrong payload, so an accidental call fails loudly
  instead of hitting a guessed, unconfirmed endpoint shape.

  Inbound normalizers (`receive_*/1`) are T-05 (inbound stack) and are also
  NOT implemented here; the `@behaviour` callbacks are still declared for
  compile-time contract coverage, returning a clear error instead.
  """

  @behaviour Glific.Providers.MessageBehaviour

  alias Glific.{
    Communications,
    Messages.Message
  }

  import Ecto.Query, warn: false
  require Logger

  @not_implemented "Glific.Providers.Swiftchat.Message: not implemented (see PRD-001-tasks T-04/T-05/T-08/T-09/T-10)"

  @doc """
  Sends a plain-text message via SwiftChat.

  # TODO(T-01): the exact JSON body shape (field names, whether `type` is
  # required, whether there's a `msgid`/reference field like Gupshup's
  # `msgid`) is unconfirmed — PRD-001 §2 could not extract the full
  # message-send request body from the Postman collection. The shape below
  # is a best guess mirroring SwiftChat's documented message-type palette
  # (`type: "text"`, a `text` object with a `body` field, per common
  # WhatsApp-Business-API-shaped conventions SwiftChat's docs reference).
  # Confirm and adjust once the live spike lands.

  Per ADR-001 (primary branch): the SwiftChat user id is read from
  `contact.fields["swiftchat_user_id"]`, written by the inbound normalizer
  on every message (T-05, not yet implemented). A contact that has never
  messaged in has no id yet and the send fails gracefully with a
  user-visible, logged error instead of hitting SwiftChat with a bad
  destination.
  """
  @impl Glific.Providers.MessageBehaviour
  @spec send_text(Message.t(), map()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()} | {:error, String.t()}
  def send_text(message, attrs \\ %{}) do
    %{
      "type" => "text",
      "text" => %{"body" => message.body}
    }
    |> check_size(message.body)
    |> put_destination(message)
    |> send_message(message, attrs)
  end

  @doc false
  @impl Glific.Providers.MessageBehaviour
  @spec send_image(Message.t(), map()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()} | {:error, String.t()}
  def send_image(_message, _attrs \\ %{}), do: Glific.log_error(@not_implemented)

  @doc false
  @impl Glific.Providers.MessageBehaviour
  @spec send_audio(Message.t(), map()) :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def send_audio(_message, _attrs \\ %{}), do: Glific.log_error(@not_implemented)

  @doc false
  @impl Glific.Providers.MessageBehaviour
  @spec send_video(Message.t(), map()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()} | {:error, String.t()}
  def send_video(_message, _attrs \\ %{}), do: Glific.log_error(@not_implemented)

  @doc false
  @impl Glific.Providers.MessageBehaviour
  @spec send_document(Message.t(), map()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def send_document(_message, _attrs \\ %{}), do: Glific.log_error(@not_implemented)

  @doc false
  @impl Glific.Providers.MessageBehaviour
  @spec send_sticker(Message.t(), map()) :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def send_sticker(_message, _attrs \\ %{}), do: Glific.log_error(@not_implemented)

  @doc false
  @impl Glific.Providers.MessageBehaviour
  @spec send_interactive(Message.t(), map()) :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def send_interactive(_message, _attrs \\ %{}), do: Glific.log_error(@not_implemented)

  @doc false
  @impl Glific.Providers.MessageBehaviour
  @spec receive_text(payload :: map()) :: map()
  def receive_text(_params), do: raise(RuntimeError, message: @not_implemented)

  @doc false
  @impl Glific.Providers.MessageBehaviour
  @spec receive_media(payload :: map()) :: map()
  def receive_media(_params), do: raise(RuntimeError, message: @not_implemented)

  @doc false
  @impl Glific.Providers.MessageBehaviour
  @spec receive_location(payload :: map()) :: map()
  def receive_location(_params), do: raise(RuntimeError, message: @not_implemented)

  @doc false
  @impl Glific.Providers.MessageBehaviour
  @spec receive_interactive(payload :: map()) :: map()
  def receive_interactive(_params), do: raise(RuntimeError, message: @not_implemented)

  @doc false
  @impl Glific.Providers.MessageBehaviour
  @spec receive_billing_event(payload :: map()) :: {:ok, map()} | {:error, String.t()}
  def receive_billing_event(_params), do: {:error, @not_implemented}

  @max_size 4096
  @spec check_size(map(), String.t()) :: map()
  defp check_size(%{error: _} = payload, _text), do: payload

  defp check_size(payload, text) do
    if String.length(text) < @max_size,
      do: payload,
      else: %{error: "Message size greater than #{@max_size} characters"}
  end

  # ADR-001 primary branch: SwiftChat user id lives in contact.fields,
  # written on inbound (T-05). Contacts that never messaged in have none.
  @spec put_destination(map(), Message.t()) :: map()
  defp put_destination(%{error: _} = payload, _message), do: payload

  defp put_destination(payload, message) do
    case swiftchat_user_id(message.receiver) do
      nil ->
        %{
          error:
            "Contact #{message.receiver_id} has no swiftchat_user_id yet (never messaged in) — cannot send"
        }

      user_id ->
        payload
        |> Map.put("to", user_id)
        # carried separately (never sent to SwiftChat) so the worker can
        # detect simulator contacts by real phone, mirroring Gupshup's
        # `payload["destination"]` check — the SwiftChat "to" field is the
        # bot-scoped user id, not a phone, so it can't be used for that.
        |> Map.put("destination", message.receiver.phone)
    end
  end

  @spec swiftchat_user_id(Glific.Contacts.Contact.t() | Ecto.Association.NotLoaded.t() | nil) ::
          String.t() | nil
  defp swiftchat_user_id(%Ecto.Association.NotLoaded{}), do: nil
  defp swiftchat_user_id(nil), do: nil

  defp swiftchat_user_id(contact),
    do: get_in(contact.fields, ["swiftchat_user_id", "value"])

  @doc false
  @spec send_message(map(), Message.t(), map()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()} | {:error, String.t()}
  defp send_message(%{error: error} = _payload, _message, _attrs), do: {:error, error}

  defp send_message(payload, message, attrs) do
    # carry the node reference along, so we can track this send when we
    # receive the response for a particular message (mirrors Gupshup's
    # "msgid" convention).
    request_body = Map.put(payload, "msgid", message.uuid)

    create_oban_job(message, request_body, attrs)
  end

  @doc false
  @spec to_minimal_map(map()) :: map()
  defp to_minimal_map(attrs) do
    Map.take(attrs, [:params, :template_id, :template_uuid, :is_hsm, :template_type])
  end

  @spec create_oban_job(Message.t(), map(), map()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  defp create_oban_job(message, request_body, attrs) do
    attrs = to_minimal_map(attrs)
    worker_module = Communications.provider_worker(message.organization_id)
    worker_args = %{message: Message.to_minimal_map(message), payload: request_body, attrs: attrs}

    worker_module.create_changeset(worker_args, scheduled_at: message.send_at)
    |> Oban.insert()
  end
end
