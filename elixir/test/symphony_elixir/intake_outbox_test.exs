defmodule SymphonyElixir.IntakeOutboxTest do
  use SymphonyElixir.TestSupport

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Intake.Outbox
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{AutomationRule, IntegrationConnection, IntegrationDelivery, IntakeAnalysis, IntakeCase, IntakeEvent, Project}

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "two independent PostgreSQL claimers get one lease for one delivery" do
    ids = raw_delivery_fixture!("lease-race-#{System.unique_integer([:positive])}")
    on_exit(fn -> cleanup_raw_delivery_fixture(ids) end)

    parent = self()
    now = now()

    first =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo)
        result = Outbox.claim(claim_opts(now, operation: "email", connection_id: ids.connection))
        send(parent, {:first_claimed, result})
        receive do: (:release -> :ok)
        result
      end)

    assert_receive {:first_claimed, {:ok, first_delivery}}
    assert is_binary(first_delivery.lease_token)

    second =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo)
        Outbox.claim(claim_opts(now, operation: "email", connection_id: ids.connection))
      end)

    assert Task.await(second, 5_000) == :empty
    send(first.pid, :release)
    assert {:ok, _delivery} = Task.await(first, 5_000)
  end

  test "a locked candidate is skipped instead of blocking another PostgreSQL connection" do
    ids = raw_delivery_fixture!("skip-locked-#{System.unique_integer([:positive])}")
    on_exit(fn -> cleanup_raw_delivery_fixture(ids) end)
    database = start_database_connection!()
    now = now()

    try do
      Postgrex.query!(database, "BEGIN", [])

      Postgrex.query!(database, "SELECT id FROM integration_deliveries WHERE id = $1 FOR UPDATE", [
        uuid_binary(ids.delivery)
      ])

      claimant =
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo)
          Outbox.claim(claim_opts(now, operation: "email", connection_id: ids.connection))
        end)

      assert Task.yield(claimant, 1_000) == {:ok, :empty}

      Postgrex.query!(database, "COMMIT", [])

      assert {:ok, delivery} =
               Outbox.claim(claim_opts(now, operation: "email", connection_id: ids.connection))

      assert delivery.id == ids.delivery
    after
      Postgrex.query!(database, "ROLLBACK", [])
      GenServer.stop(database)
    end
  end

  test "claim increments attempts, rotates leases, heartbeats, and rejects stale CAS writes" do
    delivery = delivery!("email")
    now = now()

    assert {:ok, claimed} = Outbox.claim(claim_opts(now, operation: "email", clock: fn -> now end))
    assert claimed.id == delivery.id
    assert claimed.status == "running"
    assert claimed.attempts == 1
    assert is_binary(claimed.lease_token)
    assert DateTime.diff(claimed.lease_until, now, :second) == 120

    assert {:ok, heartbeated} =
             Outbox.heartbeat(delivery.id, claimed.lease_token,
               now: DateTime.add(now, 100, :second),
               lease_seconds: 120
             )

    assert DateTime.diff(heartbeated.lease_until, now, :second) == 220
    assert {:error, :stale_lease} = Outbox.complete(delivery.id, "old-token", %{provider_id: "ack-old"})
    assert {:ok, completed} = Outbox.complete(delivery.id, claimed.lease_token, %{provider_id: "ack-1"})
    assert completed.status == "succeeded"
    assert completed.provider_id == "ack-1"
  end

  test "retry scheduling uses all four intervals, positive jitter, and extends for Retry-After" do
    now = now() |> DateTime.truncate(:second)

    assert Enum.map(1..4, fn attempt ->
             Outbox.next_attempt_at(now, attempt, nil, jitter: fn -> 0.5 end)
             |> DateTime.diff(now, :second)
           end) == [32, 126, 630, 1_890]

    assert Outbox.next_attempt_at(now, 1, "3600", jitter: fn -> 0.5 end)
           |> DateTime.diff(now, :second) == 3_600

    retry_date = DateTime.add(now, 3_600, :second) |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

    assert Outbox.next_attempt_at(now, 2, retry_date, jitter: fn -> 0.5 end)
           |> DateTime.diff(now, :second) == 3_600

    assert Outbox.next_attempt_at(now, 2, "1", jitter: fn -> 0.5 end)
           |> DateTime.diff(now, :second) == 126
  end

  test "Retry-After accepts all HTTP date formats and ignores invalid dates" do
    now = ~U[2026-09-22 00:00:00Z]
    expected_retry_at = DateTime.add(now, 3_600, :second)

    retry_dates = [
      "Tue, 22 Sep 2026 01:00:00 GMT",
      "Tuesday, 22-Sep-26 01:00:00 GMT",
      "Tue Sep 22 01:00:00 2026"
    ]

    for retry_date <- retry_dates do
      assert Outbox.next_attempt_at(now, 1, retry_date, jitter: fn -> 0.5 end) == expected_retry_at
    end

    assert Outbox.next_attempt_at(now, 1, "not a valid HTTP date", jitter: fn -> 0.5 end) ==
             DateTime.add(now, 32, :second)
  end

  test "expired write-capable leases become unknown while analysis uses its recovery path" do
    email = delivery!("email")
    {analysis_case, analysis} = analysis_fixture!()
    started_at = now()

    assert {:ok, email_claim} = Outbox.claim(claim_opts(started_at, operation: "email"))
    assert email_claim.id == email.id

    assert {:ok, analysis_claim} = Outbox.claim(claim_opts(started_at, operation: "analysis"))
    assert analysis_claim.case_id == analysis_case.id
    assert Repo.get!(IntakeAnalysis, analysis.id).started_at == started_at

    Enum.each(1..19, fn tick ->
      assert {:ok, _heartbeat} =
               Outbox.heartbeat(analysis_claim.id, analysis_claim.lease_token, now: DateTime.add(started_at, tick * 30, :second))
    end)

    expired_at = DateTime.add(started_at, 601, :second)

    assert {:error, :stale_lease} =
             Outbox.complete(analysis_claim.id, analysis_claim.lease_token, %{}, now: expired_at)

    assert %{unknown: 1, analyses: 1} = Outbox.recover_expired(expired_at)

    assert Repo.get!(IntegrationDelivery, email.id).status == "unknown"
    assert Repo.get!(IntegrationDelivery, analysis_claim.id).status == "pending"
    assert Repo.get!(IntakeAnalysis, analysis.id).status == "queued"
    assert Repo.get!(IntakeCase, analysis_case.id).analysis_status == "queued"
  end

  test "disabled connections pause deliveries and re-enabling resumes their saved state" do
    connection = connection!("smtp", enabled: false)

    delivery =
      delivery!("email",
        connection_id: connection.id,
        status: "retry_wait",
        attempts: 2,
        next_attempt_at: DateTime.add(now(), -60, :second),
        last_error_code: "temporary"
      )

    now = now() |> DateTime.truncate(:second)

    assert :empty = Outbox.claim(claim_opts(now, operation: "email"))
    paused = Repo.get!(IntegrationDelivery, delivery.id)
    assert paused.status == "paused"
    assert paused.payload["resume_status"] == "retry_wait"
    assert paused.attempts == 2
    assert paused.last_error_code == "temporary"

    connection
    |> IntegrationConnection.changeset(%{enabled: true})
    |> Repo.update!()

    assert {:ok, resumed} = Outbox.claim(claim_opts(now, operation: "email"))
    assert resumed.id == delivery.id
    assert resumed.status == "running"
    assert resumed.attempts == 3
    assert resumed.last_error_code == "temporary"

    event_types =
      Repo.all(from(e in IntakeEvent, where: e.payload["delivery_id"] == ^delivery.id, select: e.type))

    assert "delivery_paused" in event_types
    assert "delivery_resumed" in event_types
  end

  test "rate limits are isolated per connection and leave a retry time and attempt history" do
    first_connection = connection!("smtp", enabled: true)
    second_connection = connection!("smtp", enabled: true)
    first_attempt = delivery!("email", connection_id: first_connection.id)
    limited_delivery = delivery!("email", connection_id: first_connection.id)
    other_connection_delivery = delivery!("email", connection_id: second_connection.id)
    now = now()

    assert {:ok, claimed} =
             Outbox.claim(claim_opts(now, operation: "email", connection_id: first_connection.id, rate_limits: %{email: 1}))

    assert claimed.id == first_attempt.id
    assert {:ok, _} = Outbox.complete(first_attempt.id, claimed.lease_token)

    assert :empty =
             Outbox.claim(claim_opts(now, operation: "email", connection_id: first_connection.id, rate_limits: %{email: 1}))

    limited = Repo.get!(IntegrationDelivery, limited_delivery.id)
    assert limited.status == "retry_wait"
    assert limited.last_error_code == "rate_limited"
    assert DateTime.diff(limited.next_attempt_at, now, :second) == 3_600

    assert {:ok, other_claim} =
             Outbox.claim(claim_opts(now, operation: "email", connection_id: second_connection.id, rate_limits: %{email: 1}))

    assert other_claim.id == other_connection_delivery.id
    assert Repo.aggregate(SymphonyElixir.Storage.IntakeEvent, :count, :id) >= 1
  end

  test "email, SMS, and Jira comment deliveries without a connection are never claimed" do
    Enum.each(["email", "sms", "jira_comment"], fn operation ->
      delivery =
        %IntegrationDelivery{}
        |> IntegrationDelivery.changeset(%{
          operation: operation,
          dedupe_key: "missing-connection:#{Ecto.UUID.generate()}",
          payload: %{},
          status: "pending",
          attempts: 0,
          next_attempt_at: DateTime.add(now(), -1, :second)
        })
        |> Repo.insert!()

      assert :empty = Outbox.claim(claim_opts(now(), operation: operation))

      failed = Repo.get!(IntegrationDelivery, delivery.id)
      assert failed.status == "failed"
      assert failed.last_error_code == "connection_required"
    end)
  end

  test "five automatic retries exhaust without erasing history and manual retry grants one more attempt" do
    delivery = delivery!("sms")
    start = now()

    {last_delivery, last_token, final_time} =
      Enum.reduce(1..5, {nil, nil, start}, fn attempt, {_previous, _token, time} ->
        assert {:ok, claimed} = Outbox.claim(claim_opts(time, operation: "sms"))
        assert claimed.id == delivery.id
        assert claimed.attempts == attempt

        if attempt < 5 do
          assert {:ok, retrying} = Outbox.retry(delivery.id, claimed.lease_token, "timeout", nil, now: time, jitter: fn -> 0.0 end)

          {retrying, claimed.lease_token, retrying.next_attempt_at}
        else
          assert {:ok, failed} = Outbox.retry(delivery.id, claimed.lease_token, "timeout", nil, now: time, jitter: fn -> 0.0 end)

          assert failed.status == "failed"
          {failed, claimed.lease_token, time}
        end
      end)

    assert last_delivery.attempts == 5
    assert {:ok, manually_retried} = Outbox.manual_retry(delivery.id, now: final_time)
    assert manually_retried.status == "retry_wait"
    assert manually_retried.attempts == 5
    assert manually_retried.payload["manual_retries"] == 1

    assert {:ok, sixth_attempt} = Outbox.claim(claim_opts(final_time, operation: "sms"))
    assert sixth_attempt.attempts == 6
    assert last_token != sixth_attempt.lease_token
  end

  test "retrying unknown requires duplicate-risk confirmation and external reconciliation" do
    ids = raw_delivery_fixture!("unknown-retry-#{System.unique_integer([:positive])}")
    on_exit(fn -> cleanup_raw_delivery_fixture(ids) end)
    database = start_database_connection!()

    try do
      Postgrex.query!(
        database,
        "UPDATE integration_deliveries SET operation = 'jira_comment', status = 'unknown', attempts = 1 WHERE id = $1",
        [uuid_binary(ids.delivery)]
      )
    after
      GenServer.stop(database)
    end

    parent = self()

    result =
      Sandbox.unboxed_run(Repo, fn ->
        assert {:error, :confirmation_required} = Outbox.manual_retry(ids.delivery)

        assert {:error, :reconciliation_required} =
                 Outbox.manual_retry(ids.delivery, confirm_duplicate_risk: true)

        Outbox.manual_retry(ids.delivery,
          confirm_duplicate_risk: true,
          reconcile: fn _delivery ->
            send(parent, {:reconcile_in_transaction, Repo.in_transaction?()})
            :safe_to_retry
          end
        )
      end)

    assert_receive {:reconcile_in_transaction, false}
    assert {:ok, retrying} = result
    assert retrying.status == "retry_wait"
    assert retrying.attempts == 1
  end

  defp claim_opts(now, overrides) do
    Keyword.merge(
      [
        now: now,
        intake_enabled: true,
        effects_enabled: true,
        analysis_enabled: true,
        jitter: fn -> 0.0 end
      ],
      overrides
    )
  end

  defp delivery!(operation, attrs \\ []) do
    attrs = Map.new(attrs)

    connection_id =
      Map.get(attrs, :connection_id) ||
        case operation do
          "email" -> connection!("smtp").id
          "sms" -> connection!("smsapi").id
          "jira_comment" -> connection!("jira_cloud").id
          _operation -> nil
        end

    defaults = %{
      operation: operation,
      connection_id: connection_id,
      dedupe_key: "outbox:#{Ecto.UUID.generate()}",
      payload: %{},
      status: "pending",
      attempts: 0,
      next_attempt_at: DateTime.add(now(), -1, :second)
    }

    %IntegrationDelivery{}
    |> IntegrationDelivery.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp connection!(kind, attrs \\ []) do
    suffix = System.unique_integer([:positive])

    defaults = %{
      kind: kind,
      name: "#{kind} #{suffix}",
      settings:
        case kind do
          "smtp" -> %{host: "smtp.example.test"}
          "smsapi" -> %{sender: "Harmony"}
          "jira_cloud" -> %{site_url: "https://outbox-#{suffix}.atlassian.net"}
        end,
      enabled: true
    }

    %IntegrationConnection{}
    |> IntegrationConnection.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp analysis_fixture! do
    connection = connection!("jira_cloud")

    project =
      %Project{}
      |> Project.changeset(%{
        slug: "outbox-project-#{System.unique_integer([:positive])}",
        forge_owner: "example",
        forge_repo: "harmony",
        forge_base_branch: "main",
        config: %{},
        config_version: 1,
        ui_color: "purple"
      })
      |> Repo.insert!()

    rule =
      %AutomationRule{}
      |> AutomationRule.changeset(%{
        project_id: project.id,
        jira_connection_id: connection.id,
        name: "Outbox rule",
        source_type: "board",
        source_id: "42",
        priority_ids: ["1"],
        interval_seconds: 300,
        initial_policy: "new_matches_only",
        linear_team_id: "team",
        linear_project_id: "project",
        linear_todo_state_id: "todo",
        linear_hold_label_id: "hold",
        email_recipients: [],
        sms_recipients: [],
        enabled: false,
        config_version: 1,
        activation_status: "idle",
        lock_version: 1
      })
      |> Repo.insert!()

    timestamp = now()

    intake_case =
      %IntakeCase{}
      |> IntakeCase.changeset(%{
        project_id: project.id,
        rule_id: rule.id,
        jira_connection_id: connection.id,
        jira_issue_id: Ecto.UUID.generate(),
        jira_key: "OPS-#{System.unique_integer([:positive])}",
        jira_url: "https://example.atlassian.net/browse/OPS-1",
        title: "Analysis recovery",
        description_text: "Description",
        priority_id: "1",
        priority_name: "Highest",
        jira_updated_at: timestamp,
        detected_at: timestamp,
        rule_snapshot: %{},
        linear_issue_id: Ecto.UUID.generate(),
        analysis_version: 1,
        analysis_status: "running",
        lock_version: 1
      })
      |> Repo.insert!()

    analysis =
      %IntakeAnalysis{}
      |> IntakeAnalysis.changeset(%{
        case_id: intake_case.id,
        version: 1,
        status: "running",
        input_snapshot: %{},
        model: "analysis-model",
        effort: "medium",
        started_at: timestamp
      })
      |> Repo.insert!()

    delivery!("analysis", case_id: intake_case.id, payload: %{version: 1})

    {intake_case, analysis}
  end

  defp raw_delivery_fixture!(slug) do
    ids = %{project: Ecto.UUID.generate(), connection: Ecto.UUID.generate(), delivery: Ecto.UUID.generate()}
    database = start_database_connection!()

    try do
      Postgrex.query!(database, "INSERT INTO projects (id, slug, inserted_at, updated_at) VALUES ($1, $2, now(), now())", [
        uuid_binary(ids.project),
        slug
      ])

      Postgrex.query!(
        database,
        "INSERT INTO integration_connections (id, kind, name, settings, enabled, health, inserted_at, updated_at) VALUES ($1, 'smtp', $2, '{\"host\":\"smtp.example.test\"}', TRUE, 'ok', now(), now())",
        [uuid_binary(ids.connection), slug]
      )

      Postgrex.query!(
        database,
        "INSERT INTO integration_deliveries (id, connection_id, operation, dedupe_key, payload, status, attempts, next_attempt_at, lock_version, inserted_at, updated_at) VALUES ($1, $2, 'email', $3, '{}', 'pending', 0, now(), 1, now(), now())",
        [uuid_binary(ids.delivery), uuid_binary(ids.connection), "dedupe:#{slug}"]
      )

      ids
    after
      GenServer.stop(database)
    end
  end

  defp cleanup_raw_delivery_fixture(%{project: project, connection: connection, delivery: delivery}) do
    database = start_database_connection!()

    try do
      Postgrex.query!(database, "DELETE FROM integration_deliveries WHERE id = $1", [uuid_binary(delivery)])
      Postgrex.query!(database, "DELETE FROM integration_connections WHERE id = $1", [uuid_binary(connection)])
      Postgrex.query!(database, "DELETE FROM projects WHERE id = $1", [uuid_binary(project)])
    after
      GenServer.stop(database)
    end
  end

  defp start_database_connection! do
    opts = Repo.config() |> Keyword.take([:hostname, :port, :username, :password, :database])
    {:ok, connection} = Postgrex.start_link(opts)
    connection
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp uuid_binary(uuid), do: Ecto.UUID.dump!(uuid)
end
