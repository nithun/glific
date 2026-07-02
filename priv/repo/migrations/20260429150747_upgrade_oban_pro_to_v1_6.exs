defmodule Glific.Repo.Migrations.UpgradeObanProToV1_6 do
  use Ecto.Migration

  # free-Oban path: no-op when Oban Pro isn't loaded (dev/test without a license).
  def up do
    if Code.ensure_loaded?(Oban.Pro.Migration),
      do: Oban.Pro.Migration.up(version: "1.6.0", prefix: "global"),
      else: :ok
  end

  def down do
    if Code.ensure_loaded?(Oban.Pro.Migration),
      do: Oban.Pro.Migration.down(version: "1.5.0", prefix: "global"),
      else: :ok
  end
end
