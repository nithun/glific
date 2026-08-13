# `priv/repo/migrations/` — Database Migrations

~85 timestamp-named migrations. Migrations are **append-only and immutable once merged** — never
edit a migration that has shipped; write a new one to change course. The dev/test schema is also
captured in `priv/repo/structure.sql` — **but that file is a frozen snapshot (last
regenerated 2023-07-10), not kept in sync automatically.** `mix ecto.migrate` does
**NOT** regenerate it (F-086(c) doc correction — verified against every alias in
`mix.exs` that touches Ecto: `ecto.setup`/`ecto.reset`/`test`/`test_full` all run
`ecto.load --skip-if-loaded` then `ecto.migrate`, and none of them call `ecto.dump`).
Do **not** hand-edit `structure.sql` to "fix" this drift — if it ever needs
regenerating, that is a deliberate `mix ecto.dump` run against a fully-migrated DB,
done once, reviewed as its own change.

> Read this before adding a migration. Pairs with the schema conventions in `lib/glific/CLAUDE.md`.

## Naming & creation

```bash
mix ecto.gen.migration add_widgets       # → priv/repo/migrations/<YYYYMMDDhhmmss>_add_widgets.exs
```

Use `def change` (auto-reversible) whenever possible. Use `def up`/`def down` only for operations
Ecto can't auto-reverse (raw SQL, data backfills, `execute/2`).

## Glific conventions (mirror `20260513140000_add_wa_groups_phones.exs`)

```elixir
defmodule Glific.Repo.Migrations.AddWidgets do
  use Ecto.Migration

  def change do
    create table(:widgets) do
      add :name, :string, null: false, comment: "Human label for the widget"

      add :organization_id, references(:organizations, on_delete: :delete_all),
        null: false,
        comment: "Organization scope"          # EVERY tenant table needs this FK

      timestamps(type: :utc_datetime)
    end

    create unique_index(:widgets, [:name, :organization_id])  # scope uniqueness by org
    create index(:widgets, [:organization_id])                # index the tenant FK
  end
end
```

Hard rules observed across the codebase:

- **`organization_id` on every tenant-scoped table**, as `references(:organizations, on_delete: :delete_all), null: false`, plus a plain index on it. This is what makes `Repo.prepare_query` auto-scoping work.
- **Scope unique constraints by org**: `unique_index(:t, [:field, :organization_id])`, never a bare
  `unique_index(:t, [:field])` — the matching schema `unique_constraint/2` must use the same
  column list or the friendly error won't fire.
- `timestamps(type: :utc_datetime)` on every table.
- Add `comment:` to columns and tables — Glific migrations are well-commented; keep that up.
- Soft deletes use a `deleted_at :utc_datetime` column with a **partial index**
  `where: "deleted_at IS NULL"`. Other partial/conditional indexes (e.g. one-primary-per-group)
  follow the same `where:`/`name:` pattern.
- Choose `on_delete:` deliberately: `:delete_all` for owned children, `:nilify_all` for optional
  refs, `:restrict`/`:nothing` to protect referenced rows.

## Big tables & safe operations

Production tables (messages, contacts, flow_contexts, etc.) are large. On those:

- Adding a column with a non-null default rewrites the table — prefer nullable + backfill, or set
  the default in a follow-up. For concurrent index creation use
  `create index(..., concurrently: true)` with `@disable_ddl_transaction true` and
  `@disable_migration_lock true` at the top of the module.
- Heavy data backfills belong in a **separate** migration (or an Oban job), kept idempotent, and
  should batch rather than load everything at once.

## After writing a migration

1. `mix ecto.migrate` (applies the migration to your local DB — does **NOT** update
   `structure.sql`; see the frozen-snapshot note above).
2. Add/adjust the Ecto schema field + `@type t()` + changeset (`lib/glific/CLAUDE.md`).
3. Seed any reference rows in `priv/repo/seeds_dev.exs` if dev/tests rely on them.
4. Run the relevant tests; `mix test` loads `structure.sql` then runs `ecto.migrate` on
   top of it (`mix.exs` aliases), so a fresh test DB reflects both the frozen snapshot
   AND every migration since — including yours.

Never hand-edit `structure.sql` and never delete/renumber a merged migration — both desync the
schema across environments.
