defmodule SymphonyElixir.IntakeConfigTest do
  use SymphonyElixir.TestSupport

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Intake
  alias SymphonyElixir.Intake.Connections
  alias SymphonyElixir.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "intake and analysis runtime flags are disabled by default" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.intake.enabled == false
    assert settings.intake.effects_enabled == false
    assert settings.analysis.enabled == false
    assert settings.intake.public_url == nil
    assert settings.intake.smtp_allowed_hosts == []

    assert Intake.enabled?(settings) == false
    assert Intake.effects_enabled?(settings) == false
    assert Intake.analysis_enabled?(settings) == false
    assert Intake.enabled?() == false
    assert Intake.effects_enabled?() == false
    assert Intake.analysis_enabled?() == false
    assert Config.settings!().intake.enabled == false
    assert Config.settings!().intake.effects_enabled == false
    assert Config.settings!().analysis.enabled == false
  end

  test "runtime intake and analysis settings are read through Config.Schema" do
    assert {:ok, settings} =
             Schema.parse(%{
               "intake" => %{
                 "enabled" => true,
                 "effects_enabled" => true,
                 "public_url" => "https://harmony.example.test",
                 "smtp_allowed_hosts" => ["smtp.example.test"]
               },
               "analysis" => %{"enabled" => true, "model" => "analysis-model", "effort" => "high"}
             })

    assert settings.intake.enabled
    assert settings.intake.effects_enabled
    assert settings.intake.public_url == "https://harmony.example.test"
    assert settings.intake.smtp_allowed_hosts == ["smtp.example.test"]
    assert settings.analysis.enabled
    assert settings.analysis.model == "analysis-model"
    assert settings.analysis.effort == "high"
    assert settings.analysis.max_concurrent == 1
    assert settings.analysis.timeout_ms == 600_000
    assert settings.analysis.max_turns == 1
    assert settings.analysis.max_result_bytes == 32_768

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"analysis" => %{"enabled" => true}})

    assert message =~ "model"
  end

  test "enabling intake requires an HTTPS public URL" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"intake" => %{"enabled" => true, "public_url" => "http://harmony.test"}})

    assert message =~ "public_url"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"intake" => %{"enabled" => true}})

    assert message =~ "public_url"
  end

  test "connection presenter exposes only whether a secret is set" do
    assert {:ok, connection} =
             Connections.create(%{
               kind: "smtp",
               name: "SMTP",
               settings: %{host: "smtp.example.test"},
               secret: "smtp-password"
             })

    presented = Connections.present(connection)
    serialized = Jason.encode!(presented)

    assert presented.secret_status == "set"
    refute Map.has_key?(presented, :secret_value)
    refute Map.has_key?(presented, :secret)
    refute serialized =~ "smtp-password"
  end

  test "blank secret keeps the existing value and clear_secret removes it" do
    assert {:ok, connection} =
             Connections.create(%{
               kind: "smtp",
               name: "SMTP",
               settings: %{host: "smtp.example.test"},
               secret: "smtp-password"
             })

    assert {:ok, unchanged} = Connections.update(connection, %{secret: ""})
    assert unchanged.secret == "smtp-password"
    assert Connections.present(unchanged).secret_status == "set"

    assert {:ok, cleared} = Connections.update(unchanged, %{clear_secret: true})
    assert is_nil(cleared.secret)
    assert Connections.present(cleared).secret_status == "unset"
  end

  test "string-key connection input ignores unknown fields and redacts nested secrets" do
    assert {:ok, connection} =
             Connections.create(%{
               "kind" => "smtp",
               "name" => "SMTP with nested credentials",
               "settings" => %{
                 host: "smtp.example.test",
                 accounts: [%{token: "nested-token", password: "nested-password", label: "primary"}]
               },
               "secret" => "smtp-password",
               "secret_version" => 2,
               "enabled" => true,
               "last_checked_at" => nil,
               "health" => "ok",
               "error_code" => "last-check-warning",
               "lock_version" => 2,
               "ignored_field" => "ignored"
             })

    presented = Connections.present(connection)
    serialized = Jason.encode!(presented)

    assert connection.enabled
    assert connection.secret_version == 2
    assert connection.error_code == "last-check-warning"
    assert Connections.secret_set?(connection)
    assert presented.settings == %{"host" => "smtp.example.test", "accounts" => [%{"label" => "primary"}]}
    assert presented.secret_status == "set"
    refute serialized =~ "smtp-password"
    refute serialized =~ "nested-token"
    refute serialized =~ "nested-password"
  end

  test "SMS connections require a sender and partial updates preserve settings" do
    assert {:error, changeset} = Connections.create(%{kind: "smsapi", name: "SMS", settings: %{sender: " "}})
    assert Keyword.has_key?(changeset.errors, :settings)

    assert {:ok, sms} = Connections.create(%{kind: "smsapi", name: "SMS", settings: %{sender: "Harmony"}})
    assert {:ok, renamed} = Connections.update(sms, %{name: "Primary SMS"})
    assert renamed.name == "Primary SMS"
    assert renamed.settings == %{"sender" => "Harmony"}
    assert Connections.secret_set?(renamed) == false
  end

  test "connection kind is validated and a Jira site URL cannot change after use" do
    assert {:error, changeset} =
             Connections.create(%{kind: "other", name: "Unknown", settings: %{}})

    assert {:kind, {_message, _metadata}} = List.keyfind(changeset.errors, :kind, 0)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, connection} =
             Connections.create(%{
               kind: "jira_cloud",
               name: "Jira",
               settings: %{site_url: "https://jira.example.test"},
               secret: "jira-token",
               last_checked_at: now
             })

    assert {:error, changeset} =
             Connections.update(connection, %{settings: %{site_url: "https://other.example.test"}})

    assert {:site_url, {_message, _metadata}} = List.keyfind(changeset.errors, :site_url, 0)

    assert get_in(Repo.get!(SymphonyElixir.Storage.IntegrationConnection, connection.id).settings, ["site_url"]) ==
             "https://jira.example.test"
  end
end
