defmodule Glific.Scripts.SwiftchatTemplates do
  @moduledoc """
  Admin helper script for SwiftChat template phase 1 (PRD-001-tasks T-10,
  ADR-005 "manual bsp_id mapping").

  SwiftChat templates are authored and approved in the SwiftChat merchant
  dashboard (`POST /merchants/{Merchant-ID}/templates`, out of Glific's
  control in phase 1). Once a template shows `ACTIVE` there, run this
  helper from the IEx console to insert (or update) the matching
  `session_templates` row so Glific's existing HSM send path
  (`Glific.Messages.create_and_send_hsm_message/1` ->
  `Glific.Providers.Swiftchat.Message.send_text/2`) can use it —
  see `docs/adrs/ADR-005-swiftchat-template-strategy.md`.

  Run from the console (e.g. `iex -S mix` locally, `gigalixir remote_console`
  in production):

      Glific.Scripts.SwiftchatTemplates.upsert_template(
        _org_id = 1,
        _template_name = "order_confirmation",
        _label = "Order Confirmation",
        _body = "Hi {{1}}, your order {{2}} has shipped.",
        _number_parameters = 2,
        _language_id = 1
      )

  SwiftChat templates are keyed by **name**, not a numeric id
  (`docs/prds/PRD-001-spike-notes.md` "Templates" bonus finding) — the
  template name is stored in `SessionTemplate.bsp_id`, exactly the field
  `Swiftchat.Message.send_text/2`'s HSM branch reads at send time.
  Idempotent: re-running with the same `org_id` + `template_name` updates
  the existing row (matched on `bsp_id` + `organization_id`) instead of
  raising a uniqueness error.
  """

  alias Glific.{
    Partners,
    Repo,
    Templates,
    Templates.SessionTemplate
  }

  # `Templates.update_session_template/2` (via `SessionTemplate.update_changeset/2`)
  # deliberately restricts an already-`status: "APPROVED"` HSM row to only
  # `[:is_active, :tag_id]` — Glific's own submit-for-approval flow treats
  # an approved template as frozen, to stop the body/params silently
  # drifting from what the BSP approved. That protection is aimed at
  # Gupshup's API-driven approval flow; phase 1 (ADR-005) is explicitly a
  # dashboard-approved, Glific-blind mapping, so this script updates the
  # row directly via the base `SessionTemplate.changeset/2` (same
  # changeset `do_create_session_template/1` uses for insert) rather than
  # going through the update path meant for API-synced templates.

  require Logger

  @doc """
  Inserts or updates a `session_templates` row for a SwiftChat template
  that has already been approved in the SwiftChat dashboard.

  `language_id` defaults to the organization's `default_language_id` when
  not supplied. Sets `status: "APPROVED"`, `is_hsm: true`, `type: :text`
  (phase 1 restricts to text templates, per ADR-005's variable-mapping
  caveat — media/button templates are out of this task's scope).
  """
  @spec upsert_template(
          non_neg_integer(),
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer() | nil
        ) :: {:ok, SessionTemplate.t()} | {:error, Ecto.Changeset.t() | String.t()}
  def upsert_template(
        org_id,
        template_name,
        label,
        body,
        number_parameters,
        language_id \\ nil
      ) do
    Repo.put_organization_id(org_id)

    language_id = language_id || Partners.organization(org_id).default_language_id

    attrs = %{
      bsp_id: template_name,
      label: label,
      body: body,
      type: :text,
      shortcode: template_name,
      status: "APPROVED",
      is_hsm: true,
      number_parameters: number_parameters,
      language_id: language_id,
      organization_id: org_id
    }

    case Repo.fetch_by(SessionTemplate, %{bsp_id: template_name, organization_id: org_id}) do
      {:ok, session_template} ->
        session_template
        |> SessionTemplate.changeset(attrs)
        |> Repo.update()
        |> log_result("updated")

      {:error, _reason} ->
        attrs
        |> Templates.do_create_session_template()
        |> log_result("created")
    end
  end

  @spec log_result(
          {:ok, SessionTemplate.t()} | {:error, Ecto.Changeset.t()},
          String.t()
        ) :: {:ok, SessionTemplate.t()} | {:error, Ecto.Changeset.t()}
  defp log_result({:ok, session_template} = result, action) do
    IO.puts(
      "✓ SwiftChat template #{action} (id: #{session_template.id}, bsp_id: #{session_template.bsp_id})"
    )

    result
  end

  defp log_result({:error, changeset} = result, action) do
    Logger.error(
      "SwiftChat template #{action} failed: #{Glific.SafeLog.safe_inspect(changeset.errors)}"
    )

    IO.puts(
      "✗ SwiftChat template #{action} failed: #{Glific.SafeLog.safe_inspect(changeset.errors)}"
    )

    result
  end
end
