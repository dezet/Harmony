defmodule SymphonyElixir.Repo.Migrations.AddUniqueOpenBlockerIndex do
  use Ecto.Migration

  def change do
    create(
      unique_index(:blockers, [:project_id, :target_type, :target_id, :status],
        where: "status = 'open'",
        name: :blockers_unique_open_target
      )
    )
  end
end
