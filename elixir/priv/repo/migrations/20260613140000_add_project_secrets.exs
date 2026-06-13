defmodule SymphonyElixir.Repo.Migrations.AddProjectSecrets do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :forge_secret, :binary
      add :tracker_secret, :binary
    end
  end
end
