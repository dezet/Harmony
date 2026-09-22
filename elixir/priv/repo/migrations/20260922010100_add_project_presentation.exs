defmodule SymphonyElixir.Repo.Migrations.AddProjectPresentation do
  use Ecto.Migration

  def up do
    alter table(:projects) do
      add(:ui_color, :text, null: false, default: "purple")
    end

    create(constraint(:projects, :projects_ui_color_check, check: "ui_color IN ('purple', 'gold', 'teal')"))
  end

  def down do
    drop(constraint(:projects, :projects_ui_color_check))

    alter table(:projects) do
      remove(:ui_color)
    end
  end
end
