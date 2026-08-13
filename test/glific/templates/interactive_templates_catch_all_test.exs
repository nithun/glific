defmodule Glific.Templates.InteractiveTemplatesCatchAllTest do
  @moduledoc """
  PRD-005 T15 (ADR-016 rule 4): the 11 `interactive_templates.ex` per-type
  dispatch sites must either do a descriptor lookup or gain a safe
  catch-all — no silent degradation, no crash. This suite specifically
  exercises the previously-crashing sites (`translate_interactive_content/6`,
  `generate_csv_data/1`'s CSV export `case`, `import_interactive_template/2`'s
  CSV import `case` — none had a catch-all before this task).

  Real interactive_templates rows are always write-time validated (T13) to
  have `interactive_content["type"]` match the row's `type` column, and the
  `type` column is DB-enum-constrained to the 3 known types — so a
  *genuinely unrecognized* declared type can only exist on a row today via
  a legacy/out-of-band write that bypasses the changeset (ADR-016
  Consequences: "existing rows are not retro-validated; legacy rows must be
  tolerated"). `Repo.update_all/3` (raw SQL, no changeset) simulates
  exactly that.

  Note: this suite asserts on *functional* behavior (no crash, safe
  fallback value), not on log output — `config/test.exs` sets
  `compile_time_purge_matching: [[level_lower_than: :emergency]]`, which
  strips every `Logger.error/1` call (including the ones inside
  `Glific.log_error/1`, used by every catch-all this task added) out of
  the compiled test build entirely. That's a project-wide test-env
  convention, not something this task's catch-alls can observe around.
  """
  use Glific.DataCase, async: false

  alias Glific.{
    Fixtures,
    Repo,
    Templates.InteractiveTemplate,
    Templates.InteractiveTemplates
  }

  @spec force_mismatched_content(InteractiveTemplate.t()) :: InteractiveTemplate.t()
  defp force_mismatched_content(interactive_template) do
    import Ecto.Query

    Repo.update_all(
      from(i in InteractiveTemplate, where: i.id == ^interactive_template.id),
      set: [
        interactive_content: %{
          "type" => "some_future_type_not_yet_declared",
          "content" => %{"type" => "text", "text" => "hi"},
          "options" => []
        }
      ]
    )

    InteractiveTemplates.get_interactive_template!(interactive_template.id)
  end

  describe "generate_csv_data/1 catch-all (via export_interactive_template/2)" do
    test "an unrecognized declared type exports a header-only CSV instead of crashing (CaseClauseError before T15)",
         %{organization_id: organization_id} do
      interactive_template =
        %{organization_id: organization_id}
        |> Fixtures.interactive_fixture()
        |> force_mismatched_content()

      assert {:ok, %{export_data: data}} =
               InteractiveTemplates.export_interactive_template(interactive_template, false)

      assert data =~ "Attribute"
      # header-only: exactly one CSV row, no data rows appended after it
      assert data |> String.trim() |> String.split("\n") |> length() == 1
    end
  end

  describe "translate_interactive_content/6 catch-all (via translate_interactive_template/1)" do
    test "an unrecognized declared type does not raise FunctionClauseError", %{
      organization_id: organization_id
    } do
      interactive_template =
        %{organization_id: organization_id}
        |> Fixtures.interactive_fixture()
        |> force_mismatched_content()

      # Must not raise. T13's own write-time validation independently
      # rejects the (still-mismatched, forced) row on the resulting
      # `update_interactive_template/2` call inside
      # `translate_interactive_template/1` — a controlled `{:error, _}`,
      # not a crash, is the expected outcome; the property under test is
      # "no exception," which is exactly what was broken before T15
      # (a bare FunctionClauseError from translate_interactive_content/6).
      result = InteractiveTemplates.translate_interactive_template(interactive_template)
      assert match?({:ok, _, _}, result) or match?({:error, _}, result)
    end
  end

  describe "import_interactive_template/2 catch-all" do
    test "an unrecognized declared type does not raise CaseClauseError", %{
      organization_id: organization_id
    } do
      interactive_template =
        %{organization_id: organization_id}
        |> Fixtures.interactive_fixture()
        |> force_mismatched_content()

      translation_data = [["Attribute", "en"], ["Header", "hi"]]

      result =
        InteractiveTemplates.import_interactive_template(translation_data, interactive_template)

      assert match?({:ok, _, _}, result) or match?({:error, _}, result)
    end
  end

  describe "the already-permissive catch-alls stay unchanged for the 3 known types (R1/R2)" do
    test "a real location_request_message template's body/clean/title helpers behave exactly as before",
         %{organization_id: organization_id} do
      interactive_template =
        Fixtures.interactive_fixture(%{
          organization_id: organization_id,
          label: "Real location for catch-all regression check",
          type: :location_request_message,
          interactive_content: %{
            "type" => "location_request_message",
            "body" => %{"type" => "text", "text" => "please share your location"},
            "action" => %{"name" => "send_location"}
          }
        })

      assert "please share your location" ==
               InteractiveTemplates.get_interactive_body(interactive_template.interactive_content)

      assert interactive_template.interactive_content ==
               InteractiveTemplates.get_clean_interactive_content(
                 interactive_template.interactive_content,
                 interactive_template.send_with_title,
                 interactive_template.type
               )

      assert interactive_template.interactive_content ==
               InteractiveTemplates.clean_template_title(interactive_template.interactive_content)
    end
  end
end
