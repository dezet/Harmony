defmodule SymphonyElixir.Repo.Migrations.AddRulePriorityRanking do
  use Ecto.Migration

  # Jira priority IDs in the order of the Jira `priority/search` response,
  # stored when a rule is activated. NULL means no ranking is known.
  def change do
    alter table(:automation_rules) do
      add(:priority_ranking, {:array, :text})
    end
  end
end
