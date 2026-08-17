defmodule Glific.Providers.Swiftchat.Template do
  @moduledoc """
  Module for handling template operations specific to SwiftChat.

  Phase 2 (`docs/prds/PRD-002-swiftchat-template-sync.md`, completing
  `docs/adrs/ADR-005-swiftchat-template-strategy.md`): this module now
  implements real SwiftChat template lifecycle sync — `submit_for_approval/1`
  posts a new template to SwiftChat, `update_hsm_templates/1` polls
  `GET /merchants/{Merchant-ID}/templates` for status changes AND pulls in
  templates created directly in the SwiftChat dashboard, and `delete/2`
  removes a Glific-managed template from SwiftChat. **Text templates only**
  in this phase (ADR-005's caveat, PRD-002's out-of-scope list) — media-header
  and interactive (button/list) templates are deferred.

  `Glific.Scripts.SwiftchatTemplates.upsert_template/6` (the phase-1 manual
  seed helper) is **not superseded/deleted** — it remains available as a
  documented manual fallback (e.g. template types this phase doesn't sync,
  or emergency `bsp_id` correction). See that module's moduledoc.

  **`update_hsm_templates/1` must never raise**: `Glific.Jobs.MinuteWorker`'s
  `"update_hsms"` cron branch calls
  `Partners.perform_all(&Templates.sync_hsms_from_bsp/1, ...)` unconditionally
  over every active organization; `Partners.perform_all/4`'s `rescue` wraps
  the *entire* iteration, not per-org, so one raising org would abort the
  batch for every other org in that cron tick. All BSP-call branches here
  return `{:error, "BSP Couldn't connect"}` on transient failure, matching
  Gupshup's existing contract (`Gupshup.Template.update_hsm_templates/1`).

  `import_templates/2`, `bulk_apply_templates/2`, `edit_approved_template/2`
  remain unimplemented — out of PRD-002's F-1-F-5 scope (T-06); their error
  messages name each operation explicitly rather than referring to a
  now-stale "phase 1 has no template API" framing.

  **F-114 (2026-08-14)**: the T-04 pull-sync import path originally built
  a `SessionTemplate` directly from the LIST response
  (`ApiClient.list_templates/1`), which was live-verified to carry NO
  `body` field — every dashboard-created template failed to import and the
  hourly cron logged the failure forever. Fixed by fetching each
  not-yet-known template individually (`ApiClient.get_template/2`) for its
  body before inserting. See `import_dashboard_template/3`'s doc.
  """

  @behaviour Glific.Providers.TemplateBehaviour

  alias Glific.{
    Notifications,
    Partners,
    Providers.Swiftchat.ApiClient,
    Repo,
    Templates,
    Templates.SessionTemplate
  }

  require Logger

  @unimplemented_ops "SwiftChat template %{op} is not implemented — see PRD-002 " <>
                       "(docs/prds/PRD-002-swiftchat-template-sync.md); submit-for-approval, " <>
                       "status sync, and delete ARE implemented. File a new PRD if %{op} is needed."

  @max_name_length 50

  # -- T-02: submit_for_approval/1 --------------------------------------

  @doc """
  Submits a new text template to SwiftChat for approval.

  Contract verified against `Glific.Templates.create_session_template/1`'s
  `is_hsm: true` branch (`lib/glific/templates.ex:142-154`), which validates
  `attrs` (shortcode charset, button shape, length) BEFORE calling the
  private `submit_for_approval/1` wrapper (`templates.ex:272-280`), which
  dispatches to `Provider.bsp_module(attrs.organization_id, :template).submit_for_approval/1`.
  `attrs` therefore already carries `shortcode`, `category`, `example`,
  `body`, `language_id`, `organization_id`, `type`, plus whatever else the
  GraphQL resolver passed straight through (mirrors Gupshup's `attrs` usage
  at `gupshup/template.ex:47-75`).

  Per PRD-001-spike-notes.md "Bonus findings" (Templates):
  `POST {base}/merchants/{Merchant-ID}/templates`, Bearer `{API-Key}`,
  `{"name": <a-z0-9_ max50>, "template": {"type": "text", "text": {"body": "..."}}}`.
  Success is `201 Created` — response body shape is not confirmed live (may
  be non-JSON `"Created"`), so both a JSON object body and a plain-string
  body are handled; either way the **submitted `name`** (not anything from
  the response) is the durable identifier, since SwiftChat templates are
  keyed by name, not a numeric id (spike finding) — stored into
  `SessionTemplate.bsp_id`, same field the phase-1 seed script already
  populates.
  """
  @spec submit_for_approval(map()) :: {:ok, SessionTemplate.t()} | {:error, any()}
  def submit_for_approval(%{type: type} = _attrs) when type not in [:text, "text"] do
    {:error, "SwiftChat template sync supports text templates only in this phase — see ADR-005"}
  end

  # F-081: `has_buttons`/`buttons` pass Glific's own `validate_button_template/1`
  # (button *shape* is valid) but this module's payload build only ever reads
  # `attrs.body` — buttons would be silently dropped end-to-end, and
  # `send_hsm_text/2` never sends button data either, so the save would look
  # successful while quietly shipping a text-only template. Reject loudly
  # instead of guessing a button payload SwiftChat's docs never confirmed
  # (mirrors the non-text-type guard above) until F-18 ships real button
  # support.
  def submit_for_approval(%{has_buttons: true} = _attrs) do
    {:error,
     "SwiftChat HSM templates with buttons are not supported yet — buttons would be " <>
       "silently dropped (see F-081); use a plain text template until F-18 ships button support"}
  end

  def submit_for_approval(attrs) do
    with {:ok, name} <- build_template_name(attrs),
         swiftchat_body <- glific_vars_to_swiftchat(attrs.body || ""),
         payload <- %{
           "name" => name,
           "template" => %{"type" => "text", "text" => %{"body" => swiftchat_body}}
         },
         {:ok, result} <- do_submit(attrs.organization_id, payload, name) do
      attrs
      |> Map.merge(%{
        number_parameters: Templates.template_parameters_count(attrs),
        bsp_id: name,
        shortcode: name,
        status: result.status,
        is_active: result.status == "APPROVED"
      })
      |> Templates.do_create_session_template()
    end
  end

  @spec do_submit(non_neg_integer(), map(), String.t()) ::
          {:ok, %{status: String.t()}} | {:error, any()}
  defp do_submit(organization_id, payload, name) do
    case ApiClient.create_template(organization_id, payload) do
      {:ok, %Tesla.Env{status: status}} when status in [200, 201] ->
        # Create response shape not confirmed live (may be a non-JSON
        # "Created" string) — SwiftChat's create call has no confirmed
        # terminal status in the response, so a freshly-submitted template
        # is PENDING until the next poll (T-03) confirms ACTIVE/REJECTED.
        {:ok, %{status: "PENDING"}}

      {:ok, %Tesla.Env{status: 409, body: body}} ->
        {:error,
         "SwiftChat template name '#{name}' already exists (409): " <>
           Glific.SafeLog.safe_inspect(body)}

      {:ok, %Tesla.Env{status: status, body: body}} ->
        Logger.error(
          "SwiftChat template submit failed (status #{status}): #{Glific.SafeLog.safe_inspect(body)}"
        )

        {:error, "BSP Couldn't submit for approval (status #{status})"}

      {:error, error} ->
        Logger.error("SwiftChat template submit failed: #{Glific.SafeLog.safe_inspect(error)}")

        {:error, "BSP Couldn't connect"}
    end
  end

  # SwiftChat name constraint: ^[a-z0-9_]{1,50}$ (PRD-001 spike notes).
  # Derive from the Glific shortcode (already validated to
  # ^[a-z0-9_]*$ by Templates.validate_hsm/1, but re-validate defensively
  # here since submit_for_approval/1 is a public callback that could be hit
  # directly, not just through create_session_template/1) — fail fast with
  # a clear error rather than letting SwiftChat 400 on an invalid name.
  @spec build_template_name(map()) :: {:ok, String.t()} | {:error, String.t()}
  defp build_template_name(%{shortcode: shortcode}) when is_binary(shortcode) do
    name = String.downcase(shortcode)

    cond do
      name == "" ->
        {:error, "SwiftChat template name cannot be blank"}

      String.length(name) > @max_name_length ->
        {:error,
         "SwiftChat template name '#{name}' exceeds the #{@max_name_length}-character limit"}

      not String.match?(name, ~r/^[a-z0-9_]{1,50}$/) ->
        {:error,
         "SwiftChat template name '#{name}' is invalid — only lowercase letters, digits, " <>
           "and underscores are allowed"}

      true ->
        {:ok, name}
    end
  end

  defp build_template_name(_attrs),
    do: {:error, "SwiftChat template submission requires a shortcode"}

  # -- F-4: variable dialect translation, shared both directions ---------

  @doc """
  Translates Glific's positional `{{n}}` variable syntax to SwiftChat's
  single-brace `{n}` syntax. Pure/mechanical — shared by `submit_for_approval/1`
  (this direction) and the pull-sync path in `update_hsm_templates/1`
  (reverse direction, `swiftchat_vars_to_glific/1`), per T-02's instruction
  not to inline the regex twice.
  """
  @spec glific_vars_to_swiftchat(String.t()) :: String.t()
  def glific_vars_to_swiftchat(body) when is_binary(body) do
    Regex.replace(~r/\{\{(\d+)\}\}/, body, "{\\1}")
  end

  def glific_vars_to_swiftchat(body), do: body

  @doc """
  Reverse of `glific_vars_to_swiftchat/1` — translates SwiftChat's `{n}`
  syntax back to Glific's `{{n}}`, used by the pull-sync path (T-04) when
  importing a dashboard-created template.
  """
  @spec swiftchat_vars_to_glific(String.t()) :: String.t()
  def swiftchat_vars_to_glific(body) when is_binary(body) do
    Regex.replace(~r/\{(\d+)\}/, body, "{{\\1}}")
  end

  def swiftchat_vars_to_glific(body), do: body

  @doc """
  Counts the number of unique positional variables (`{n}`) in a SwiftChat
  template body — reverse-direction counterpart of
  `Templates.template_parameters_count/1` (which counts Glific's `{{n}}`),
  used by the pull-sync path (T-04) to set `number_parameters` on an
  imported row.
  """
  @spec swiftchat_parameters_count(String.t()) :: non_neg_integer()
  def swiftchat_parameters_count(body) when is_binary(body) do
    ~r/\{(\d+)\}/
    |> Regex.scan(body)
    |> Enum.map(fn [_, n] -> n end)
    |> Enum.uniq()
    |> Enum.count()
  end

  def swiftchat_parameters_count(_body), do: 0

  # -- T-06: remaining phase-2 stubs --------------------------------------

  @doc """
  Not implemented — out of PRD-002's F-1-F-5 scope (T-06).
  """
  @spec import_templates(non_neg_integer(), String.t()) :: {:ok, any} | {:error, any}
  def import_templates(_organization_id, _data),
    do: {:error, String.replace(@unimplemented_ops, "%{op}", "import")}

  @doc """
  Not implemented — out of PRD-002's F-1-F-5 scope (T-06).
  """
  @spec bulk_apply_templates(non_neg_integer(), String.t()) :: {:ok, any} | {:error, any}
  def bulk_apply_templates(_organization_id, _data),
    do: {:error, String.replace(@unimplemented_ops, "%{op}", "bulk-apply")}

  @doc """
  Not implemented — out of PRD-002's F-1-F-5 scope (T-06).
  """
  @spec edit_approved_template(integer(), map()) :: {:ok, any} | {:error, any}
  def edit_approved_template(_template_id, _params),
    do: {:error, String.replace(@unimplemented_ops, "%{op}", "edit-approved-template")}

  @doc """
  Not implemented — SwiftChat has no Meta Template Library equivalent
  (upstream `feat: add template library feature flag and GraphQL support`,
  #5534, added this callback for Gupshup only).
  """
  @spec search_library_templates(non_neg_integer()) :: {:ok, list(map())} | {:error, String.t()}
  def search_library_templates(_organization_id), do: {:error, "Feature not available"}

  # -- T-03/T-04: update_hsm_templates/1 (status poll + pull sync) -------

  @doc """
  Polls SwiftChat's template list for this org and:
  - (T-03) updates `status`/`reason`/`is_active` for every Glific row whose
    `bsp_id` matches a SwiftChat template name, firing a Glific notification
    exactly once per status *transition* (not every poll tick);
  - (T-04) inserts any SwiftChat template with no matching local row
    (dashboard-created) as a new `session_templates` row, in the same pass
    (one list fetch, both directions).

  Called unconditionally for every active org by `Glific.Jobs.MinuteWorker`'s
  `"update_hsms"` cron branch via `Templates.sync_hsms_from_bsp/1`
  (`templates.ex:390-400`). Multi-tenancy: `Partners.perform_handler/4`
  (`partners.ex:889-900`, the function that ultimately invokes this
  callback via `Partners.perform_all/4`) already calls
  `Repo.put_process_state(org_id)` before dispatching — verified by reading
  that call site; no additional org-context call needed here (L-001).

  Never raises on BSP HTTP failure/non-200 — returns
  `{:error, "BSP Couldn't connect"}` matching Gupshup's existing contract.
  """
  @spec update_hsm_templates(non_neg_integer()) :: :ok | {:error, String.t()}
  def update_hsm_templates(org_id) do
    with {:ok, %Tesla.Env{status: 200, body: body}} <- ApiClient.list_templates(org_id),
         {:ok, decoded} <- decode_list_body(body) do
      entries = unwrap_template_list(decoded)
      sync_entries(org_id, entries)
      :ok
    else
      _ ->
        {:error, "BSP Couldn't connect"}
    end
  end

  # ApiClient uses Tesla.Middleware.JSON, so a JSON response body already
  # arrives decoded (a map); tolerate a raw string body defensively (e.g. a
  # non-JSON "Created"-style response, matching submit's defensiveness).
  @spec decode_list_body(any()) :: {:ok, map()} | {:error, any()}
  defp decode_list_body(body) when is_map(body), do: {:ok, body}
  defp decode_list_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_list_body(_body), do: {:error, "unexpected list response shape"}

  # The confirmed sample response nests as {"data": [[{...}]]} — an extra
  # list level vs. a flat array. Defensively accept both {"data": [[...]]}
  # and {"data": [...]} shapes (PRD-002 T-01 decision: code defensively,
  # do not trust the nesting blindly), flattening one level only when the
  # first element of "data" is itself a list.
  @spec unwrap_template_list(map()) :: [map()]
  defp unwrap_template_list(%{"data" => [first | _] = data}) when is_list(first),
    do: List.flatten(data)

  defp unwrap_template_list(%{"data" => data}) when is_list(data), do: data
  defp unwrap_template_list(_decoded), do: []

  @spec sync_entries(non_neg_integer(), [map()]) :: :ok
  defp sync_entries(org_id, entries) do
    organization = Partners.organization(org_id)

    Enum.each(entries, fn entry ->
      case Repo.get_by(SessionTemplate, bsp_id: entry["name"], organization_id: org_id) do
        nil ->
          # T-04: dashboard-created template, not yet known to Glific.
          import_dashboard_template(org_id, organization, entry)

        %SessionTemplate{} = existing ->
          # T-03: known template — sync status/reason on a real transition.
          sync_existing_template(existing, entry)
      end
    end)

    :ok
  end

  # -- T-03: status mapping + sync -----------------------------------

  @doc """
  Defensive status mapping (PRD-002 T-01 decision): `ACTIVE` -> `APPROVED`,
  `REJECTED` -> `REJECTED`, anything else (including an unconfirmed
  under-review string, or a future/unknown status) -> `PENDING`. Public so
  the unit tests can exercise every branch directly.
  """
  @spec map_bsp_status(String.t() | any()) :: String.t()
  def map_bsp_status("ACTIVE"), do: "APPROVED"
  def map_bsp_status("REJECTED"), do: "REJECTED"
  def map_bsp_status(_other), do: "PENDING"

  @spec sync_existing_template(SessionTemplate.t(), map()) :: :ok
  defp sync_existing_template(existing, entry) do
    new_status = map_bsp_status(entry["status"])

    if new_status == existing.status do
      :ok
    else
      update_attrs = %{
        status: new_status,
        is_active: new_status == "APPROVED",
        reason: entry["status_reason"]
      }

      # `Templates.update_session_template/2` (via
      # `SessionTemplate.update_changeset/2`) deliberately restricts an
      # `is_hsm: true` row to `[:is_active, :tag_id]` (and rejects any
      # update entirely unless the row is already `status: "APPROVED"`) —
      # that guard protects Gupshup's API-driven approval flow from a
      # caller silently drifting body/params away from what the BSP
      # approved. It is the wrong changeset for *setting* the status field
      # itself, which is exactly this sync's job (mirrors
      # `Glific.Scripts.SwiftchatTemplates.upsert_template/6`'s documented
      # reasoning for the same bypass) — use the base changeset directly.
      case existing
           |> SessionTemplate.changeset(update_attrs)
           |> Repo.update() do
        {:ok, updated} ->
          maybe_notify_status_change(updated, new_status)
          :ok

        {:error, error} ->
          Logger.error(
            "SwiftChat template status sync failed for #{existing.bsp_id}: " <>
              Glific.SafeLog.safe_inspect(error)
          )

          :ok
      end
    end
  end

  # F-5: fire a Glific notification on an actual status transition (never
  # on an unchanged poll tick — enforced by the caller's guard above, not
  # here, so this is only reached on a real change). Mirrors
  # `Templates.change_template_status/3`'s "APPROVED"/"REJECTED" shape
  # (templates.ex:659-692) — same category, same entity fields.
  @spec maybe_notify_status_change(SessionTemplate.t(), String.t()) :: :ok
  defp maybe_notify_status_change(template, "REJECTED") do
    notify(template, "Template #{template.shortcode} has been rejected")
  end

  defp maybe_notify_status_change(template, "APPROVED") do
    notify(template, "Template #{template.shortcode} has been approved")
  end

  defp maybe_notify_status_change(_template, _status), do: :ok

  @spec notify(SessionTemplate.t(), String.t()) :: :ok
  defp notify(template, message) do
    Notifications.create_notification(%{
      category: "Templates",
      message: message,
      severity: Notifications.types().info,
      organization_id: template.organization_id,
      entity: %{
        id: template.id,
        shortcode: template.shortcode,
        label: template.label,
        bsp_id: template.bsp_id
      }
    })

    :ok
  end

  # -- T-04: pull sync of dashboard-created templates -----------------

  @doc """
  Imports a dashboard-created template not yet known to Glific.

  **F-114 fix**: the LIST response (`ApiClient.list_templates/1`) was
  live-verified to carry ONLY `name`/`type`/`status`/`created_at`/
  `status_reason` — NO `body`. Building a `SessionTemplate` straight from
  the list entry therefore always failed `validate_body/2` ("Non-media
  messages should have a body") the moment `cast/3` normalized the
  fallback `""` body to `nil` — the hourly cron logged this error forever
  for every dashboard-created template, and the T-04 unit tests were
  mocked-green only because their fixtures included a body the real API
  never sends (GL-002). The fix: fetch the single template
  (`ApiClient.get_template/2`, `GET /merchants/{id}/templates/{name}`),
  which DOES return the body, and derive `number_parameters` from the
  body's own placeholders rather than trusting a list-response field that
  doesn't exist.
  """
  @spec import_dashboard_template(non_neg_integer(), Partners.Organization.t(), map()) :: :ok
  def import_dashboard_template(org_id, organization, entry) do
    name = entry["name"]

    case fetch_dashboard_template_body(org_id, name) do
      {:ok, body} ->
        insert_dashboard_template(org_id, organization, entry, body)

      :skip_non_text ->
        # Import remains text-only per ADR-005's scope — a non-text
        # dashboard template is skipped (not crashed), same as today's
        # behavior for other unmappable types elsewhere in this pipeline.
        Logger.error(
          "SwiftChat pull-sync: skipping dashboard template '#{name}' — non-text template " <>
            "type, text-only in this phase (ADR-005)"
        )

        :ok

      {:error, reason} ->
        # Single-fetch failed (non-200/network) — skip this template THIS
        # cycle only; no partial row is created. The next hourly cron
        # (Glific.Jobs.MinuteWorker's "update_hsms" branch) retries
        # naturally on the next poll, since no local row was created to
        # short-circuit the retry.
        Logger.warning(
          "SwiftChat pull-sync: skipping dashboard template '#{name}' this cycle — " <>
            "single-template fetch failed, will retry next hourly cron: " <>
            Glific.SafeLog.safe_inspect(reason)
        )

        :ok
    end
  end

  # Fetches the single-template body for a dashboard-created template
  # (F-114). Returns `{:ok, body}` for a text template, `:skip_non_text`
  # for any other confirmed type (ADR-005 scope), or `{:error, reason}` on
  # a non-200/network failure.
  @spec fetch_dashboard_template_body(non_neg_integer(), String.t() | nil) ::
          {:ok, String.t()} | :skip_non_text | {:error, any()}
  defp fetch_dashboard_template_body(org_id, name) do
    case ApiClient.get_template(org_id, name) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        decode_single_template_body(body)

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error, "status #{status}: #{Glific.SafeLog.safe_inspect(body)}"}

      {:error, error} ->
        {:error, error}
    end
  end

  # ApiClient uses Tesla.Middleware.JSON, so a JSON response body normally
  # arrives already decoded (a map); tolerate a raw string body defensively
  # (mirrors `decode_list_body/1`'s same defensiveness for the list call).
  @spec decode_single_template_body(any()) ::
          {:ok, String.t()} | :skip_non_text | {:error, any()}
  defp decode_single_template_body(body) when is_map(body), do: extract_text_body(body)

  defp decode_single_template_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> extract_text_body(decoded)
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_single_template_body(body),
    do:
      {:error, "unexpected single-template response shape: #{Glific.SafeLog.safe_inspect(body)}"}

  # Confirmed live shape (F-114):
  # {"template": {"type": "text", "text": {"body": "..."}}, "status": ..., ...}
  @spec extract_text_body(map()) :: {:ok, String.t()} | :skip_non_text | {:error, String.t()}
  defp extract_text_body(%{"template" => %{"type" => "text", "text" => %{"body" => body}}})
       when is_binary(body),
       do: {:ok, body}

  defp extract_text_body(%{"template" => %{"type" => _other_type}}), do: :skip_non_text

  defp extract_text_body(_decoded),
    do: {:error, "single-template response missing template.text.body"}

  @spec insert_dashboard_template(
          non_neg_integer(),
          Partners.Organization.t(),
          map(),
          String.t()
        ) :: :ok
  defp insert_dashboard_template(org_id, organization, entry, body) do
    glific_body = swiftchat_vars_to_glific(body)
    name = entry["name"]

    attrs = %{
      bsp_id: name,
      shortcode: name,
      label: name,
      body: glific_body,
      type: :text,
      is_hsm: true,
      status: map_bsp_status(entry["status"]),
      is_active: map_bsp_status(entry["status"]) == "APPROVED",
      reason: entry["status_reason"],
      number_parameters: max_positional_parameter(body),
      # SwiftChat's list response carries no language field per the
      # confirmed shape — default to the org's default language (matching
      # Gupshup's existing fallback pattern, templates.ex:509). Known gap
      # (PRD-002 Open Question Q3, still open): dashboard-created templates
      # in a language other than the org's default land mis-tagged until
      # Q3 is resolved — do not silently guess a specific language beyond
      # this documented fallback.
      language_id: organization.default_language_id,
      organization_id: org_id
    }

    case Templates.do_create_session_template(attrs) do
      {:ok, _template} ->
        :ok

      {:error, error} ->
        Logger.error(
          "SwiftChat pull-sync failed to import dashboard template '#{name}': " <>
            Glific.SafeLog.safe_inspect(error)
        )

        :ok
    end
  end

  @doc """
  Derives `number_parameters` from the MAX positional placeholder `{N}`
  found in a SwiftChat template body (F-114) — deliberately the max, not a
  count of unique placeholders, so numbering matches SwiftChat's own `{N}`
  rather than Glific's occurrence count (e.g. a body using only `{1}` and
  `{3}` reports 3). Returns 0 when the body has no placeholders. Public so
  the unit tests can exercise it directly.
  """
  @spec max_positional_parameter(String.t()) :: non_neg_integer()
  def max_positional_parameter(body) when is_binary(body) do
    ~r/\{(\d+)\}/
    |> Regex.scan(body)
    |> Enum.map(fn [_full, n] -> String.to_integer(n) end)
    |> case do
      [] -> 0
      numbers -> Enum.max(numbers)
    end
  end

  def max_positional_parameter(_body), do: 0

  # -- T-05: delete/2 (real BSP-side delete) ---------------------------

  @doc """
  Deletes a Glific-managed template from SwiftChat.

  Contract verified against `Templates.delete_session_template/1`
  (`templates.ex:341-353`): for an `is_hsm` row, it spawns
  `bsp_module.delete(org_id, Map.from_struct(session_template))` via
  `Task.Supervisor.async_nolink` and, **independently**, always calls
  `Repo.delete(session_template)` itself — this callback does NOT delete
  the local row (matching Gupshup's `delete/2`, `gupshup/template.ex:366-377`,
  which likewise never touches the DB). `attrs.bsp_id` is the SwiftChat
  template name (per the confirmed endpoint: templates are keyed by name).

  `DELETE {base}/merchants/{Merchant-ID}/templates/{Template-Name}`.
  Error-code 122 ("already deleted") and 118 ("not found") are treated as
  **success** — idempotent-delete: the end state (not present at SwiftChat)
  is achieved either way, matching PRD-002's non-functional idempotency
  requirement.

  Dashboard-only (script-seeded) rows are not distinguished from
  API-managed rows before calling this — SwiftChat's delete-by-name has no
  server-side notion of "who created this," so calling delete on a
  script-seeded row's `bsp_id` is a harmless best-effort SwiftChat-side
  operation: either it exists and gets removed, or it 404s/409s, both
  tolerated below; the local row is deleted by the caller regardless of
  this call's outcome. No new schema state added to track "origin" (per
  T-05's provisional decision).
  """
  @spec delete(non_neg_integer(), map()) :: {:ok, any()} | {:error, any()}
  def delete(org_id, %{bsp_id: bsp_id} = attrs) when is_binary(bsp_id) and bsp_id != "" do
    case ApiClient.delete_template(org_id, bsp_id) do
      {:ok, %Tesla.Env{status: status}} when status in [200, 204] ->
        {:ok, attrs}

      {:ok, %Tesla.Env{status: status, body: body}} ->
        if already_gone?(status, body) do
          {:ok, attrs}
        else
          Logger.error(
            "Error while deleting the SwiftChat template. status=#{status} " <>
              Glific.SafeLog.safe_inspect(body)
          )

          {:error, body}
        end

      {:error, error} ->
        Logger.error("Error while deleting the template. #{Glific.SafeLog.safe_inspect(error)}")
        {:error, error}
    end
  end

  # No bsp_id (e.g. a row never submitted via the API, or a script-seeded
  # row with no bsp_id at all) — nothing to clean up BSP-side.
  def delete(_org_id, attrs), do: {:ok, attrs}

  # 409/code-122 ("already deleted") and 118 ("not found", surfaced as
  # either a 404 or a 400 depending on the endpoint per PRD-001's captured
  # error-code table) both mean the end state (not present at SwiftChat) is
  # already achieved — treat as success rather than surfacing a confusing
  # GraphQL error.
  @spec already_gone?(non_neg_integer(), any()) :: boolean()
  defp already_gone?(409, body), do: error_code(body) == 122
  defp already_gone?(404, body), do: error_code(body) == 118
  defp already_gone?(400, body), do: error_code(body) == 118
  defp already_gone?(_status, _body), do: false

  @spec error_code(any()) :: any()
  defp error_code(%{"code" => code}), do: code

  defp error_code(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"code" => code}} -> code
      _ -> nil
    end
  end

  defp error_code(_body), do: nil
end
