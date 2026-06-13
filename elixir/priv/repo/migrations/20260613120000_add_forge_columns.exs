defmodule SymphonyElixir.Repo.Migrations.AddForgeColumns do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :forge_type, :string, default: "github", null: false
      add :forge_owner, :string
      add :forge_repo, :string
      add :forge_base_branch, :string
      add :forge_base_url, :string
    end

    alter table(:work_runs) do
      add :forge_owner, :string
      add :forge_repo, :string
      add :forge_pr_number, :integer
      add :forge_head_sha, :string
      add :forge_head_ref, :string
      add :forge_base_ref, :string
    end

    alter table(:pull_request_links) do
      add :forge_owner, :string
      add :forge_repo, :string
      add :forge_pr_number, :integer
      add :forge_head_sha, :string
      add :forge_head_ref, :string
      add :forge_base_ref, :string
    end

    # Backfill: every existing row is GitHub.
    execute(
      "UPDATE projects SET forge_owner = github_owner, forge_repo = github_repo, forge_base_branch = github_base_branch WHERE forge_owner IS NULL",
      "SELECT 1"
    )

    execute(
      "UPDATE work_runs SET forge_owner = github_owner, forge_repo = github_repo, forge_pr_number = github_pr_number, forge_head_sha = github_head_sha, forge_head_ref = github_head_ref, forge_base_ref = github_base_ref",
      "SELECT 1"
    )

    execute(
      "UPDATE pull_request_links SET forge_owner = github_owner, forge_repo = github_repo, forge_pr_number = github_pr_number, forge_head_sha = github_head_sha, forge_head_ref = github_head_ref, forge_base_ref = github_base_ref",
      "SELECT 1"
    )
  end
end
