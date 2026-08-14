defmodule Glific.Providers.Swiftchat.TemplateTest do
  @moduledoc """
  Covers PRD-002 (SwiftChat template lifecycle sync, phase 2 of ADR-005):
  T-02 submit-for-approval, T-03 status poll sync, T-04 pull sync of
  dashboard-created templates, T-05 real BSP-side delete, T-06 updated
  stub-error text on the remaining unimplemented callbacks.

  Also retains the original provider-dispatch regression coverage: before
  `Glific.Providers.Swiftchat.Template` existed, a single active
  swiftchat-BSP org raised `"swiftchat Provider Not found."` inside
  `Partners.perform_all/4`'s `Enum.each`, aborting the whole cron batch.
  """
  use Glific.DataCase, async: false

  alias Glific.{
    Fixtures,
    Notifications.Notification,
    Partners,
    Partners.Provider,
    Providers.Swiftchat.Template,
    Repo,
    Templates,
    Templates.SessionTemplate
  }

  setup %{organization_id: organization_id} = attrs do
    {:ok, swiftchat_provider} = Repo.fetch_by(Provider, %{shortcode: "swiftchat"})

    {:ok, _credential} =
      Partners.create_credential(%{
        organization_id: organization_id,
        shortcode: "swiftchat",
        keys: %{
          handler: "Glific.Providers.Swiftchat.Message",
          worker: "Glific.Providers.Swiftchat.Worker"
        },
        secrets: %{
          "api_key" => "test_swiftchat_api_key",
          "bot_id" => "test_bot_id",
          "merchant_id" => "test_merchant_id"
        },
        is_active: true
      })

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

  describe "variable-dialect translation (F-4)" do
    test "glific_vars_to_swiftchat/1 translates {{1}} to {1}" do
      assert Template.glific_vars_to_swiftchat("Hi {{1}}, your OTP is {{2}}.") ==
               "Hi {1}, your OTP is {2}."
    end

    test "glific_vars_to_swiftchat/1 handles a no-variable body unchanged" do
      assert Template.glific_vars_to_swiftchat("Hello there") == "Hello there"
    end

    test "glific_vars_to_swiftchat/1 handles a single-variable body" do
      assert Template.glific_vars_to_swiftchat("Hi {{1}}") == "Hi {1}"
    end

    test "swiftchat_vars_to_glific/1 is the exact reverse" do
      assert Template.swiftchat_vars_to_glific("Hi {1}, your OTP is {2}.") ==
               "Hi {{1}}, your OTP is {{2}}."
    end

    test "swiftchat_vars_to_glific/1 handles a no-variable body unchanged" do
      assert Template.swiftchat_vars_to_glific("Hello there") == "Hello there"
    end

    test "round-trip: glific -> swiftchat -> glific returns the original body" do
      original = "Hi {{1}}, your order {{2}} shipped on {{3}}."

      assert original
             |> Template.glific_vars_to_swiftchat()
             |> Template.swiftchat_vars_to_glific() == original
    end

    test "swiftchat_parameters_count/1 counts unique positional variables" do
      assert Template.swiftchat_parameters_count("Hi {1}, order {2} shipped") == 2
      assert Template.swiftchat_parameters_count("Hi {1}, {1} again") == 1
      assert Template.swiftchat_parameters_count("No variables here") == 0
    end

    test "max_positional_parameter/1 (F-114) derives the MAX placeholder number, matching the " <>
           "live F-083 body Hello {1}, ... Ref: {2}. -> 2" do
      assert Template.max_positional_parameter("Hello {1}, ... Ref: {2}.") == 2
    end

    test "max_positional_parameter/1 returns 0 for a body with no placeholders" do
      assert Template.max_positional_parameter("No variables here") == 0
    end

    test "max_positional_parameter/1 returns the max even when a middle number is skipped" do
      assert Template.max_positional_parameter("Hi {1}, ref {3}") == 3
    end

    test "max_positional_parameter/1 is unaffected by repeated placeholders" do
      assert Template.max_positional_parameter("Hi {1}, {1} again, then {2}") == 2
    end
  end

  describe "map_bsp_status/1 (defensive status mapping, T-01 decision)" do
    test "ACTIVE maps to APPROVED" do
      assert Template.map_bsp_status("ACTIVE") == "APPROVED"
    end

    test "REJECTED maps to REJECTED" do
      assert Template.map_bsp_status("REJECTED") == "REJECTED"
    end

    test "an unconfirmed under-review string falls through to PENDING" do
      assert Template.map_bsp_status("UNDER_REVIEW") == "PENDING"
      assert Template.map_bsp_status("IN_REVIEW") == "PENDING"
    end

    test "a completely unrecognized/future status string falls through to PENDING, not crash" do
      assert Template.map_bsp_status("SOME_FUTURE_STATUS") == "PENDING"
      assert Template.map_bsp_status(nil) == "PENDING"
    end
  end

  describe "submit_for_approval/1 (T-02)" do
    test "posts to SwiftChat, stores the name in bsp_id, creates the row with status PENDING",
         %{organization_id: organization_id} do
      Tesla.Mock.mock(fn %{method: :post, url: url, body: body} ->
        assert url =~ "/merchants/test_merchant_id/templates"
        decoded = Jason.decode!(body)
        assert decoded["name"] == "order_confirmation"
        assert decoded["template"]["type"] == "text"
        assert decoded["template"]["text"]["body"] == "Hi {1}, your order {2} shipped."

        %Tesla.Env{status: 201, body: Jason.encode!(%{"name" => "order_confirmation"})}
      end)

      language = Fixtures.language_fixture()

      attrs = %{
        shortcode: "order_confirmation",
        label: "Order Confirmation",
        body: "Hi {{1}}, your order {{2}} shipped.",
        type: :text,
        category: "UTILITY",
        example: "Hi Priya, your order ORD-123 shipped.",
        is_hsm: true,
        language_id: language.id,
        organization_id: organization_id
      }

      assert {:ok, %SessionTemplate{} = template} = Template.submit_for_approval(attrs)
      assert template.bsp_id == "order_confirmation"
      assert template.shortcode == "order_confirmation"
      assert template.status == "PENDING"
      assert template.is_active == false
      assert template.number_parameters == 2
    end

    test "handles a 201 with a non-JSON 'Created' body", %{organization_id: organization_id} do
      Tesla.Mock.mock(fn %{method: :post} ->
        %Tesla.Env{status: 201, body: "Created"}
      end)

      language = Fixtures.language_fixture()

      attrs = %{
        shortcode: "welcome_msg",
        label: "Welcome",
        body: "Welcome {{1}}!",
        type: :text,
        category: "UTILITY",
        example: "Welcome Priya!",
        is_hsm: true,
        language_id: language.id,
        organization_id: organization_id
      }

      assert {:ok, %SessionTemplate{} = template} = Template.submit_for_approval(attrs)
      assert template.bsp_id == "welcome_msg"
      assert template.status == "PENDING"
    end

    test "returns a clear error on a 409 name collision", %{organization_id: organization_id} do
      Tesla.Mock.mock(fn %{method: :post} ->
        %Tesla.Env{status: 409, body: Jason.encode!(%{"code" => 121, "message" => "exists"})}
      end)

      language = Fixtures.language_fixture()

      attrs = %{
        shortcode: "dup_template",
        label: "Duplicate",
        body: "Hi {{1}}",
        type: :text,
        category: "UTILITY",
        example: "Hi Priya",
        is_hsm: true,
        language_id: language.id,
        organization_id: organization_id
      }

      assert {:error, message} = Template.submit_for_approval(attrs)
      assert message =~ "already exists"

      refute Repo.get_by(SessionTemplate,
               bsp_id: "dup_template",
               organization_id: organization_id
             )
    end

    test "rejects a non-text template type without calling the BSP",
         %{organization_id: organization_id} do
      Tesla.Mock.mock(fn _env ->
        flunk("BSP should not have been called for a non-text template")
      end)

      attrs = %{
        shortcode: "media_template",
        type: :image,
        body: "Hi {{1}}",
        organization_id: organization_id
      }

      assert {:error, message} = Template.submit_for_approval(attrs)
      assert message =~ "text templates only"
      assert message =~ "ADR-005"
    end

    test "F-081: rejects an HSM text template with has_buttons: true without calling the BSP",
         %{organization_id: organization_id} do
      Tesla.Mock.mock(fn _env ->
        flunk("BSP should not have been called for a button-carrying template")
      end)

      attrs = %{
        shortcode: "button_template",
        type: :text,
        body: "Hi {{1}}",
        has_buttons: true,
        button_type: "quick_reply",
        buttons: [%{"text" => "Yes"}],
        organization_id: organization_id
      }

      assert {:error, message} = Template.submit_for_approval(attrs)
      assert message =~ "buttons"
      assert message =~ "not supported"

      refute Repo.get_by(SessionTemplate,
               shortcode: "button_template",
               organization_id: organization_id
             )
    end

    test "rejects an invalid shortcode before calling the BSP",
         %{organization_id: organization_id} do
      Tesla.Mock.mock(fn _env ->
        flunk("BSP should not have been called for an invalid name")
      end)

      attrs = %{
        shortcode: "Invalid Name!",
        type: :text,
        body: "Hi {{1}}",
        organization_id: organization_id
      }

      assert {:error, message} = Template.submit_for_approval(attrs)
      assert message =~ "invalid"
    end

    test "rejects a shortcode exceeding 50 characters before calling the BSP",
         %{organization_id: organization_id} do
      Tesla.Mock.mock(fn _env ->
        flunk("BSP should not have been called for an over-length name")
      end)

      attrs = %{
        shortcode: String.duplicate("a", 51),
        type: :text,
        body: "Hi {{1}}",
        organization_id: organization_id
      }

      assert {:error, message} = Template.submit_for_approval(attrs)
      assert message =~ "50-character limit"
    end

    test "surfaces a connection failure without raising", %{organization_id: organization_id} do
      Tesla.Mock.mock(fn %{method: :post} -> {:error, :timeout} end)

      language = Fixtures.language_fixture()

      attrs = %{
        shortcode: "conn_fail_template",
        label: "Conn Fail",
        body: "Hi {{1}}",
        type: :text,
        category: "UTILITY",
        example: "Hi Priya",
        is_hsm: true,
        language_id: language.id,
        organization_id: organization_id
      }

      assert {:error, message} = Template.submit_for_approval(attrs)
      assert message =~ "BSP Couldn't connect"
    end
  end

  describe "update_hsm_templates/1 (T-03 status sync + T-04 pull sync)" do
    @spec approved_swiftchat_template(non_neg_integer(), String.t(), String.t()) ::
            SessionTemplate.t()
    defp approved_swiftchat_template(organization_id, template_name, status \\ "PENDING") do
      language = Fixtures.language_fixture()

      {:ok, template} =
        Templates.do_create_session_template(%{
          bsp_id: template_name,
          shortcode: template_name,
          label: template_name,
          body: "Hi {{1}}",
          type: :text,
          is_hsm: true,
          status: status,
          number_parameters: 1,
          language_id: language.id,
          organization_id: organization_id
        })

      template
    end

    test "never raises on a non-200/transient BSP failure", %{organization_id: organization_id} do
      Tesla.Mock.mock(fn %{method: :get} -> %Tesla.Env{status: 500, body: "boom"} end)

      assert {:error, "BSP Couldn't connect"} = Template.update_hsm_templates(organization_id)
    end

    test "never raises on a network timeout", %{organization_id: organization_id} do
      Tesla.Mock.mock(fn %{method: :get} -> {:error, :timeout} end)

      assert {:error, "BSP Couldn't connect"} = Template.update_hsm_templates(organization_id)
    end

    test "Templates.sync_hsms_from_bsp/1 propagates the same error contract (regression test)",
         %{organization_id: organization_id} do
      Tesla.Mock.mock(fn %{method: :get} -> {:error, :timeout} end)

      assert {:error, "BSP Couldn't connect"} = Templates.sync_hsms_from_bsp(organization_id)
    end

    test "ACTIVE transition updates status to APPROVED and fires a notification once",
         %{organization_id: organization_id} do
      template = approved_swiftchat_template(organization_id, "order_confirmation")

      Tesla.Mock.mock(fn %{method: :get} ->
        %Tesla.Env{
          status: 200,
          body:
            Jason.encode!(%{
              "data" => [
                %{"name" => "order_confirmation", "type" => "text", "status" => "ACTIVE"}
              ]
            })
        }
      end)

      assert :ok = Template.update_hsm_templates(organization_id)

      updated = Repo.get!(SessionTemplate, template.id)
      assert updated.status == "APPROVED"
      assert updated.is_active == true

      notifications =
        Repo.all(Notification) |> Enum.filter(&(&1.organization_id == organization_id))

      assert Enum.any?(notifications, &(&1.message =~ "order_confirmation"))

      # Second, identical poll must not duplicate the notification (idempotency).
      notification_count_after_first = length(notifications)

      assert :ok = Template.update_hsm_templates(organization_id)

      notifications_after_second =
        Repo.all(Notification) |> Enum.filter(&(&1.organization_id == organization_id))

      assert length(notifications_after_second) == notification_count_after_first
    end

    test "REJECTED transition updates status/reason and fires a notification",
         %{organization_id: organization_id} do
      template = approved_swiftchat_template(organization_id, "rejected_template")

      Tesla.Mock.mock(fn %{method: :get} ->
        %Tesla.Env{
          status: 200,
          body:
            Jason.encode!(%{
              "data" => [
                %{
                  "name" => "rejected_template",
                  "type" => "text",
                  "status" => "REJECTED",
                  "status_reason" => "Content policy violation"
                }
              ]
            })
        }
      end)

      assert :ok = Template.update_hsm_templates(organization_id)

      updated = Repo.get!(SessionTemplate, template.id)
      assert updated.status == "REJECTED"
      assert updated.reason == "Content policy violation"
      assert updated.is_active == false

      notifications =
        Repo.all(Notification) |> Enum.filter(&(&1.organization_id == organization_id))

      assert Enum.any?(notifications, &(&1.message =~ "rejected_template"))
    end

    test "an unrecognized status string maps to PENDING and does not crash",
         %{organization_id: organization_id} do
      template = approved_swiftchat_template(organization_id, "unknown_status_template")

      Tesla.Mock.mock(fn %{method: :get} ->
        %Tesla.Env{
          status: 200,
          body:
            Jason.encode!(%{
              "data" => [
                %{
                  "name" => "unknown_status_template",
                  "type" => "text",
                  "status" => "SOME_NEW_STATUS"
                }
              ]
            })
        }
      end)

      assert :ok = Template.update_hsm_templates(organization_id)

      updated = Repo.get!(SessionTemplate, template.id)
      assert updated.status == "PENDING"
    end

    test "re-running the same poll twice does not duplicate rows or re-fire notifications",
         %{organization_id: organization_id} do
      approved_swiftchat_template(organization_id, "idempotent_template")

      Tesla.Mock.mock(fn %{method: :get} ->
        %Tesla.Env{
          status: 200,
          body:
            Jason.encode!(%{
              "data" => [
                %{"name" => "idempotent_template", "type" => "text", "status" => "ACTIVE"}
              ]
            })
        }
      end)

      assert :ok = Template.update_hsm_templates(organization_id)

      count_after_first =
        Repo.all(SessionTemplate) |> Enum.count(&(&1.organization_id == organization_id))

      assert :ok = Template.update_hsm_templates(organization_id)

      count_after_second =
        Repo.all(SessionTemplate) |> Enum.count(&(&1.organization_id == organization_id))

      assert count_after_first == count_after_second
    end

    test "accepts the flat {\"data\": [...]} list shape", %{organization_id: organization_id} do
      template = approved_swiftchat_template(organization_id, "flat_shape_template")

      Tesla.Mock.mock(fn %{method: :get} ->
        %Tesla.Env{
          status: 200,
          body:
            Jason.encode!(%{
              "data" => [
                %{"name" => "flat_shape_template", "type" => "text", "status" => "ACTIVE"}
              ]
            })
        }
      end)

      assert :ok = Template.update_hsm_templates(organization_id)
      updated = Repo.get!(SessionTemplate, template.id)
      assert updated.status == "APPROVED"
    end

    test "accepts the doubly-nested {\"data\": [[...]]} list shape",
         %{organization_id: organization_id} do
      template = approved_swiftchat_template(organization_id, "nested_shape_template")

      Tesla.Mock.mock(fn %{method: :get} ->
        %Tesla.Env{
          status: 200,
          body:
            Jason.encode!(%{
              "data" => [
                [%{"name" => "nested_shape_template", "type" => "text", "status" => "ACTIVE"}]
              ]
            })
        }
      end)

      assert :ok = Template.update_hsm_templates(organization_id)
      updated = Repo.get!(SessionTemplate, template.id)
      assert updated.status == "APPROVED"
    end

    test "pull-sync (T-04/F-114): a dashboard-created template with no local row is imported " <>
           "end-to-end (list has no body -> single-fetch supplies it -> row created)",
         %{organization_id: organization_id} do
      Tesla.Mock.mock(fn %{method: :get, url: url} ->
        if String.ends_with?(url, "/templates/dashboard_only_template") do
          # F-114: single-template GET DOES carry the body — the live-verified
          # shape this fix relies on.
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "template" => %{
                  "type" => "text",
                  "text" => %{"body" => "Hi {1}, your code is {2}."}
                },
                "status" => "PENDING_REVIEW",
                "status_reason" => nil,
                "created_at" => "2026-08-14T05:30:00Z"
              })
          }
        else
          # F-114 regression pin: the LIST response carries NO `body`/
          # `template` field at all — this is the live-verified shape
          # (name/type/status/created_at/status_reason only). Do NOT add a
          # body/template key back here; the whole point of this test is
          # to prove the import path survives a body-less list entry.
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "data" => [
                  %{
                    "name" => "dashboard_only_template",
                    "type" => "text",
                    "status" => "ACTIVE",
                    "created_at" => "2026-08-14T05:00:00Z"
                  }
                ]
              })
          }
        end
      end)

      refute Repo.get_by(SessionTemplate,
               bsp_id: "dashboard_only_template",
               organization_id: organization_id
             )

      assert :ok = Template.update_hsm_templates(organization_id)

      imported =
        Repo.get_by(SessionTemplate,
          bsp_id: "dashboard_only_template",
          organization_id: organization_id
        )

      assert imported
      assert imported.shortcode == "dashboard_only_template"
      assert imported.body == "Hi {{1}}, your code is {{2}}."
      assert imported.number_parameters == 2
      assert imported.is_hsm == true
      # status/is_active still come from the LIST entry's "status" field,
      # unaffected by the single-fetch (which reports "PENDING_REVIEW" —
      # only the body/number_parameters come from the single fetch).
      assert imported.status == "APPROVED"
      assert imported.is_active == true

      organization = Partners.organization(organization_id)
      assert imported.language_id == organization.default_language_id
    end

    test "pull-sync (F-114): single-template fetch failing (non-200) skips the template " <>
           "this cycle, no partial row, no crash",
         %{organization_id: organization_id} do
      Tesla.Mock.mock(fn %{method: :get, url: url} ->
        if String.ends_with?(url, "/templates/fetch_fails_template") do
          %Tesla.Env{status: 500, body: "boom"}
        else
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "data" => [
                  %{"name" => "fetch_fails_template", "type" => "text", "status" => "ACTIVE"}
                ]
              })
          }
        end
      end)

      assert :ok = Template.update_hsm_templates(organization_id)

      refute Repo.get_by(SessionTemplate,
               bsp_id: "fetch_fails_template",
               organization_id: organization_id
             )
    end

    test "pull-sync (F-114): single-template fetch network error skips the template " <>
           "this cycle, no partial row, no crash",
         %{organization_id: organization_id} do
      Tesla.Mock.mock(fn %{method: :get, url: url} ->
        if String.ends_with?(url, "/templates/network_fail_template") do
          {:error, :timeout}
        else
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "data" => [
                  %{"name" => "network_fail_template", "type" => "text", "status" => "ACTIVE"}
                ]
              })
          }
        end
      end)

      assert :ok = Template.update_hsm_templates(organization_id)

      refute Repo.get_by(SessionTemplate,
               bsp_id: "network_fail_template",
               organization_id: organization_id
             )
    end

    test "pull-sync (F-114): a non-text single-template response is skipped (ADR-005 " <>
           "text-only scope), not crashed",
         %{organization_id: organization_id} do
      Tesla.Mock.mock(fn %{method: :get, url: url} ->
        if String.ends_with?(url, "/templates/image_dashboard_template") do
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "template" => %{"type" => "image"},
                "status" => "ACTIVE",
                "status_reason" => nil
              })
          }
        else
          %Tesla.Env{
            status: 200,
            body:
              Jason.encode!(%{
                "data" => [
                  %{"name" => "image_dashboard_template", "type" => "image", "status" => "ACTIVE"}
                ]
              })
          }
        end
      end)

      assert :ok = Template.update_hsm_templates(organization_id)

      refute Repo.get_by(SessionTemplate,
               bsp_id: "image_dashboard_template",
               organization_id: organization_id
             )
    end

    test "pull-sync: a Glific-submitted template (already has a matching bsp_id) is never duplicated",
         %{organization_id: organization_id} do
      approved_swiftchat_template(organization_id, "already_known_template")

      Tesla.Mock.mock(fn %{method: :get} ->
        %Tesla.Env{
          status: 200,
          body:
            Jason.encode!(%{
              "data" => [
                %{"name" => "already_known_template", "type" => "text", "status" => "ACTIVE"}
              ]
            })
        }
      end)

      assert :ok = Template.update_hsm_templates(organization_id)

      matches =
        Repo.all(SessionTemplate)
        |> Enum.filter(
          &(&1.bsp_id == "already_known_template" and &1.organization_id == organization_id)
        )

      assert length(matches) == 1
    end
  end

  describe "delete/2 (T-05: real BSP-side delete)" do
    test "calls the SwiftChat delete endpoint and returns :ok on 200",
         %{organization_id: organization_id} do
      Tesla.Mock.mock(fn %{method: :delete, url: url} ->
        assert url =~ "/merchants/test_merchant_id/templates/order_confirmation"
        %Tesla.Env{status: 200, body: "OK"}
      end)

      assert {:ok, _attrs} =
               Template.delete(organization_id, %{bsp_id: "order_confirmation"})
    end

    test "tolerates a 409/122 (already deleted) as success",
         %{organization_id: organization_id} do
      Tesla.Mock.mock(fn %{method: :delete} ->
        %Tesla.Env{status: 409, body: Jason.encode!(%{"code" => 122, "message" => "gone"})}
      end)

      assert {:ok, _attrs} = Template.delete(organization_id, %{bsp_id: "already_deleted"})
    end

    test "tolerates a 404/118 (not found) as success", %{organization_id: organization_id} do
      Tesla.Mock.mock(fn %{method: :delete} ->
        %Tesla.Env{status: 404, body: Jason.encode!(%{"code" => 118, "message" => "not found"})}
      end)

      assert {:ok, _attrs} = Template.delete(organization_id, %{bsp_id: "never_existed"})
    end

    test "returns {:error, _} on any other BSP error, safely logged",
         %{organization_id: organization_id} do
      Tesla.Mock.mock(fn %{method: :delete} ->
        %Tesla.Env{status: 500, body: Jason.encode!(%{"code" => 999, "message" => "boom"})}
      end)

      assert {:error, _reason} = Template.delete(organization_id, %{bsp_id: "boom_template"})
    end

    test "surfaces a connection failure as an error, not a raise",
         %{organization_id: organization_id} do
      Tesla.Mock.mock(fn %{method: :delete} -> {:error, :timeout} end)

      assert {:error, _reason} = Template.delete(organization_id, %{bsp_id: "conn_fail"})
    end

    test "a row with no bsp_id is a local no-op (nothing to clean up BSP-side)",
         %{organization_id: organization_id} do
      Tesla.Mock.mock(fn _env -> flunk("BSP should not have been called with no bsp_id") end)

      assert {:ok, %{some: :attrs}} = Template.delete(organization_id, %{some: :attrs})
    end
  end

  describe "T-06: remaining unimplemented callbacks name their operation, distinct from the shipped ones" do
    test "import_templates/2 names 'import' as unimplemented, does not reference phase-1 framing" do
      assert {:error, message} = Template.import_templates(1, "")
      assert message =~ "import"
      refute message =~ "phase 1"
    end

    test "bulk_apply_templates/2 names 'bulk-apply' as unimplemented" do
      assert {:error, message} = Template.bulk_apply_templates(1, "")
      assert message =~ "bulk-apply"
      refute message =~ "phase 1"
    end

    test "edit_approved_template/2 names 'edit-approved-template' as unimplemented" do
      assert {:error, message} = Template.edit_approved_template(1, %{})
      assert message =~ "edit-approved-template"
      refute message =~ "phase 1"
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
