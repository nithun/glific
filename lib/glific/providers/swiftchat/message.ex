defmodule Glific.Providers.Swiftchat.Message do
  @moduledoc """
  Message API layer between application and SwiftChat.

  Implemented so far: `send_text/2` (T-04), `receive_text/1` and
  `receive_interactive/1` for button replies (T-05). Media, remaining
  interactive subtypes, sticker/audio-fallback, and template sends are
  later tasks (T-08/T-09/T-10) — each unimplemented callback fails loudly
  (logged error or raise) rather than silently building a wrong payload
  against an unconfirmed endpoint shape.
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

  Body shape confirmed from the official Postman collection
  (`Message > Send-Text-Message`):

      {"to": "+91XXXXXXXXXX", "type": "text", "text": {"body": "..."}}

  `to` is the recipient's real mobile number — confirming ADR-001's
  primary branch. Outbound needs no SwiftChat-side user id at all;
  `contact.phone` is the destination, exactly like Gupshup.
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

  @doc """
  Normalizes an inbound SwiftChat `text` webhook payload into Glific's
  standard inbound-message map.

  Envelope shape confirmed from the official Postman collection
  (`docs/prds/PRD-001-spike-notes.md` §3):

      %{
        "from" => "+91XXXXXXXXXX",
        "type" => "text",
        "timestamp" => ...,
        "message_id" => "...",
        "conversation_id" => "...",
        "conversation_initiated_by" => "...",
        "text" => %{"body" => "..."}
      }

  `from` is the user's real phone (ADR-001 primary branch, confirmed) —
  used directly as `sender.phone`, no synthetic phone / contact_type
  change. SwiftChat sends **no profile-name field** anywhere in the
  documented envelope (unlike Gupshup's `sender.name`) — `Contact.name`
  is optional at the schema level (`@optional_fields`, no
  `validate_required`), so leaving it nil would be valid, but a nameless
  contact is poor UX everywhere Glific displays a contact list/search
  result. We fall back to the phone number as the display name, the same
  fallback Glific already uses as its "no better name available" default
  (see `Contacts.simulator_contact?`/seed data patterns) — this is a
  display default we choose, not a field invented in the payload.

  Docs note new envelope/payload keys may appear over time — this
  normalizer reads only the documented keys and ignores everything else,
  so unknown extra keys never crash it.
  """
  @impl Glific.Providers.MessageBehaviour
  @spec receive_text(payload :: map()) :: map()
  def receive_text(params) do
    %{
      bsp_message_id: params["message_id"],
      body: get_in(params, ["text", "body"]),
      sender: %{
        phone: params["from"],
        name: params["from"]
      }
    }
  end

  @doc false
  @impl Glific.Providers.MessageBehaviour
  @spec receive_media(payload :: map()) :: map()
  def receive_media(_params), do: raise(RuntimeError, message: @not_implemented)

  @doc false
  @impl Glific.Providers.MessageBehaviour
  @spec receive_location(payload :: map()) :: map()
  def receive_location(_params), do: raise(RuntimeError, message: @not_implemented)

  @doc """
  Normalizes an inbound SwiftChat `button_response` webhook payload
  (button-reply — the reply body text that advances a flow). Shape
  confirmed from the spike notes:

      %{"from" => "...", "message_id" => "...",
        "button_response" => %{"button_index" => 1, "body" => "Class 1"}}

  `multi_select_button_response` and `persistent_menu_response` share the
  same envelope but carry richer payloads (a list, or an `id` field) —
  those are left for T-09 (interactive messages) to map onto Glific's
  interactive-content shape; this function handles the single
  `button_response` case only, which is cheap to land alongside T-05
  because it needs nothing beyond the confirmed envelope.
  """
  @impl Glific.Providers.MessageBehaviour
  @spec receive_interactive(payload :: map()) :: map()
  def receive_interactive(params) do
    button_response = params["button_response"] || %{}

    %{
      bsp_message_id: params["message_id"],
      body: button_response["body"],
      interactive_content: button_response,
      sender: %{
        phone: params["from"],
        name: params["from"]
      }
    }
  end

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

  # SwiftChat's "to" is the recipient's real mobile number (confirmed via
  # the Postman collection) — same as Gupshup's `:destination`. The worker
  # also uses payload["to"] for simulator-contact detection.
  @spec put_destination(map(), Message.t()) :: map()
  defp put_destination(%{error: _} = payload, _message), do: payload

  defp put_destination(payload, message) do
    case receiver_phone(message.receiver) do
      nil ->
        %{error: "Contact #{message.receiver_id} has no phone — cannot send via SwiftChat"}

      phone ->
        Map.put(payload, "to", phone)
    end
  end

  @spec receiver_phone(Glific.Contacts.Contact.t() | Ecto.Association.NotLoaded.t() | nil) ::
          String.t() | nil
  defp receiver_phone(%Ecto.Association.NotLoaded{}), do: nil
  defp receiver_phone(nil), do: nil
  defp receiver_phone(%{phone: phone}) when phone in [nil, ""], do: nil
  defp receiver_phone(%{phone: phone}), do: phone

  @doc false
  @spec send_message(map(), Message.t(), map()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()} | {:error, String.t()}
  defp send_message(%{error: error} = _payload, _message, _attrs), do: {:error, error}

  # Note: unlike Gupshup, the request body carries no extra `msgid` field —
  # SwiftChat's documented send body has no reference-id passthrough, and
  # unknown fields risk a 400 code-1 "Invalid request JSON". Tracking is by
  # the Oban job's `message` args; the 201 response's `{"id": ...}` becomes
  # the bsp_message_id in ResponseHandler.
  defp send_message(payload, message, attrs),
    do: create_oban_job(message, payload, attrs)

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
