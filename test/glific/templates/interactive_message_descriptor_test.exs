defmodule Glific.Templates.InteractiveMessageDescriptorTest do
  use ExUnit.Case, async: true

  alias Glific.Templates.InteractiveMessageDescriptor

  describe "validate/2 — permissive cases (ADR-016 rule 1, zero behavior change)" do
    test "nil content is untouched" do
      assert :ok == InteractiveMessageDescriptor.validate(:quick_reply, nil)
    end

    test "empty map content is untouched — matches InteractiveTemplate.changeset/2's own %{} contract" do
      assert :ok == InteractiveMessageDescriptor.validate(:quick_reply, %{})
    end

    test "content with no \"type\" key at all is untouched (e.g. atom-keyed or partial content)" do
      assert :ok == InteractiveMessageDescriptor.validate(:quick_reply, %{a: 1})
    end

    test "a type this descriptor doesn't know about is left unvalidated (ADR-016 rule 4)" do
      assert :ok ==
               InteractiveMessageDescriptor.validate(:some_future_type, %{
                 "type" => "some_future_type"
               })
    end
  end

  describe "validate/2 — the three existing types' REAL production shapes validate with zero behavior change" do
    test "quick_reply (text) — seeds_dev.ex shape" do
      content = %{
        "type" => "quick_reply",
        "content" => %{
          "type" => "text",
          "header" => "Quick Reply Text",
          "text" => "Glific is a two way communication platform"
        },
        "options" => [
          %{"type" => "text", "title" => "Excited"},
          %{"type" => "text", "title" => "Very Excited"}
        ]
      }

      assert :ok == InteractiveMessageDescriptor.validate(:quick_reply, content)
    end

    test "quick_reply (image, no header) — test/support/fixtures.ex shape" do
      content = %{
        "type" => "quick_reply",
        "content" => %{"type" => "text", "text" => "Test glific quick reply?"},
        "options" => [
          %{"type" => "text", "title" => "Test 1"},
          %{"type" => "text", "title" => "Test 2"}
        ]
      }

      assert :ok == InteractiveMessageDescriptor.validate(:quick_reply, content)
    end

    test "list — seeds_dev.ex shape" do
      content = %{
        "type" => "list",
        "title" => "Interactive list",
        "body" => "Glific",
        "globalButtons" => [%{"type" => "text", "title" => "button text"}],
        "items" => [
          %{
            "title" => "Glific Features",
            "subtitle" => "first Subtitle",
            "options" => [
              %{"type" => "text", "title" => "Custom Flows", "description" => "desc"}
            ]
          }
        ]
      }

      assert :ok == InteractiveMessageDescriptor.validate(:list, content)
    end

    test "location_request_message — seeds_dev.ex shape" do
      content = %{
        "type" => "location_request_message",
        "body" => %{"type" => "text", "text" => "please share your location"},
        "action" => %{"name" => "send_location"}
      }

      assert :ok == InteractiveMessageDescriptor.validate(:location_request_message, content)
    end
  end

  describe "validate/2 — strict on the type cross-check (ADR-016 rule 1)" do
    test "content declares a different type than the template's type column" do
      content = %{
        "type" => "list",
        "content" => %{"type" => "text", "text" => "hi"},
        "options" => []
      }

      assert {:error, message} = InteractiveMessageDescriptor.validate(:quick_reply, content)
      assert message =~ "does not match"
      assert message =~ "list"
      assert message =~ "quick_reply"
    end
  end

  describe "validate/2 — strict on declared required top-level keys" do
    test "quick_reply missing \"options\"" do
      content = %{"type" => "quick_reply", "content" => %{"type" => "text", "text" => "hi"}}

      assert {:error, message} = InteractiveMessageDescriptor.validate(:quick_reply, content)
      assert message =~ "options"
    end

    test "list missing \"globalButtons\" and \"items\"" do
      content = %{"type" => "list", "title" => "t", "body" => "b"}

      assert {:error, message} = InteractiveMessageDescriptor.validate(:list, content)
      assert message =~ "globalButtons"
      assert message =~ "items"
    end

    test "location_request_message missing \"action\"" do
      content = %{
        "type" => "location_request_message",
        "body" => %{"type" => "text", "text" => "hi"}
      }

      assert {:error, message} =
               InteractiveMessageDescriptor.validate(:location_request_message, content)

      assert message =~ "action"
    end
  end

  describe "supported?/2 (ADR-016 rule 3: capability declaration)" do
    test "plain gupshup supports all 3 existing types — verbatim passthrough grandfather clause" do
      assert InteractiveMessageDescriptor.supported?("gupshup", :quick_reply)
      assert InteractiveMessageDescriptor.supported?("gupshup", :list)
      assert InteractiveMessageDescriptor.supported?("gupshup", :location_request_message)
    end

    test "gupshup_enterprise supports quick_reply/list only — matches parse_interactive_message/2 post-T06" do
      assert InteractiveMessageDescriptor.supported?("gupshup_enterprise", :quick_reply)
      assert InteractiveMessageDescriptor.supported?("gupshup_enterprise", :list)

      refute InteractiveMessageDescriptor.supported?(
               "gupshup_enterprise",
               :location_request_message
             )
    end

    test "swiftchat supports quick_reply/list only — matches send_interactive/2's current mapping" do
      assert InteractiveMessageDescriptor.supported?("swiftchat", :quick_reply)
      assert InteractiveMessageDescriptor.supported?("swiftchat", :list)
      refute InteractiveMessageDescriptor.supported?("swiftchat", :location_request_message)
    end

    test "maytapi supports none of the 3 existing types — it never implements MessageBehaviour's send_interactive/2" do
      refute InteractiveMessageDescriptor.supported?("maytapi", :quick_reply)
      refute InteractiveMessageDescriptor.supported?("maytapi", :list)
      refute InteractiveMessageDescriptor.supported?("maytapi", :location_request_message)
    end

    test "an undeclared type is unsupported by every provider (fail closed)" do
      refute InteractiveMessageDescriptor.supported?("gupshup", :some_future_type)
    end
  end

  test "known_types/0 lists exactly the 3 currently-declared types" do
    assert Enum.sort(InteractiveMessageDescriptor.known_types()) ==
             Enum.sort([:quick_reply, :list, :location_request_message])
  end
end
