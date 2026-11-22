defmodule SecantService.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  It uses shared sandbox mode so that spawned processes
  (e.g. from Ash managed relationships or Oban) can
  access the same database connection.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias SecantService.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import SecantService.Generators
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(SecantService.Repo, shared: not tags[:async])

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    :ok
  end
end
