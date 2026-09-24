defmodule SymphonyElixir.Repo.Migrations.AddProjectDisplayName do
  use Ecto.Migration

  def up do
    alter table(:projects) do
      add(:display_name, :text)
    end

    create(
      constraint(:projects, :projects_display_name_length_check,
        check: "display_name IS NULL OR char_length(display_name) BETWEEN 1 AND 100"
      )
    )
  end

  def down do
    drop(constraint(:projects, :projects_display_name_length_check))

    alter table(:projects) do
      remove(:display_name)
    end
  end
end
