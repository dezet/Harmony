defmodule SymphonyElixir.Repo.Migrations.CreateHarmonyStorage do
  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS pgcrypto", "SELECT 1")

    create table(:projects, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:slug, :text, null: false)
      add(:linear_project_slug, :text)
      add(:linear_team_key, :text)
      add(:linear_human_review_state, :text)
      add(:github_owner, :text, null: false)
      add(:github_repo, :text, null: false)
      add(:github_base_branch, :text, null: false)
      add(:config_version, :integer, null: false, default: 1)
      add(:config, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:projects, [:slug]))

    create table(:work_runs, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:project_id, references(:projects, type: :uuid, on_delete: :delete_all), null: false)
      add(:type, :text, null: false)
      add(:status, :text, null: false)
      add(:dedupe_key, :text)
      add(:github_owner, :text)
      add(:github_repo, :text)
      add(:github_pr_number, :integer)
      add(:github_head_sha, :text)
      add(:github_head_ref, :text)
      add(:github_base_ref, :text)
      add(:linear_issue_id, :text)
      add(:linear_identifier, :text)
      add(:linear_url, :text)
      add(:agent_backend, :text, null: false, default: "codex")
      add(:payload, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:work_runs, [:project_id, :status]))
    create(unique_index(:work_runs, [:project_id, :dedupe_key], where: "dedupe_key IS NOT NULL"))

    create table(:work_events, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:project_id, references(:projects, type: :uuid, on_delete: :delete_all), null: false)
      add(:work_run_id, references(:work_runs, type: :uuid, on_delete: :nilify_all))
      add(:type, :text, null: false)
      add(:payload, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:work_events, [:project_id, :inserted_at]))
    create(index(:work_events, [:work_run_id, :inserted_at]))

    create table(:dedupe_keys, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:project_id, references(:projects, type: :uuid, on_delete: :delete_all), null: false)
      add(:key, :text, null: false)
      add(:scope, :text, null: false)
      add(:status, :text, null: false, default: "processed")
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:dedupe_keys, [:project_id, :key]))

    create table(:pull_request_links, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:project_id, references(:projects, type: :uuid, on_delete: :delete_all), null: false)
      add(:github_owner, :text, null: false)
      add(:github_repo, :text, null: false)
      add(:github_pr_number, :integer, null: false)
      add(:github_head_sha, :text)
      add(:linear_issue_id, :text)
      add(:linear_identifier, :text)
      add(:linear_url, :text)
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:pull_request_links, [:project_id, :github_owner, :github_repo, :github_pr_number]))

    create table(:blockers, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:project_id, references(:projects, type: :uuid, on_delete: :delete_all), null: false)
      add(:work_run_id, references(:work_runs, type: :uuid, on_delete: :nilify_all))
      add(:target_type, :text, null: false)
      add(:target_id, :text, null: false)
      add(:reason, :text, null: false)
      add(:status, :text, null: false, default: "open")
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:blockers, [:project_id, :status]))

    create table(:artifacts, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:project_id, references(:projects, type: :uuid, on_delete: :delete_all), null: false)
      add(:work_run_id, references(:work_runs, type: :uuid, on_delete: :nilify_all))
      add(:kind, :text, null: false)
      add(:path, :text, null: false)
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:artifacts, [:project_id, :work_run_id]))
  end
end
