defmodule Glific.Scripts.SwiftchatTemplatesTest do
  @moduledoc """
  Tests for the T-10 manual bsp_id seed helper (ADR-005 phase 1) — row
  creation, idempotent re-run (upsert by bsp_id + org), and a validation
  error path.
  """
  use Glific.DataCase, async: true

  alias Glific.{
    Fixtures,
    Partners,
    Repo,
    Scripts.SwiftchatTemplates,
    Templates.SessionTemplate
  }

  describe "upsert_template/6" do
    test "creates a new session_templates row with the confirmed phase-1 shape", attrs do
      assert {:ok, session_template} =
               SwiftchatTemplates.upsert_template(
                 attrs.organization_id,
                 "order_confirmation",
                 "Order Confirmation",
                 "Hi {{1}}, your order {{2}} has shipped.",
                 2
               )

      assert session_template.bsp_id == "order_confirmation"
      assert session_template.label == "Order Confirmation"
      assert session_template.body == "Hi {{1}}, your order {{2}} has shipped."
      assert session_template.type == :text
      assert session_template.status == "APPROVED"
      assert session_template.is_hsm == true
      assert session_template.number_parameters == 2
      assert session_template.organization_id == attrs.organization_id

      assert session_template.language_id ==
               Partners.organization(attrs.organization_id).default_language_id
    end

    test "is idempotent: re-running with the same org_id + template name updates, not duplicates",
         attrs do
      count_before =
        Repo.aggregate(
          Ecto.Query.where(SessionTemplate, organization_id: ^attrs.organization_id),
          :count,
          :id
        )

      assert {:ok, first_insert} =
               SwiftchatTemplates.upsert_template(
                 attrs.organization_id,
                 "order_confirmation",
                 "Order Confirmation",
                 "Hi {{1}}, your order {{2}} has shipped.",
                 2
               )

      assert {:ok, second_run} =
               SwiftchatTemplates.upsert_template(
                 attrs.organization_id,
                 "order_confirmation",
                 "Order Confirmation (updated label)",
                 "Hi {{1}}, your order {{2}} shipped via {{3}}.",
                 3
               )

      assert second_run.id == first_insert.id
      assert second_run.label == "Order Confirmation (updated label)"
      assert second_run.number_parameters == 3

      count_after =
        Repo.aggregate(
          Ecto.Query.where(SessionTemplate, organization_id: ^attrs.organization_id),
          :count,
          :id
        )

      assert count_after == count_before + 1
    end

    test "accepts an explicit language_id instead of the org default", attrs do
      language = Fixtures.language_fixture(%{label: "Hindi", label_locale: "hi", locale: "hi"})

      assert {:ok, session_template} =
               SwiftchatTemplates.upsert_template(
                 attrs.organization_id,
                 "order_confirmation_hi",
                 "Order Confirmation (Hindi)",
                 "नमस्ते {{1}}",
                 1,
                 language.id
               )

      assert session_template.language_id == language.id
    end

    test "returns a validation error changeset for an invalid language_id", attrs do
      assert {:error, %Ecto.Changeset{}} =
               SwiftchatTemplates.upsert_template(
                 attrs.organization_id,
                 "bad_template",
                 "Bad Template",
                 "Hi {{1}}",
                 1,
                 0
               )
    end
  end
end
