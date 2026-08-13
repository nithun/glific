defmodule Glific.Templates.InteractiveMessageDescriptor do
  @moduledoc """
  ADR-016's descriptor + capability-gated extension seam for interactive
  message types (`Glific.Enums.InteractiveMessageType`).

  This is the single Glific-owned source of truth for two independent
  concerns that both scale per-type as PRD-005 widens the type set:

  1. **Rule 1 — canonical schema.** What top-level keys a valid
     `interactive_content` JSON blob must carry for a given type, and the
     cross-check that `interactive_content["type"]` agrees with the row's
     `type` column (`InteractiveTemplate.changeset/2` calls `validate/2`).
  2. **Rule 3 — capability declaration.** Which BSPs are declared to
     support which type, consulted by `Glific.Communications.Message` at
     the pre-provider dispatch chokepoint (`supported?/2`) so an
     unsupported `(provider, type)` pair is rejected loudly *before* the
     provider module is ever reached — closing the `FunctionClauseError`
     bug class (F-085) structurally rather than per type.

  Adding a new interactive type = adding one entry to `@descriptors`
  (ADR-016 rule 4). A type with no entry here is left unvalidated by
  `validate/2` (existing rows / in-progress authoring are tolerated, per
  ADR-016 Consequences: "validate on write, warn-not-fail on read") and is
  declared unsupported by every provider via `supported?/2` (fail closed).

  `providers` values are BSP `Partners.Provider.shortcode` strings (the
  same strings matched throughout `partners.ex`, e.g.
  `validate_secrets?/2`), not module names — this module never references
  provider modules directly, keeping it free of the `providers/`
  dependency.
  """

  @type descriptor :: %{
          required_keys: [String.t()],
          providers: [String.t()]
        }

  # Required top-level keys are derived from the 3 existing types' REAL
  # seeded/production shapes (`lib/glific/seeds/seeds_dev.ex:seed_interactives/1`,
  # `test/support/fixtures.ex:interactive_fixture/1`, and every valid_*_attrs
  # fixture across the interactive-template test suite) — every one of
  # those shapes carries exactly these keys, and every downstream reader in
  # `interactive_templates.ex` (`trim_content/2`, `build_content_to_translate/1`,
  # etc.) already assumes they're present, crashing otherwise. Deliberately
  # NOT validated deeper than this (nested "content"/"items" structure) —
  # permissive on optional keys per T13's acceptance criteria.
  @descriptors %{
    quick_reply: %{
      required_keys: ["content", "options"],
      providers: ["gupshup", "gupshup_enterprise", "swiftchat"]
    },
    list: %{
      required_keys: ["title", "body", "globalButtons", "items"],
      providers: ["gupshup", "gupshup_enterprise", "swiftchat"]
    },
    location_request_message: %{
      required_keys: ["body", "action"],
      # Gupshup Enterprise: F-085/T06 closed the crash, but never added
      # positive support (parse_interactive_message/2 has clauses only for
      # quick_reply/list) — declaring it here would misrepresent capability.
      # SwiftChat: send_interactive/2's catch-all rejects it today (no
      # SwiftChat equivalent) — same reasoning.
      providers: ["gupshup"]
    }
  }

  @doc "Every interactive type this descriptor currently declares."
  @spec known_types() :: [atom()]
  def known_types, do: Map.keys(@descriptors)

  @doc """
  Validates `interactive_content` against `type`'s declared schema.

  Deliberately permissive, in this order:
  - `nil`/empty content, or content with no `"type"` key at all: `:ok`
    (nothing to cross-check — covers legacy/in-progress rows and the
    pre-existing `interactive_content: %{}` contract exercised by
    `InteractiveTemplate.changeset/2`'s own test suite).
  - content type present but a type this descriptor doesn't (yet) know
    about: `:ok` (ADR-016 rule 4 — a type lands its own descriptor entry;
    until then it's unvalidated, not rejected).
  - content type present and known: strict on (a) the type cross-check and
    (b) declared required top-level keys.
  """
  @spec validate(atom() | nil, map() | nil) :: :ok | {:error, String.t()}
  def validate(type, content) when is_map(content) and map_size(content) > 0 do
    case Map.get(content, "type") do
      nil -> :ok
      content_type -> validate_type_match(type, content_type, content)
    end
  end

  def validate(_type, _content), do: :ok

  @spec validate_type_match(atom() | nil, String.t(), map()) :: :ok | {:error, String.t()}
  defp validate_type_match(type, content_type, content) do
    declared_type = type && Atom.to_string(type)

    cond do
      content_type != declared_type ->
        {:error,
         "interactive_content[\"type\"] (#{inspect(content_type)}) does not match this " <>
           "template's type (#{inspect(declared_type)})"}

      Map.has_key?(@descriptors, type) ->
        validate_required_keys(type, content)

      true ->
        :ok
    end
  end

  @spec validate_required_keys(atom(), map()) :: :ok | {:error, String.t()}
  defp validate_required_keys(type, content) do
    missing =
      @descriptors
      |> Map.fetch!(type)
      |> Map.fetch!(:required_keys)
      |> Enum.reject(&Map.has_key?(content, &1))

    case missing do
      [] ->
        :ok

      keys ->
        {:error,
         "interactive_content for type #{type} is missing required key(s): #{Enum.join(keys, ", ")}"}
    end
  end

  @doc """
  ADR-016 rule 3: is `provider` (a BSP `shortcode`, e.g. `"gupshup"`)
  declared to support `type`? Fails closed — an undeclared type, or a
  provider not listed for a declared type, is unsupported.
  """
  @spec supported?(String.t(), atom()) :: boolean()
  def supported?(provider, type) do
    case Map.get(@descriptors, type) do
      nil -> false
      %{providers: providers} -> provider in providers
    end
  end
end
