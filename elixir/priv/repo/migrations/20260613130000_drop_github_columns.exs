defmodule SymphonyElixir.Repo.Migrations.DropGithubColumns do
  use Ecto.Migration

  def up do
    # Create the new unique index on forge_* columns for pull_request_links
    create(
      unique_index(:pull_request_links, [:project_id, :forge_owner, :forge_repo, :forge_pr_number])
    )

    # Drop the old github_* unique index
    drop(
      index(:pull_request_links, [:project_id, :github_owner, :github_repo, :github_pr_number],
        name: :pull_request_links_project_id_github_owner_github_repo_github_pr_number_index
      )
    )

    # Drop github_* columns from projects
    alter table(:projects) do
      remove(:github_owner)
      remove(:github_repo)
      remove(:github_base_branch)
    end

    # Drop github_* columns from work_runs
    alter table(:work_runs) do
      remove(:github_owner)
      remove(:github_repo)
      remove(:github_pr_number)
      remove(:github_head_sha)
      remove(:github_head_ref)
      remove(:github_base_ref)
    end

    # Drop github_* columns from pull_request_links
    alter table(:pull_request_links) do
      remove(:github_owner)
      remove(:github_repo)
      remove(:github_pr_number)
      remove(:github_head_sha)
      remove(:github_head_ref)
      remove(:github_base_ref)
    end
  end

  def down do
    # Re-add github_* columns to projects
    alter table(:projects) do
      add(:github_owner, :string)
      add(:github_repo, :string)
      add(:github_base_branch, :string)
    end

    # Re-add github_* columns to work_runs
    alter table(:work_runs) do
      add(:github_owner, :string)
      add(:github_repo, :string)
      add(:github_pr_number, :integer)
      add(:github_head_sha, :string)
      add(:github_head_ref, :string)
      add(:github_base_ref, :string)
    end

    # Re-add github_* columns to pull_request_links
    alter table(:pull_request_links) do
      add(:github_owner, :string)
      add(:github_repo, :string)
      add(:github_pr_number, :integer)
      add(:github_head_sha, :string)
      add(:github_head_ref, :string)
      add(:github_base_ref, :string)
    end

    # Backfill from forge_* columns
    execute(
      "UPDATE projects SET github_owner = forge_owner, github_repo = forge_repo, github_base_branch = forge_base_branch",
      "SELECT 1"
    )

    execute(
      "UPDATE work_runs SET github_owner = forge_owner, github_repo = forge_repo, github_pr_number = forge_pr_number, github_head_sha = forge_head_sha, github_head_ref = forge_head_ref, github_base_ref = forge_base_ref",
      "SELECT 1"
    )

    execute(
      "UPDATE pull_request_links SET github_owner = forge_owner, github_repo = forge_repo, github_pr_number = forge_pr_number, github_head_sha = forge_head_sha, github_head_ref = forge_head_ref, github_base_ref = forge_base_ref",
      "SELECT 1"
    )

    # Re-create the old github_* unique index
    create(
      unique_index(:pull_request_links, [:project_id, :github_owner, :github_repo, :github_pr_number])
    )

    # Drop the new forge_* unique index
    drop(
      index(:pull_request_links, [:project_id, :forge_owner, :forge_repo, :forge_pr_number],
        name: :pull_request_links_project_id_forge_owner_forge_repo_forge_pr_n
      )
    )
  end
end
