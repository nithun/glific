defmodule Glific.Providers.Swiftchat.TemplateTest do
  @moduledoc """
  Covers the must-fix identified in the provider-dispatch sweep:
  `Glific.Jobs.MinuteWorker`'s `"update_hsms"` cron calls
  `Partners.perform_all(&Templates.sync_hsms_from_bsp/1, ...)` over every
  active organization unconditionally; `sync_hsms_from_bsp/1` dispatches
  through `Provider.bsp_module(org_id, :template)`. Before
  `Glific.Providers.Swiftchat.Template` existed, a single active
  swiftchat-BSP org raised `"swiftchat Provider Not found."` inside
  `Partners.perform_all/4`'s `Enum.each`, aborting the whole batch (the
  function's `rescue` wraps the entire iteration, not per-org).
  """
  use Glific.DataCase, async: false

  alias Glific.{
    Partners,
    Partners.Provider,
    Providers.Swiftchat.Template,
    Repo,
    Templates
  }

  setup %{organization_id: organization_id} = attrs do
    {:ok, swiftchat_provider} = Repo.fetch_by(Provider, %{shortcode: "swiftchat"})

    organization = Partners.get_organization!(organization_id)
    Partners.update_organization(organization, %{bsp_id: swiftchat_provider.id})

    organization = Partners.get_organization!(organization_id)
    Partners.remove_organization_cache(organization.id, organization.shortcode)
    Partners.fill_cache(organization)

    attrs
  end

  describe "Provider.bsp_module(org_id, :template) resolution" do
    test "resolves to Glific.Providers.Swiftchat.Template for a swiftchat-BSP org",
         %{organization_id: organization_id} do
      assert Provider.bsp_module(organization_id, :template) ==
               Glific.Providers.Swiftchat.Template
    end
  end

  describe "update_hsm_templates/1 (must not raise — the cron crash fix)" do
    test "is a real no-op that returns :ok", %{organization_id: organization_id} do
      assert Template.update_hsm_templates(organization_id) == :ok
    end

    test "Templates.sync_hsms_from_bsp/1 no longer raises for a swiftchat org (regression test)",
         %{organization_id: organization_id} do
      assert Templates.sync_hsms_from_bsp(organization_id) == :ok
    end
  end

  describe "phase-1 gap callbacks (ADR-005) return a clear error instead of raising" do
    test "submit_for_approval/1 errors naming the phase-1 gap" do
      assert {:error, message} = Template.submit_for_approval(%{})
      assert message =~ "phase 1"
    end

    test "import_templates/2 errors naming the phase-1 gap" do
      assert {:error, message} = Template.import_templates(1, "")
      assert message =~ "phase 1"
    end

    test "bulk_apply_templates/2 errors naming the phase-1 gap" do
      assert {:error, message} = Template.bulk_apply_templates(1, "")
      assert message =~ "phase 1"
    end

    test "edit_approved_template/2 errors naming the phase-1 gap" do
      assert {:error, message} = Template.edit_approved_template(1, %{})
      assert message =~ "phase 1"
    end

    test "delete/2 is a local no-op (nothing BSP-side to clean up)" do
      assert {:ok, %{some: :attrs}} = Template.delete(1, %{some: :attrs})
    end
  end

  describe "Provider.bsp_module(org_id, _) catch-all (unreachable dispatch today)" do
    test "still raises with a clear, gap-naming message for a swiftchat org",
         %{organization_id: organization_id} do
      assert_raise RuntimeError, ~r/no swiftchat clause here/, fn ->
        Provider.bsp_module(organization_id, :some_unused_tag)
      end
    end
  end
end
