defmodule SymphonyElixir.Repo.Migrations.AddCaseProjectionIndexes do
  use Ecto.Migration

  # Indexes for the Case Center projection (spec §11.3):
  # - deliveries of a case (effect aggregation and case detail);
  # - work runs by Linear issue (implementation runs of an intake case);
  # - the newest work run per (project_id, coalesce(linear_issue_id, dedupe_key, id)).
  def change do
    create(index(:integration_deliveries, [:case_id], where: "case_id IS NOT NULL"))
    create(index(:work_runs, [:linear_issue_id], where: "linear_issue_id IS NOT NULL"))

    create(
      index(:work_runs, ["project_id", "(COALESCE(linear_issue_id, dedupe_key, id::text))", "inserted_at DESC", "id DESC"],
        name: :work_runs_source_key_index,
        where: "type <> 'jira_analysis'"
      )
    )
  end
end
