defmodule Glific.Providers.Swiftchat.Template do
  @moduledoc """
  Module for handling template operations specific to SwiftChat.

  Per ADR-005 ("Manage SwiftChat templates by manual bsp_id mapping in
  phase 1, API sync in phase 2"), SwiftChat templates are authored and
  approved in the SwiftChat dashboard; phase 1 has **no** template API
  integration — approved templates are inserted into `session_templates`
  via `Glific.Scripts.SwiftchatTemplates` with `bsp_id` set manually.
  There is deliberately no `Swiftchat.Template` API-sync module yet
  (phase 2 slots in behind the same `TemplateBehaviour` contract).

  This module is the phase-1 placeholder that satisfies
  `Glific.Providers.TemplateBehaviour` so `Glific.Partners.Provider.bsp_module/2`
  has something to dispatch a `swiftchat`-BSP org to, mirroring the
  precedent already set by `Glific.Providers.GupshupEnterprise.Template`
  for BSPs whose sub-flows aren't (yet) implemented.

  **`update_hsm_templates/1` is the one callback that MUST be a real
  no-op, not a raise**: `Glific.Jobs.MinuteWorker`'s `"update_hsms"` cron
  branch calls `Partners.perform_all(&Templates.sync_hsms_from_bsp/1, ...)`
  unconditionally over every active organization (no per-BSP filter);
  `sync_hsms_from_bsp/1` calls `Provider.bsp_module(org_id, :template).update_hsm_templates/1`.
  Before this module existed, a single active SwiftChat-BSP org would
  raise `"swiftchat Provider Not found."` inside `Partners.perform_all/4`'s
  `Enum.each` — since that function's `rescue` wraps the *entire* iteration
  (not per-org), one bad org aborted `sync_hsms_from_bsp` for every other
  org in that (randomly-ordered) cron tick's batch. `:ok` here (matching
  `GupshupEnterprise.Template.update_hsm_templates/1`'s existing pattern)
  fixes that crash without pretending a sync happened.

  The remaining callbacks (`submit_for_approval/1`, `import_templates/2`,
  `bulk_apply_templates/2`, `edit_approved_template/2`... `delete/2`) are
  reachable only via GraphQL template-authoring mutations
  (`createSessionTemplate` with `is_hsm: true`, `importTemplates`,
  `bulkApplyTemplates`, `editApprovedTemplate`, `deleteSessionTemplate`).
  Per ADR-005's explicit phase-1 scope, the frontend template-creation UI
  "must not be pointed at SwiftChat orgs in phase 1" — these mutations are
  not expected to be exercised for a swiftchat org today. Rather than
  silently no-op (which would look like success while doing nothing to a
  caller who ignores ADR-005's guidance), they return a clear
  `{:error, ...}` naming the phase-1 gap, so a misdirected UI call fails
  loudly and visibly instead of crashing the whole GraphQL request with an
  unhandled raise. `delete/2` is the one exception: deleting a
  manually-seeded row must not fail (there is nothing BSP-side to clean
  up), so it mirrors `GupshupEnterprise.Template.delete/2`'s local no-op.
  """

  @behaviour Glific.Providers.TemplateBehaviour

  alias Glific.Templates.SessionTemplate

  @phase_1_gap "SwiftChat template API sync is not implemented in phase 1 (ADR-005) — " <>
                 "templates are authored and approved in the SwiftChat dashboard, then seeded " <>
                 "via Glific.Scripts.SwiftchatTemplates with bsp_id set manually. Do not point " <>
                 "the template-creation UI at a SwiftChat org."

  @doc """
  Phase 1 has no submit-for-approval API call — approval happens in the
  SwiftChat dashboard, outside Glific.
  """
  @spec submit_for_approval(map()) :: {:ok, SessionTemplate.t()} | {:error, any()}
  def submit_for_approval(_attrs), do: {:error, @phase_1_gap}

  @doc """
  Phase 1 has no CSV-import-from-BSP integration.
  """
  @spec import_templates(non_neg_integer(), String.t()) :: {:ok, any} | {:error, any}
  def import_templates(_organization_id, _data), do: {:error, @phase_1_gap}

  @doc """
  Phase 1 has no bulk-apply-from-BSP integration.
  """
  @spec bulk_apply_templates(non_neg_integer(), String.t()) :: {:ok, any} | {:error, any}
  def bulk_apply_templates(_organization_id, _data), do: {:error, @phase_1_gap}

  @doc """
  Phase 1 has no edit-approved-template API call.
  """
  @spec edit_approved_template(integer(), map()) :: {:ok, any} | {:error, any}
  def edit_approved_template(_template_id, _params), do: {:error, @phase_1_gap}

  @doc """
  Real no-op (must not raise) — see moduledoc. Called unconditionally for
  every active organization by `Glific.Jobs.MinuteWorker`'s `"update_hsms"`
  cron branch via `Glific.Templates.sync_hsms_from_bsp/1`.
  """
  @spec update_hsm_templates(non_neg_integer()) :: :ok | {:error, String.t()}
  def update_hsm_templates(_organization_id), do: :ok

  @doc """
  Deleting a manually-seeded (phase-1) template row has nothing to clean
  up BSP-side — mirrors `GupshupEnterprise.Template.delete/2`.
  """
  @spec delete(non_neg_integer(), map()) :: {:ok, any()} | {:error, any()}
  def delete(_org_id, attrs), do: {:ok, attrs}
end
