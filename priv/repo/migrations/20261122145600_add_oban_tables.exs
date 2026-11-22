defmodule SecantService.Repo.Migrations.AddObanTables do
  @moduledoc """
  The Oban job tables, for AshOban. Hand-written: the Ash migration
  generator does not know about them. A newer Oban that raises the schema
  version needs another migration calling `Oban.Migrations.up(version: n)`.
  """
  use Ecto.Migration

  def up, do: Oban.Migrations.up(version: 14)

  def down, do: Oban.Migrations.down(version: 1)
end
