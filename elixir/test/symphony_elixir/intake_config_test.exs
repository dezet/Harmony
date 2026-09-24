defmodule SymphonyElixir.IntakeConfigTest do
  use SymphonyElixir.TestSupport

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Intake
  alias SymphonyElixir.Intake.Connections
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.IntegrationConnection

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

  test "an update of settings or secret resets the stored check; a rename or enabled toggle keeps it" do
    assert {:ok, connection} =
             Connections.create(%{kind: "smtp", name: "SMTP", settings: %{host: "smtp.example.test"}, secret: "smtp-password"})

    checked_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    checked = Connections.record_check(connection, {:error, "smtp_auth_failed"}, checked_at)

    assert {:ok, renamed} = Connections.update(checked, %{name: "Renamed"})
    assert {renamed.health, renamed.error_code} == {"error", "smtp_auth_failed"}

    for attrs <- [%{enabled: true}, %{enabled: false}] do
      assert {:ok, toggled} = Connections.update(Repo.get!(IntegrationConnection, connection.id), attrs)
      assert {toggled.health, toggled.error_code} == {"error", "smtp_auth_failed"}, inspect(attrs)
    end

    for attrs <- [%{settings: %{host: "smtp2.example.test"}}, %{secret: "rotated"}, %{clear_secret: true}] do
      failed = Connections.record_check(Repo.get!(IntegrationConnection, connection.id), {:error, "smtp_auth_failed"}, checked_at)
      assert {:ok, updated} = Connections.update(failed, attrs)
      assert {updated.health, updated.error_code, updated.last_checked_at} == {"unchecked", nil, checked_at}, inspect(attrs)
    end
  end

  test "string-key clear_secret clears a credential while an unused Jira URL remains editable" do
    assert {:ok, smtp} =
             Connections.create(%{
               kind: "smtp",
               name: "SMTP with string clear flag",
               settings: %{host: "smtp.example.test"},
               secret: "smtp-password"
             })

    assert {:ok, cleared} = Connections.update(smtp, %{"clear_secret" => true})
    assert is_nil(cleared.secret)
    assert Connections.present(cleared).secret_status == "unset"

    site_url = "https://editable-#{System.unique_integer([:positive])}.atlassian.net"

    assert {:ok, jira} =
             Connections.create(%{
               kind: "jira_cloud",
               name: "Unused Jira",
               settings: %{site_url: site_url}
             })

    replacement_url = "https://replacement-#{System.unique_integer([:positive])}.atlassian.net"
    assert {:ok, updated} = Connections.update(jira, %{settings: %{site_url: replacement_url}})
    assert Connections.site_url(updated) == replacement_url
  end

  test "nil secrets remain unset and malformed connection settings are rejected by provider" do
    assert {:ok, smtp} =
             Connections.create(%{
               kind: "smtp",
               name: "SMTP without a secret",
               settings: %{host: "smtp.example.test"},
               secret: nil
             })

    refute Connections.secret_set?(smtp)

    assert {:error, jira_changeset} =
             Connections.create(%{kind: "jira_cloud", name: "Jira without settings", settings: nil})

    assert Keyword.has_key?(jira_changeset.errors, :settings)

    assert {:error, smtp_changeset} =
             Connections.create(%{kind: "smtp", name: "SMTP without settings", settings: nil})

    assert Keyword.has_key?(smtp_changeset.errors, :settings)

    assert {:error, sms_changeset} =
             Connections.create(%{kind: "smsapi", name: "SMS without settings", settings: nil})

    assert Keyword.has_key?(sms_changeset.errors, :settings)
  end

  test "string-key connection input ignores unknown fields and normalizes settings" do
    assert {:ok, connection} =
             Connections.create(%{
               "kind" => "smtp",
               "name" => "SMTP with nested credentials",
               "settings" => %{
                 host: "smtp.example.test",
                 accounts: [%{label: "primary"}]
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
  end

  test "Jira credential-like settings are rejected before JSONB persistence" do
    site_url = "https://jira-credentials-#{System.unique_integer([:positive])}.atlassian.net"

    result =
      Connections.create(%{
        kind: "jira_cloud",
        name: "Jira with misplaced credentials",
        settings: %{
          site_url: site_url,
          auth_mode: "classic",
          account_email: "ops@example.test",
          api_token: "canary-api-token",
          access_token: "canary-access-token",
          credentials: [%{refreshToken: "canary-refresh-token", client_secret: "canary-client-secret"}]
        }
      })

    assert {:error, changeset} = result
    assert Keyword.has_key?(changeset.errors, :settings)
    refute inspect(changeset) =~ "canary-"

    %{rows: [[connection_count]]} =
      Repo.query!("SELECT count(*) FROM integration_connections WHERE settings->>'site_url' = $1", [site_url])

    assert connection_count == 0

    assert {:ok, safe_connection} =
             Connections.create(%{
               kind: "jira_cloud",
               name: "Jira with encrypted credential field",
               settings: %{site_url: site_url, auth_mode: "classic", account_email: "ops@example.test"},
               secret: "encrypted-field-canary"
             })

    assert {:error, update_changeset} =
             Connections.update(safe_connection, %{settings: %{api_token: "canary-update-token"}})

    assert Keyword.has_key?(update_changeset.errors, :settings)
    refute inspect(update_changeset) =~ "canary-update-token"

    stored_safe_connection = Repo.get!(IntegrationConnection, safe_connection.id)
    assert stored_safe_connection.settings["site_url"] == site_url
    refute Map.has_key?(stored_safe_connection.settings, "api_token")
  end

  test "presenter masks legacy token and credential variants and updates remove them from storage" do
    site_url = "https://jira-legacy-secrets-#{System.unique_integer([:positive])}.atlassian.net"

    secret_values = [
      "legacy-api-token",
      "legacy-access-token",
      "legacy-client-secret",
      "legacy-authorization",
      "legacy-refresh-token"
    ]

    assert {:ok, legacy_connection} =
             IntegrationConnection.changeset(%IntegrationConnection{}, %{
               kind: "jira_cloud",
               name: "Legacy Jira",
               settings: %{
                 site_url: site_url,
                 api_token: Enum.at(secret_values, 0),
                 access_token: Enum.at(secret_values, 1),
                 client_secret: Enum.at(secret_values, 2),
                 headers: [
                   %{authorization: Enum.at(secret_values, 3), refreshToken: Enum.at(secret_values, 4)}
                 ]
               }
             })
             |> Repo.insert()

    presented = legacy_connection |> Connections.present() |> Jason.encode!()
    Enum.each(secret_values, fn secret -> refute presented =~ secret end)

    assert {:ok, updated} = Connections.update(legacy_connection, %{name: "Repaired Jira"})
    assert updated.name == "Repaired Jira"

    stored = Repo.get!(IntegrationConnection, legacy_connection.id)
    refute Map.has_key?(stored.settings, "api_token")
    refute Map.has_key?(stored.settings, "access_token")
    refute Map.has_key?(stored.settings, "client_secret")
    refute Map.has_key?(hd(stored.settings["headers"]), "authorization")
    refute Map.has_key?(hd(stored.settings["headers"]), "refreshToken")

    stored_projection = Jason.encode!(Connections.present(stored))
    Enum.each(secret_values, fn secret -> refute stored_projection =~ secret end)
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
