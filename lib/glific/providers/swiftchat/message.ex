defmodule Glific.Providers.Swiftchat.Message do
  @moduledoc """
  Message API layer between application and SwiftChat.

  Implemented so far: `send_text/2` (T-04), `receive_text/1` and
  `receive_interactive/1` for button replies (T-05), media send/receive
  (T-08: `send_image/2`, `send_video/2`, `send_document/2`, `send_audio/2`,
  `receive_media/1`). Remaining interactive subtypes and template sends
  are later tasks (T-09/T-10) — each unimplemented callback fails loudly
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

  @doc """
  Sends an image message via SwiftChat.

  Body shape confirmed from the official Postman collection (URL
  pass-through branch, ADR-006):

      {"to": "+91XXXXXXXXXX", "type": "image", "image": {"url": "...", "body": "<caption>"}}

  `message.media.source_url` is the public URL Glific already stores for
  every media message (Gupshup mirror); `body` carries the caption per the
  inbound `image` payload shape documented in
  `docs/prds/PRD-001-spike-notes.md` §3, which SwiftChat's outbound side
  mirrors (`body` is the caption key across image/document/audio).
  """
  @impl Glific.Providers.MessageBehaviour
  @spec send_image(Message.t(), map()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()} | {:error, String.t()}
  def send_image(message, attrs \\ %{}) do
    message_media = message.media

    %{
      "type" => "image",
      "image" => %{"url" => message_media.source_url, "body" => caption(message_media.caption)}
    }
    |> check_media_size(message_media)
    |> put_destination(message)
    |> send_message(message, attrs)
  end

  @doc """
  Sends an audio message via SwiftChat.

  SwiftChat natively supports audio (`audio/mpeg`, `audio/ogg` — see
  `docs/prds/PRD-001-spike-notes.md` §4), so this sends `type: "audio"`
  directly rather than applying ADR-002's audio->document fallback.
  ADR-002's fallback predates the confirmed docs and is now known-stale
  for SwiftChat specifically — see PRD-001-tasks T-08 handoff for the
  discrepancy note; ADR-002 itself is left unedited here (out of scope
  for a code change to revise) but should be revisited.

  Body shape CONFIRMED from the official Postman collection's
  `Send-Audio-Message-By-Media-URL` request:

      {"to": "+91XXXXXXXXXX", "type": "audio",
       "audio": {"url": "...", "title": "<caption>", "body": "<caption>"},
       "rating_type": "thumb"}

  `title` and `body` both carry the caption (SwiftChat's audio payload
  has both keys; `title` is a display-title placeholder — we set it from
  the same caption Glific stores, there being no separate title concept
  on `MessageMedia`). `rating_type` is optional per the send-text body's
  precedent and is omitted here (not set on any other media type either).
  """
  @impl Glific.Providers.MessageBehaviour
  @spec send_audio(Message.t(), map()) :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def send_audio(message, attrs \\ %{}) do
    message_media = message.media

    %{
      "type" => "audio",
      "audio" => %{
        "url" => message_media.source_url,
        "title" => caption(message_media.caption),
        "body" => caption(message_media.caption)
      }
    }
    |> check_media_size(message_media)
    |> put_destination(message)
    |> send_message(message, attrs)
  end

  @doc """
  Sends a video message via SwiftChat.

  Body shape CONFIRMED from the official Postman collection's
  `Send-Video-Message-By-Media-URL` request — video uses `title`, NOT
  `body`, for its caption-equivalent field (unlike image/document):

      {"to": "+91XXXXXXXXXX", "type": "video", "video": {"url": "...", "title": "<caption>"}}
  """
  @impl Glific.Providers.MessageBehaviour
  @spec send_video(Message.t(), map()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()} | {:error, String.t()}
  def send_video(message, attrs \\ %{}) do
    message_media = message.media

    %{
      "type" => "video",
      "video" => %{"url" => message_media.source_url, "title" => caption(message_media.caption)}
    }
    |> check_media_size(message_media)
    |> put_destination(message)
    |> send_message(message, attrs)
  end

  @doc """
  Sends a document message via SwiftChat.

  Body shape CONFIRMED from the official Postman collection's
  `Send-Document-Message-By-Media-URL` request:

      {"to": "+91XXXXXXXXXX", "type": "document", "document": {"url": "...", "name": "...", "body": "<caption>"}}

  `name` carries the filename (mirrors Gupshup's `filename`), `body`
  carries the caption. Glific's `MessageMedia` has a single `caption`
  field with no separate filename concept, so both are set from the
  same value (matches Gupshup's `send_document/2`, which does the same
  with `filename: message_media.caption`).
  """
  @impl Glific.Providers.MessageBehaviour
  @spec send_document(Message.t(), map()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def send_document(message, attrs \\ %{}) do
    message_media = message.media

    %{
      "type" => "document",
      "document" => %{
        "url" => message_media.source_url,
        "name" => caption(message_media.caption),
        "body" => caption(message_media.caption)
      }
    }
    |> check_media_size(message_media)
    |> put_destination(message)
    |> send_message(message, attrs)
  end

  @doc """
  SwiftChat has no sticker message type (`docs/adrs/ADR-002-swiftchat-fourth-bsp.md`:
  "its message-type palette differs from WhatsApp's (no audio, no
  sticker)"). Per ADR-002's decision, sticker maps to image, logged via
  `Glific.log_error/2` (non-fatal) — unlike the audio fallback, this
  ADR-002 branch is NOT contradicted by the confirmed docs (SwiftChat
  genuinely has no sticker type), so it stays as designed.
  """
  @impl Glific.Providers.MessageBehaviour
  @spec send_sticker(Message.t(), map()) :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def send_sticker(message, attrs \\ %{}) do
    Glific.log_error(
      "SwiftChat has no sticker type — sending sticker as image (ADR-002 fallback), message id #{message.id}"
    )

    send_image(message, attrs)
  end

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

  @doc """
  Normalizes an inbound SwiftChat media webhook payload (`image`,
  `document`, `video`, `audio`) into Glific's standard inbound-media map.

  Confirmed payload shapes (`docs/prds/PRD-001-spike-notes.md` §3):

      image:    {"id", "body" (caption), "content_type"}
      document: {"id", "name", "body" (caption), "content_type"}
      video:    {"id", "title", "content_type"}
      audio:    {"id", "title", "body" (caption), "content_type"}

  **Design decision (T-08):** unlike Gupshup/Maytapi, SwiftChat's inbound
  media payload carries a *media id*, not a URL — the URL must be
  resolved via a separate `GET /bots/{Bot-ID}/media/{Media-ID}` call
  (`ApiClient.get_media_url/2`) that returns a presigned S3 URL expiring
  in ~15 minutes. Rather than making `receive_media/1` perform I/O (it's
  a pure normalizer everywhere else in the provider behaviour, and the
  media-id -> URL resolution needs the organization's credentials, which
  this function doesn't receive), the **caller resolves the URL first**
  and passes it in under a `"resolved_url"` key alongside the raw
  webhook payload — see
  `GlificWeb.Providers.Swiftchat.Controllers.MessageController.media/2`.

  **Trade-off, flagged explicitly (see PRD-001-tasks T-08 handoff):** the
  presigned URL is resolved once, at receive time, and stored directly as
  `MessageMedia.url`/`source_url` — simplest, matches how Glific already
  stores inbound media source_urls today (Gupshup: no expiry to begin
  with). But SwiftChat's presigned URL expires in ~15 minutes, so the
  stored URL goes stale shortly after receipt for any org that reads it
  later (a flow re-broadcasting the media, someone opening the
  conversation UI after 15 minutes, exports, etc.). Glific's GCS worker
  (`Glific.GCS.GcsWorker`) re-uploads inbound media to permanent storage
  on a periodic sweep for orgs with GCS enabled, which mitigates this
  case (permanent `gcs_url` set within the sweep interval). **Orgs
  without GCS enabled have no mitigation and will see broken media links
  after ~15 minutes** — this is a real limitation, not silently absorbed;
  flagged as a follow-up task, not fixed here.

  If URL resolution fails (`"resolved_url"` missing/nil — e.g. the
  SwiftChat media API errored or the id already expired), we still
  normalize and store the message with `url`/`source_url` set to a
  sentinel marker (`"unresolved://<media-id>"`) rather than dropping the
  inbound message — mirroring Gupshup's `receive_media/1`, which also
  never validates that its URL resolves before storing
  (`Communications.Message.receive_media/1` calls
  `Messages.create_message_media/1` unconditionally). `url` and
  `source_url` are required, non-blank fields on `MessageMedia`
  (`validate_required/2` rejects `""` same as `nil`), so a sentinel is
  required, not merely a stylistic choice; it also stays greppable, and
  keeps the media-id around for a manual resolve/backfill.
  """
  @impl Glific.Providers.MessageBehaviour
  @spec receive_media(payload :: map()) :: map()
  def receive_media(params) do
    type = params["type"]
    media_payload = params[type] || %{}

    resolved_url =
      case params["resolved_url"] do
        url when is_binary(url) and url != "" ->
          url

        _ ->
          Glific.log_error(
            "SwiftChat inbound media URL could not be resolved for message_id #{params["message_id"]}, type #{type} — storing message with a sentinel media URL"
          )

          "unresolved://" <> to_string(media_payload["id"])
      end

    %{
      bsp_message_id: params["message_id"],
      caption: media_payload["body"] || media_payload["title"],
      url: resolved_url,
      content_type: media_payload["content_type"],
      source_url: resolved_url,
      sender: %{
        phone: params["from"],
        name: params["from"]
      }
    }
  end

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

  @doc false
  @spec caption(nil | String.t()) :: String.t()
  defp caption(nil), do: ""
  defp caption(caption), do: caption

  # 64 MB, confirmed max media size (`docs/prds/PRD-001-spike-notes.md` §4).
  # No shared per-BSP size-validation mechanism exists to plug into:
  # `Glific.Messages.validate_media/2` is a GraphQL/frontend attach-time
  # check with a hardcoded, Gupshup-tuned size table (not BSP-parameterized,
  # never called from any send builder — grepped and confirmed), and
  # `MessageMedia` stores no byte-size field. Gupshup/Maytapi's builders
  # also do no send-time size check. Enforced here at enqueue via an HTTP
  # HEAD-equivalent content-length check on the media URL, mirroring
  # `Messages.do_validate_media/2`'s technique, failing fast with a
  # logged, user-visible send error per ADR-006.
  @max_media_bytes 64 * 1024 * 1024
  @spec check_media_size(map(), Glific.Messages.MessageMedia.t() | nil) :: map()
  defp check_media_size(%{error: _} = payload, _message_media), do: payload

  defp check_media_size(payload, %{source_url: url}) when is_binary(url) and url != "" do
    case Tesla.get(url, opts: [adapter: [recv_timeout: 10_000]]) do
      {:ok, %Tesla.Env{status: status, headers: headers}} when status in 200..299 ->
        content_length =
          headers
          |> Enum.into(%{})
          |> Map.get("content-length")
          |> Glific.parse_maybe_integer()
          |> case do
            {:ok, value} -> value
            _ -> nil
          end

        if is_integer(content_length) and content_length > @max_media_bytes do
          %{
            error:
              "Media size exceeds the 64 MB SwiftChat limit (#{content_length} bytes) — send rejected"
          }
        else
          payload
        end

      error ->
        Glific.log_error(
          "SwiftChat: could not verify media size before send — #{Glific.SafeLog.safe_inspect(error)}"
        )

        payload
    end
  end

  defp check_media_size(payload, _message_media), do: payload

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
