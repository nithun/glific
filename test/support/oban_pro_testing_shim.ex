if not Code.ensure_loaded?(Oban.Pro.Testing) do
  defmodule Oban.Pro.Testing do
    @moduledoc """
    Free-Oban local shim. Only compiled under `test/support/` (test envs only —
    see `elixirc_paths/1` in mix.exs), and only defined when the real
    `Oban.Pro.Testing` isn't available (no Oban Pro license).

    Every call site in this project's test suite is a bare
    `use Oban.Pro.Testing, repo: Glific.Repo` — it doesn't reach for any
    Pro-only assertion helper beyond what the free `Oban.Testing` module
    already provides (`assert_enqueued`, `refute_enqueued`, `all_enqueued`,
    etc.), so delegating is sufficient. If a future test starts using a
    genuinely Pro-only helper (e.g. batch/workflow assertions), this shim
    will need a matching addition — or an Oban Pro license.
    """

    defmacro __using__(opts) do
      quote do
        use Oban.Testing, unquote(opts)
      end
    end
  end
end
