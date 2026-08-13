defmodule Glific.Providers.TemplateBehaviour do
  @moduledoc """
  The message behaviour which all the providers needs to implement for communication
  """

  @callback submit_for_approval(attrs :: map()) ::
              {:ok, Glific.Templates.SessionTemplate.t()} | {:error, any()}

  @callback delete(org_id :: non_neg_integer(), attrs :: map()) ::
              {:ok, any()} | {:error, any()}

  @callback update_hsm_templates(org_id :: non_neg_integer()) ::
              :ok | {:error, String.t()}

  @callback import_templates(org_id :: non_neg_integer(), data :: String.t()) ::
              :ok | {:ok, any}

  @callback bulk_apply_templates(org_id :: non_neg_integer(), data :: String.t()) ::
              :ok | {:ok, any}

  # F-082(a): both shipped implementations (Gupshup, SwiftChat) already
  # implement this and `Templates.edit_approved_template/2`
  # (`lib/glific/templates.ex:321-330`) already dispatches to it — it was
  # simply missing from the behaviour, so a future BSP could omit it with
  # no compile-time warning.
  @callback edit_approved_template(template_id :: integer(), params :: map()) ::
              {:ok, any} | {:error, any}
end
