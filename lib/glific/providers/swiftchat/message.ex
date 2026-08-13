defmodule Glific.Providers.Swiftchat.Message do
  @moduledoc """
  Message API layer between application and SwiftChat.

  Implemented so far: `send_text/2` (T-04, and its HSM/template branch as
  of T-10), `receive_text/1` (T-05), media send/receive (T-08:
  `send_image/2`, `send_video/2`, `send_document/2`, `send_audio/2`,
  `receive_media/1`), interactive send/receive (T-09: `send_interactive/2`
  for `quick_reply`/`list`, `receive_interactive/1` for `button_response` /
  `multi_select_button_response` / `persistent_menu_response`). Each
  otherwise-unimplemented callback fails loudly (logged error or raise)
  rather than silently building a wrong payload against an unconfirmed
  endpoint shape.
  """

  @behaviour Glific.Providers.MessageBehaviour

  alias Glific.{
    Caches,
    Communications,
    Messages.Message,
    Repo
  }

  import Ecto.Query, warn: false
  require Logger

  @not_implemented "Glific.Providers.Swiftchat.Message: not implemented (see PRD-001-tasks T-04/T-05/T-08/T-10)"

  @doc """
  Sends a plain-text message via SwiftChat.

  Body shape confirmed from the official Postman collection
  (`Message > Send-Text-Message`):

      {"to": "+91XXXXXXXXXX", "type": "text", "text": {"body": "..."}}

  `to` is the recipient's real mobile number — confirming ADR-001's
  primary branch. Outbound needs no SwiftChat-side user id at all;
  `contact.phone` is the destination, exactly like Gupshup.

  **HSM/template branch (T-10, ADR-005 phase 1):** `Communications.Message.send_message/2`
  dispatches every `:text`-typed message here regardless of `is_hsm`
  (`@type_to_token` in `lib/glific/communications/message.ex` maps
  `text: :send_text` unconditionally — mirrors Gupshup's `send_text/2`,
  which likewise receives `attrs[:is_hsm]` rather than being routed to a
  separate template callback; `MessageBehaviour` defines no
  `send_template/2`). When `attrs[:is_hsm]` is true, we build the
  confirmed template-send body instead of the plain-text body:

      {"to": "...", "type": "template",
       "template": {"name": "<bsp_id>", "parameters": [<positional...>]}}

  per `docs/prds/PRD-001-spike-notes.md`'s "Templates" bonus finding and
  ADR-005: SwiftChat templates are created per-merchant and keyed by
  **name**, not a numeric id, so phase 1's manual mapping stores the
  template name in `SessionTemplate.bsp_id` — the seed helper
  (`Glific.Scripts.SwiftchatTemplates`) is what populates it. `attrs`
  carries `template_id`/`params` set by
  `Glific.Messages.hsm_message_params/3` (`lib/glific/messages.ex`); we
  need the session template's `bsp_id`, so unlike Gupshup (which reuses
  `attrs[:template_uuid]`, itself set to `session_template.uuid` at
  approval time and never fetched again here) we look the template row up
  by `attrs[:template_id]` to read `bsp_id` directly — `attrs` alone does
  not carry it.
  """
  @impl Glific.Providers.MessageBehaviour
  @spec send_text(Message.t(), map()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()} | {:error, String.t()}
  def send_text(message, attrs \\ %{}) do
    if Map.get(attrs, :is_hsm, false) do
      send_hsm_text(message, attrs)
    else
      %{
        "type" => "text",
        "text" => %{"body" => message.body}
      }
      |> check_size(message.body)
      |> put_destination(message)
      |> send_message(message, attrs)
    end
  end

  # Builds the confirmed SwiftChat template-send payload (ADR-005 phase 1,
  # T-10). `attrs[:template_id]` is the Glific `session_templates.id` set
  # by `Glific.Messages.hsm_message_params/3`; `attrs[:params]` is the
  # already-parsed (contact-var-substituted) positional parameter list —
  # `Messages.check_for_hsm_message/2` renames the caller's `:params` key
  # to `:parameters` before calling `create_and_send_hsm_message/1`, but
  # `hsm_message_params/3` puts the final list back under `:params` for
  # the provider layer (mirrors Gupshup's `attrs[:params]` usage in
  # `Gupshup.Worker.process_gupshup/4`).
  @spec send_hsm_text(Message.t(), map()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()} | {:error, String.t()}
  defp send_hsm_text(message, attrs) do
    template_id = Map.get(attrs, :template_id)
    parameters = Map.get(attrs, :params, []) || []

    case fetch_template_bsp_id(template_id) do
      {:ok, bsp_id} ->
        %{
          "type" => "template",
          "template" => %{
            "name" => bsp_id,
            "parameters" => parameters
          }
        }
        |> put_destination(message)
        |> send_message(message, attrs)

      {:error, error} ->
        {:error, error}
    end
  end

  @spec fetch_template_bsp_id(non_neg_integer() | nil) :: {:ok, String.t()} | {:error, String.t()}
  defp fetch_template_bsp_id(nil), do: {:error, "SwiftChat HSM send is missing a template_id"}

  defp fetch_template_bsp_id(template_id) do
    case Repo.fetch(Glific.Templates.SessionTemplate, template_id) do
      {:ok, %{bsp_id: bsp_id}} when is_binary(bsp_id) and bsp_id != "" ->
        {:ok, bsp_id}

      {:ok, _template} ->
        {:error,
         "SwiftChat template id #{template_id} has no bsp_id set — run the T-10 seed helper (Glific.Scripts.SwiftchatTemplates) first"}

      {:error, _reason} ->
        {:error, "SwiftChat HSM send: template id #{template_id} not found"}
    end
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

  @doc """
  Sends an interactive message via SwiftChat, mapping Glific's
  interactive-content shape (`message.interactive_content`, produced by
  `InteractiveTemplate`/`Flows.ContactAction`) onto the closest SwiftChat
  outbound shape.

  **Mapping decision (T-09, PRD-001 §3.2), documented here since it's not
  a 1:1 name match:**

  - Glific `quick_reply` (`interactive_content` has `"content"` +
    `"options"`, a flat list of up to a few reply buttons — see
    `lib/glific/seeds/seeds_flows.ex`) -> SwiftChat `type: "button"`
    (`Message > Send-Button-Message` in the Postman collection). This is
    the closest shape: both are a body + a flat list of tappable reply
    buttons.

  - Glific `list` (`interactive_content` has `"title"`, `"body"`,
    `"globalButtons"`, and `"items"` — each item a section with its own
    `"options"`, WhatsApp's *list message* concept, see
    `test/glific/templates/interactive_template_test.exs`) -> SwiftChat
    **`multi_select_button`** (`Message > Send-Multi-Select-Button-Message`),
    NOT `card`. Reasoning: `card` requires a mandatory `header.image` with
    a SwiftChat media id per card (`Message > Send-Card-Message`) — Glific's
    `list` content carries no image at all, so a card mapping would need to
    fabricate a required field. `multi_select_button` needs no image and
    accepts a flat list of `{icon, type, body, reply}` buttons, which is
    what a flattened `items[].options[]` list already is (WhatsApp's
    section grouping has no SwiftChat equivalent, so sections are
    flattened — each item's `"title"` is prefixed onto its options'
    `"title"` when there is more than one section, so the user can still
    tell sections apart in a flat button list). This is a lossy mapping
    (no section headers, no per-item subtitle) but is the only one of
    SwiftChat's two multi-option shapes that doesn't require an
    unavailable field.

  - Glific `location_request_message` (the third interactive type per
    `Glific.Enums.InteractiveMessageType`) has **no SwiftChat equivalent**
    anywhere in the documented message-type palette (spike notes list
    card/article/rich-input/action/location/scorecard/video-stream, none
    of which round-trips a location *request*, only an outgoing location
    pin) -> fails loudly via `Glific.log_error/2` naming the unsupported
    variant, per this task's hard requirement not to guess a payload.

  Buttons carry no `icon`/`type` concept in Glific's interactive content,
  so both are set to SwiftChat's plain-text button defaults
  (`icon: ""`, `type: "text"`) — mirrors how `caption/1` defaults an
  absent Glific field to an empty string elsewhere in this module.
  `reply` (the value echoed back on tap, per the Postman body) is set to
  the button's own title, since Glific's quick-reply/list options carry
  no separate reply-payload field distinct from the display title.
  """
  @impl Glific.Providers.MessageBehaviour
  @spec send_interactive(Message.t(), map()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()} | {:error, String.t()}
  def send_interactive(message, attrs \\ %{}) do
    interactive_content = message.interactive_content

    case interactive_content["type"] do
      "quick_reply" ->
        build_button_payload(interactive_content)
        |> put_destination(message)
        |> send_message(message, attrs)

      "list" ->
        build_multi_select_button_payload(interactive_content)
        |> put_destination(message)
        |> send_message(message, attrs)

      other_type ->
        # F-086(b): construct the `{:error, reason}` tuple explicitly
        # rather than returning `Glific.log_error/2`'s result implicitly —
        # `log_error/2` does today return `{:error, error}` (verified:
        # `lib/glific.ex:362-373`, and already locked in by the
        # "location_request_message ... is rejected, not guessed" test
        # below), but this call site should not depend on a caller
        # reading that implementation detail to know it's error-safe for
        # `with` chains.
        reason =
          "SwiftChat: unsupported interactive message variant #{other_type || "nil"} for message id #{message.id} — no SwiftChat equivalent exists (see send_interactive/2 moduledoc), send skipped"

        Glific.log_error(reason)
        {:error, reason}
    end
  end

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

  @doc """
  F-082(c): unreachable by design, not merely unimplemented. SwiftChat's
  documented inbound webhook `type` values (`docs/prds/PRD-001-spike-notes.md`
  §3) never include a location/location-request reply, and
  `GlificWeb.Providers.Swiftchat.Plugs.Shunt`'s dispatch clauses only ever
  route `text`/`interactive`/`media` types to a handler — everything else
  (including any future `location`-shaped `type`) falls to the catch-all
  `unknown` action, which never calls this module at all. This callback
  exists purely to satisfy `MessageBehaviour`; a shunt/router edit that
  routes real traffic here would hit this raise, so keep this comment in
  sync if that dispatch ever changes.
  """
  @impl Glific.Providers.MessageBehaviour
  @spec receive_location(payload :: map()) :: map()
  def receive_location(_params), do: raise(RuntimeError, message: @not_implemented)

  @doc """
  Normalizes an inbound SwiftChat interactive-reply webhook payload — one
  of `button_response`, `multi_select_button_response`, or
  `persistent_menu_response` — into Glific's standard inbound-message map.
  All three share the same envelope, keyed by `params["type"]`, and land
  the type-specific payload under that same key. Shapes confirmed
  (`docs/prds/PRD-001-spike-notes.md` §3):

      button_response:               {"button_index": 1, "body": "Class 1"}
      multi_select_button_response:  [{"button_index": 1, "body": "..."}, ...]
      persistent_menu_response:      {"id": "...", "body": "..."}

  **`button_response`** (T-05): `body` is used directly as the reply text.

  **`multi_select_button_response`** (T-09): a *list* of `{button_index,
  body}` selections — there is no single `body` to lift. No other Glific
  BSP provider has a genuine multi-select inbound reply to set a
  precedent from (Gupshup/Maytapi's `receive_interactive/1` both handle
  single-selection replies only — grepped, confirmed), so this joins the
  selected bodies with `", "` into one reply string — a comparable join
  convention already exists for checkbox-style answers in
  `Flows.Router.update_context_results/4`
  (`msg.body |> Glific.make_set() |> MapSet.to_list()`, `lib/glific/flows/router.ex`),
  which likewise collapses a set of selections into one `msg.body`-shaped
  answer — chosen so a flow's `@results.<key>.input` reads as a single
  human-readable line rather than forcing every downstream flow node to
  know it should parse a list.

  **`persistent_menu_response`** (T-09): `body` is used directly as the
  reply text, same as `button_response` — it is a single-selection menu
  reply, just from a different UI surface (SwiftChat's persistent menu
  vs. an inline button).

  `interactive_content` always carries the raw type-specific payload so a
  flow's interactive-result handling (`Flows.Router.update_context_results/4`,
  which merges `msg.interactive_content` into flow results for
  `:quick_reply`/`:list` message types) has the original shape available,
  not just the derived body string. `Messages.Message.interactive_content`
  is an Ecto `:map` field (`field(:interactive_content, :map, ...)`,
  `lib/glific/messages/message.ex`) — a bare list fails to cast (silently,
  via `handle_inbound_create_result/2`'s changeset-error branch, which
  logs and drops the message rather than raising) — so
  `multi_select_button_response`'s list payload is wrapped under a
  `"selections"` key rather than stored as a raw list.
  """
  @impl Glific.Providers.MessageBehaviour
  @spec receive_interactive(payload :: map()) :: map()
  def receive_interactive(params) do
    type = params["type"]
    interactive_payload = params[type]

    %{
      bsp_message_id: params["message_id"],
      body: interactive_reply_body(type, interactive_payload),
      interactive_content: wrap_interactive_content(interactive_payload),
      sender: %{
        phone: params["from"],
        name: params["from"]
      }
    }
  end

  @spec wrap_interactive_content(list() | map() | nil) :: map()
  defp wrap_interactive_content(selections) when is_list(selections),
    do: %{"selections" => selections}

  defp wrap_interactive_content(payload) when is_map(payload), do: payload
  defp wrap_interactive_content(_payload), do: %{}

  @spec interactive_reply_body(String.t() | nil, list() | map() | nil) :: String.t()
  defp interactive_reply_body("multi_select_button_response", selections)
       when is_list(selections) do
    selections
    |> Enum.map(& &1["body"])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
  end

  defp interactive_reply_body(_type, payload) when is_map(payload), do: payload["body"]
  defp interactive_reply_body(_type, _payload), do: nil

  @doc """
  F-082(c): unreachable by design, same reasoning as `receive_location/1`
  above — SwiftChat's documented webhook `type` values
  (`docs/prds/PRD-001-spike-notes.md` §3) carry no billing-event concept,
  and `GlificWeb.Providers.Swiftchat.Plugs.Shunt` has no dispatch clause
  that could ever route a payload here. Exists only to satisfy
  `MessageBehaviour`.
  """
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

  # Builds a SwiftChat `type: "button"` payload from a Glific `quick_reply`
  # interactive_content map. Shape confirmed from the Postman collection's
  # `Message > Send-Button-Message`:
  #
  #     {"type": "button", "button": {"body": {"type": "text", "text": {"body": "..."}},
  #      "buttons": [{"icon", "type", "body", "reply"}, ...], "allow_custom_response": false},
  #      "rating_type": "thumb"}
  #
  # `interactive_content["content"]["text"]` is Glific's quick_reply body text
  # (see `lib/glific/seeds/seeds_flows.ex`); `interactive_content["options"]`
  # is the flat list of `{"type", "title"}` reply buttons.
  @spec build_button_payload(map()) :: map()
  defp build_button_payload(interactive_content) do
    body_text = get_in(interactive_content, ["content", "text"]) || ""
    options = interactive_content["options"] || []

    %{
      "type" => "button",
      "button" => %{
        "body" => %{"type" => "text", "text" => %{"body" => body_text}},
        "buttons" => Enum.map(options, &option_to_button/1),
        "allow_custom_response" => false
      },
      "rating_type" => "thumb"
    }
  end

  # Builds a SwiftChat `type: "button"` / `multi_select_button` payload from
  # a Glific `list` interactive_content map. Shape confirmed from the
  # Postman collection's `Message > Send-Multi-Select-Button-Message`:
  #
  #     {"type": "button", "multi_select_button": {"body": {"type": "text", "text": {"body": "..."}},
  #      "multi_select_button": [{"icon", "type", "body", "reply"}, ...],
  #      "allow_custom_response": false}, "rating_type": "thumb"}
  #
  # See `send_interactive/2`'s moduledoc for why `list` maps here and not to
  # `card` (card requires a mandatory per-card image id that Glific's list
  # content never carries). WhatsApp-list "sections" (`items[]`, each with
  # its own `options[]`) have no SwiftChat equivalent, so they are
  # flattened into one button list; when there is more than one section its
  # title is prefixed onto each of its options' titles so the grouping
  # isn't silently lost.
  @spec build_multi_select_button_payload(map()) :: map()
  defp build_multi_select_button_payload(interactive_content) do
    body_text = interactive_content["body"] || interactive_content["title"] || ""
    items = interactive_content["items"] || []

    flatten_multiple_sections? = length(items) > 1

    buttons =
      items
      |> Enum.flat_map(fn item ->
        section_title = item["title"]
        options = item["options"] || []

        Enum.map(options, fn option ->
          option
          |> maybe_prefix_section_title(section_title, flatten_multiple_sections?)
          |> option_to_button()
        end)
      end)

    %{
      "type" => "button",
      "multi_select_button" => %{
        "body" => %{"type" => "text", "text" => %{"body" => body_text}},
        "multi_select_button" => buttons,
        "allow_custom_response" => false
      },
      "rating_type" => "thumb"
    }
  end

  @spec maybe_prefix_section_title(map(), String.t() | nil, boolean()) :: map()
  defp maybe_prefix_section_title(option, section_title, true)
       when is_binary(section_title) and section_title != "" do
    Map.update(option, "title", section_title, &"#{section_title}: #{&1}")
  end

  defp maybe_prefix_section_title(option, _section_title, _flatten?), do: option

  # A Glific quick_reply/list option (`{"type", "title"}`) carries no
  # separate SwiftChat `icon`/`reply` concept — `reply` (the value echoed
  # back on tap) is the option's own title, since Glific has no separate
  # reply-payload field distinct from the display title. Two live-API
  # constraints the Postman placeholders (`<button-type>`, `<button-icon>`)
  # never documented, both discovered in the 2026-07-02 live round-trip:
  # `type` is a VISUAL style with enum [solid, dotted] (400 code-1), and
  # `icon` is REQUIRED non-empty (400 code-1 "icon is not allowed to be
  # empty") with "registration" confirmed accepted live (201) — matching
  # the docs' error-11 hint ("Allowed icon formats are registration and
  # edit-registration").
  @spec option_to_button(map()) :: map()
  defp option_to_button(option) do
    title = option["title"] || ""

    %{
      "icon" => "registration",
      "type" => "solid",
      "body" => title,
      "reply" => title
    }
  end

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
  #
  # F-082(b): a broadcast to N recipients sharing the same media builds a
  # send per recipient, and each one ran this synchronous Tesla GET in the
  # broadcast-enqueue loop's own process — N redundant network round-trips
  # for what is, for a broadcast, always the same URL. Cached per
  # `(organization_id, source_url)` via `Glific.Caches` (the codebase's
  # existing org-scoped caching idiom, `lib/glific/CLAUDE.md`) rather than
  # moved into the worker: the worker only runs once an Oban job already
  # exists, but the deliberate, tested contract here (see "oversize media"
  # below) is a SYNCHRONOUS reject at enqueue — no job is ever created for
  # oversize media, and the caller gets `{:error, _}` immediately. Moving
  # the check into the worker would silently turn that into an
  # asynchronous failure instead (the send would enqueue successfully and
  # only fail later); caching keeps the existing contract while removing
  # the redundant per-recipient network calls.
  #
  # Uses `Caches.get/3` + `Caches.set/4` (a manual read/check/write)
  # rather than `Caches.fetch/3`'s fallback form deliberately: Cachex's
  # `fetch/3` dispatches a cache-miss fallback to its own `Courier`
  # process pool to de-duplicate concurrent misses, which would run the
  # Tesla GET below in a *different* process than the caller — breaking
  # `Tesla.Mock`'s per-process mock resolution in every test that
  # exercises a media send. Running the GET inline here keeps it in the
  # caller's own process. A transient check failure (network error,
  # timeout) is deliberately NOT cached — so a momentary blip doesn't
  # wrongly fail-open (or fail-closed) every later send to the same URL
  # for the rest of the cache TTL.
  @max_media_bytes 64 * 1024 * 1024
  @spec check_media_size(map(), Glific.Messages.MessageMedia.t() | nil) :: map()
  defp check_media_size(%{error: _} = payload, _message_media), do: payload

  defp check_media_size(payload, %{source_url: url, organization_id: organization_id})
       when is_binary(url) and url != "" do
    cache_key = {:swiftchat_media_size_check, url}

    result =
      case Caches.get(organization_id, cache_key) do
        {:ok, false} -> media_size_check_result(organization_id, cache_key, url)
        {:ok, cached_result} -> cached_result
      end

    case result do
      :ok -> payload
      {:error, message} -> %{error: message}
    end
  end

  defp check_media_size(payload, _message_media), do: payload

  @spec media_size_check_result(non_neg_integer(), tuple(), String.t()) ::
          :ok | {:error, String.t()}
  defp media_size_check_result(organization_id, cache_key, url) do
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

        result =
          if is_integer(content_length) and content_length > @max_media_bytes do
            {:error,
             "Media size exceeds the 64 MB SwiftChat limit (#{content_length} bytes) — send rejected"}
          else
            :ok
          end

        Caches.set(organization_id, cache_key, result)
        result

      error ->
        Glific.log_error(
          "SwiftChat: could not verify media size before send — #{Glific.SafeLog.safe_inspect(error)}"
        )

        # Transient failure — fail open (matches the pre-caching
        # behavior) but never write it to the cache, so a later, healthy
        # check on the same URL gets a fresh answer rather than being
        # stuck on this blip for the rest of the TTL.
        :ok
    end
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
