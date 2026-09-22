defmodule SymphonyElixir.Repo.Migrations.CreateIntake do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pgcrypto", "SELECT 1")

    create table(:integration_connections, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:kind, :text, null: false)
      add(:name, :text, null: false)
      add(:settings, :map, null: false, default: %{})
      add(:secret, :binary)
      add(:secret_version, :integer, null: false, default: 1)
      add(:enabled, :boolean, null: false, default: false)
      add(:last_checked_at, :utc_datetime_usec)
      add(:health, :text, null: false, default: "unchecked")
      add(:error_code, :text)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:integration_connections, ["(lower(settings->>'site_url'))"],
        name: :integration_connections_jira_site_url_index,
        where: "kind = 'jira_cloud'"
      )
    )

    create(constraint(:integration_connections, :integration_connections_kind_check, check: "kind IN ('jira_cloud', 'smtp', 'smsapi')"))

    create(constraint(:integration_connections, :integration_connections_health_check, check: "health IN ('unchecked', 'ok', 'error')"))

    create(constraint(:integration_connections, :integration_connections_versions_check, check: "secret_version >= 1 AND lock_version >= 1"))

    create table(:automation_rules, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:project_id, references(:projects, type: :uuid, on_delete: :restrict), null: false)

      add(:jira_connection_id, references(:integration_connections, type: :uuid, on_delete: :restrict), null: false)

      add(:name, :text, null: false)
      add(:source_type, :text, null: false)
      add(:source_id, :text, null: false)
      add(:priority_ids, {:array, :text}, null: false, default: [])
      add(:interval_seconds, :integer, null: false, default: 300)
      add(:initial_policy, :text, null: false, default: "new_matches_only")
      add(:linear_team_id, :text, null: false)
      add(:linear_project_id, :text, null: false)
      add(:linear_todo_state_id, :text, null: false)
      add(:linear_hold_label_id, :text, null: false)
      add(:email_connection_id, references(:integration_connections, type: :uuid, on_delete: :restrict))
      add(:sms_connection_id, references(:integration_connections, type: :uuid, on_delete: :restrict))
      add(:email_recipients, {:array, :text}, null: false, default: [])
      add(:sms_recipients, {:array, :text}, null: false, default: [])
      add(:enabled, :boolean, null: false, default: false)
      add(:config_version, :integer, null: false, default: 1)
      add(:activation_status, :text, null: false, default: "idle")
      add(:activated_at, :utc_datetime_usec)
      add(:baseline_complete_at, :utc_datetime_usec)
      add(:last_started_at, :utc_datetime_usec)
      add(:last_success_at, :utc_datetime_usec)
      add(:next_poll_at, :utc_datetime_usec)
      add(:last_error_code, :text)
      add(:lease_token, :text)
      add(:lease_until, :utc_datetime_usec)
      add(:baseline_generation, :uuid)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:automation_rules, [:enabled, :next_poll_at]))

    create(
      unique_index(:automation_rules, [:jira_connection_id, :source_type, :source_id],
        name: :automation_rules_active_source_index,
        where: "enabled = TRUE OR activation_status = 'activating'"
      )
    )

    create(constraint(:automation_rules, :automation_rules_source_type_check, check: "source_type IN ('board', 'filter')"))

    create(constraint(:automation_rules, :automation_rules_initial_policy_check, check: "initial_policy IN ('new_matches_only', 'include_existing')"))

    create(constraint(:automation_rules, :automation_rules_activation_status_check, check: "activation_status IN ('idle', 'activating', 'error')"))

    create(
      constraint(:automation_rules, :automation_rules_values_check,
        check: "interval_seconds BETWEEN 60 AND 86400 AND config_version >= 1 AND lock_version >= 1 AND cardinality(priority_ids) >= 1 AND source_id <> ''"
      )
    )

    create(
      constraint(:automation_rules, :automation_rules_recipients_check,
        check: "(email_connection_id IS NULL AND cardinality(email_recipients) = 0) OR (email_connection_id IS NOT NULL AND cardinality(email_recipients) > 0)"
      )
    )

    create(
      constraint(:automation_rules, :automation_rules_sms_recipients_check,
        check: "(sms_connection_id IS NULL AND cardinality(sms_recipients) = 0) OR (sms_connection_id IS NOT NULL AND cardinality(sms_recipients) > 0)"
      )
    )

    create table(:automation_scans, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:rule_id, references(:automation_rules, type: :uuid, on_delete: :restrict), null: false)
      add(:rule_config_version, :integer, null: false)
      add(:mode, :text, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:generation, :uuid, null: false, default: fragment("gen_random_uuid()"))
      add(:started_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)
      add(:match_count, :integer, null: false, default: 0)
      add(:accepted_count, :integer, null: false, default: 0)
      add(:error_code, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:automation_scans, [:rule_id, :status]))
    create(unique_index(:automation_scans, [:rule_id, :generation]))

    create(constraint(:automation_scans, :automation_scans_mode_check, check: "mode IN ('baseline', 'poll', 'preview')"))

    create(constraint(:automation_scans, :automation_scans_status_check, check: "status IN ('pending', 'running', 'succeeded', 'failed', 'cancelled')"))

    create(constraint(:automation_scans, :automation_scans_values_check, check: "rule_config_version >= 1 AND match_count >= 0 AND accepted_count >= 0"))

    create table(:jira_observations, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:jira_connection_id, references(:integration_connections, type: :uuid, on_delete: :restrict), null: false)

      add(:rule_id, references(:automation_rules, type: :uuid, on_delete: :restrict), null: false)
      add(:jira_issue_id, :text, null: false)
      add(:first_seen_at, :utc_datetime_usec, null: false)
      add(:last_seen_at, :utc_datetime_usec, null: false)
      add(:last_priority_id, :text)
      add(:baseline_excluded, :boolean, null: false, default: false)
      add(:generation, :uuid)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:jira_observations, [:rule_id, :jira_issue_id]))
    create(index(:jira_observations, [:jira_connection_id, :last_seen_at]))

    create table(:intake_cases, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:project_id, references(:projects, type: :uuid, on_delete: :restrict), null: false)
      add(:rule_id, references(:automation_rules, type: :uuid, on_delete: :restrict), null: false)

      add(:jira_connection_id, references(:integration_connections, type: :uuid, on_delete: :restrict), null: false)

      add(:jira_issue_id, :text, null: false)
      add(:jira_key, :text, null: false)
      add(:jira_url, :text, null: false)
      add(:title, :text, null: false)
      add(:description_text, :text, null: false)
      add(:priority_id, :text, null: false)
      add(:priority_name, :text, null: false)
      add(:jira_updated_at, :utc_datetime_usec, null: false)
      add(:detected_at, :utc_datetime_usec, null: false)
      add(:rule_snapshot, :map, null: false)
      add(:linear_issue_id, :uuid, null: false, default: fragment("gen_random_uuid()"))
      add(:linear_identifier, :text)
      add(:linear_url, :text)
      add(:linear_state_name, :text)
      add(:linear_confirmed_at, :utc_datetime_usec)
      add(:analysis_version, :integer, null: false, default: 1)
      add(:analysis_status, :text, null: false, default: "queued")
      add(:acknowledged_at, :utc_datetime_usec)
      add(:repair_approved_at, :utc_datetime_usec)
      add(:repair_approved_version, :integer)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:intake_cases, [:jira_connection_id, :jira_issue_id]))
    create(unique_index(:intake_cases, [:linear_issue_id]))
    create(index(:intake_cases, [:project_id, :detected_at, :id]))

    create(constraint(:intake_cases, :intake_cases_analysis_status_check, check: "analysis_status IN ('queued', 'running', 'ready', 'needs_input', 'failed')"))

    create(constraint(:intake_cases, :intake_cases_versions_check, check: "analysis_version >= 1 AND lock_version >= 1 AND (repair_approved_version IS NULL OR repair_approved_version >= 1)"))

    create table(:intake_analyses, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:case_id, references(:intake_cases, type: :uuid, on_delete: :restrict), null: false)
      add(:version, :integer, null: false)
      add(:status, :text, null: false, default: "queued")
      add(:input_snapshot, :map, null: false)
      add(:result, :map)
      add(:model, :text, null: false)
      add(:effort, :text, null: false)
      add(:started_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)
      add(:token_usage, :map)
      add(:error_code, :text)
      add(:work_run_id, references(:work_runs, type: :uuid, on_delete: :restrict))
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:intake_analyses, [:case_id, :version]))
    create(index(:intake_analyses, [:status, :inserted_at]))

    create(constraint(:intake_analyses, :intake_analyses_status_check, check: "status IN ('queued', 'running', 'succeeded', 'failed', 'needs_input')"))

    create(constraint(:intake_analyses, :intake_analyses_version_check, check: "version >= 1"))

    create table(:integration_deliveries, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:case_id, references(:intake_cases, type: :uuid, on_delete: :restrict))
      add(:connection_id, references(:integration_connections, type: :uuid, on_delete: :restrict))
      add(:operation, :text, null: false)
      add(:dedupe_key, :text, null: false)
      add(:payload, :map, null: false, default: %{})
      add(:status, :text, null: false, default: "pending")
      add(:attempts, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime_usec, null: false)
      add(:lease_token, :text)
      add(:lease_until, :utc_datetime_usec)
      add(:provider_id, :text)
      add(:first_attempt_at, :utc_datetime_usec)
      add(:sent_at, :utc_datetime_usec)
      add(:last_error_code, :text)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:integration_deliveries, [:dedupe_key]))
    create(index(:integration_deliveries, [:status, :next_attempt_at]))

    create(constraint(:integration_deliveries, :integration_deliveries_operation_check, check: "operation IN ('linear_create', 'email', 'sms', 'analysis', 'jira_comment')"))

    create(constraint(:integration_deliveries, :integration_deliveries_status_check, check: "status IN ('pending', 'running', 'retry_wait', 'succeeded', 'failed', 'unknown', 'paused')"))

    create(constraint(:integration_deliveries, :integration_deliveries_values_check, check: "attempts >= 0 AND lock_version >= 1"))

    create table(:intake_events, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:case_id, references(:intake_cases, type: :uuid, on_delete: :restrict))
      add(:rule_id, references(:automation_rules, type: :uuid, on_delete: :restrict))
      add(:type, :text, null: false)
      add(:payload, :map, null: false, default: %{})
      add(:actor, :text, null: false, default: "system")
      add(:occurred_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:intake_events, [:case_id, :occurred_at, :id]))
    create(index(:intake_events, [:rule_id, :occurred_at]))

    create(constraint(:intake_events, :intake_events_actor_check, check: "actor IN ('system', 'operator')"))
  end

  def down do
    drop(table(:intake_events))
    drop(table(:integration_deliveries))
    drop(table(:intake_analyses))
    drop(table(:intake_cases))
    drop(table(:jira_observations))
    drop(table(:automation_scans))
    drop(table(:automation_rules))
    drop(table(:integration_connections))
  end
end
