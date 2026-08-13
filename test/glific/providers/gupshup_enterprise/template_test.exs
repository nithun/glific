defmodule Glific.Providers.GupshupEnterprise.TemplateTest do
  @moduledoc """
  F-082(a): `edit_approved_template/2` was added to `TemplateBehaviour`
  (previously implemented by Gupshup/SwiftChat but not declared on the
  behaviour) — Gupshup Enterprise had no clause for it at all, so one was
  added here to satisfy the now-compile-enforced callback. Covers that new
  clause; the rest of this module's callbacks are covered indirectly via
  `test/glific_web/providers/gupshup_enterprise/controllers/*_test.exs`.
  """
  use Glific.DataCase, async: true

  alias Glific.Providers.GupshupEnterprise.Template

  describe "edit_approved_template/2" do
    test "returns a clear not-supported error rather than crashing" do
      assert {:error, message} = Template.edit_approved_template(1, %{})
      assert message =~ "does not support editing"
    end
  end
end
