defmodule SymphonyElixir.IntakeDispatcherTest.UnknownAdapter do
  def perform(_delivery), do: {:unknown, "provider_timeout"}
end

defmodule SymphonyElixir.IntakeDispatcherTest do
  use SymphonyElixir.TestSupport

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Intake.{Dispatcher, Outbox}
  alias SymphonyElixir.Intake
  alias SymphonyElixir.Intake.Scheduler
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{IntegrationConnection, IntegrationDelivery}

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "runtime intake scheduler is absent while the default intake switch is disabled" do
    refute Intake.enabled?()
    refute Process.whereis(Scheduler)
  end

  test "dispatcher commits the lease before calling the injected I/O adapter" do
    ids = raw_delivery_fixture!("dispatcher-#{System.unique_integer([:positive])}")
    on_exit(fn -> cleanup_raw_delivery_fixture(ids) end)
    parent = self()

    result =
      Sandbox.unboxed_run(Repo, fn ->
        Dispatcher.dispatch_one(
          fn delivery ->
            assert Repo.in_transaction?() == false
            assert Repo.get!(IntegrationDelivery, delivery.id).status == "running"
            send(parent, {:adapter_called, delivery.operation})
            {:ok, %{provider_id: "smtp-accepted-1"}}
          end,
          claim_opts(now(), operation: "email", connection_id: ids.connection)
        )
      end)

    assert_receive {:adapter_called, "email"}
    assert {:ok, completed} = result
    assert completed.status == "succeeded"
    assert completed.provider_id == "smtp-accepted-1"
    database = start_database_connection!()

    try do
      %{rows: [["succeeded"]]} =
        Postgrex.query!(database, "SELECT status FROM integration_deliveries WHERE id = $1", [
          uuid_binary(ids.delivery)
        ])
    after
      GenServer.stop(database)
    end
  end

  test "kill switch blocks new claims while an in-flight result still wins its lease CAS" do
    delivery = delivery!("email")
    now = now()

    assert :empty =
             Dispatcher.dispatch_one(
               fn _delivery -> flunk("kill switch must stop dispatch") end,
               claim_opts(now, operation: "email", intake_enabled: false)
             )

    assert {:ok, claimed} = Outbox.claim(claim_opts(now, operation: "email"))
    assert claimed.id == delivery.id

    assert {:ok, completed} =
             Outbox.complete(delivery.id, claimed.lease_token, %{provider_id: "accepted-before-stop"},
               intake_enabled: false,
               effects_enabled: false
             )

    assert completed.status == "succeeded"
    assert completed.provider_id == "accepted-before-stop"
  end

  test "retryable adapter failures use Retry-After and terminal failures stop immediately" do
    retryable = delivery!("sms")
    terminal = delivery!("jira_comment")
    now = now()

    assert {:retry_wait, retried} =
             Dispatcher.dispatch_one(
               fn _delivery -> {:retry, "http_429", "120"} end,
               claim_opts(now, operation: "sms", jitter: fn -> 0.5 end)
             )

    assert retried.id == retryable.id
    assert retried.status == "retry_wait"
    assert retried.last_error_code == "http_429"
    assert DateTime.diff(retried.next_attempt_at, now, :second) == 120

    assert {:failed, failed} =
             Dispatcher.dispatch_one(
               fn _delivery -> {:error, "permission_denied"} end,
               claim_opts(now, operation: "jira_comment")
             )

    assert failed.id == terminal.id
    assert failed.status == "failed"
    assert failed.last_error_code == "permission_denied"
    assert failed.attempts == 1
  end

  test "an expired adapter lease cannot overwrite a concurrent terminal result" do
    delivery = delivery!("jira_comment")
    now = now()

    assert {:error, :stale_lease} =
             Dispatcher.dispatch_one(
               fn claimed ->
                 assert {:ok, failed} =
                          Outbox.fail(delivery.id, claimed.lease_token, "worker_timeout", now: now)

                 assert failed.status == "failed"
                 {:ok, %{provider_id: "late-ack"}}
               end,
               claim_opts(now, operation: "jira_comment")
             )

    stored = Repo.get!(IntegrationDelivery, delivery.id)
    assert stored.status == "failed"
    assert stored.provider_id == nil
    assert stored.last_error_code == "worker_timeout"
  end

  test "invalid adapter results leave the delivery leased for recovery" do
    delivery = delivery!("sms")
    now = now()

    assert {:error, {:invalid_adapter_result, :unexpected}} =
             Dispatcher.dispatch_one(fn _delivery -> :unexpected end, claim_opts(now, operation: "sms"))

    stored = Repo.get!(IntegrationDelivery, delivery.id)
    assert stored.status == "running"
    assert is_binary(stored.lease_token)
    assert stored.attempts == 1
  end

  test "adapter-reported uncertain results remain unknown until reconciled" do
    delivery = delivery!("jira_comment")
    now = now()

    assert {:unknown, unknown} =
             Dispatcher.dispatch_one(
               fn _delivery -> {:unknown, "provider_timeout"} end,
               claim_opts(now, operation: "jira_comment")
             )

    assert unknown.id == delivery.id
    assert unknown.status == "unknown"
    assert unknown.last_error_code == "provider_timeout"
    assert is_nil(unknown.lease_token)
  end

  test "dispatcher reports an exhausted automatic retry as failed" do
    delivery = delivery!("sms", attempts: 4)
    now = now()

    assert {:failed, failed} =
             Dispatcher.dispatch_one(
               fn _delivery -> {:retry, "provider_unavailable", nil} end,
               claim_opts(now, operation: "sms")
             )

    assert failed.id == delivery.id
    assert failed.status == "failed"
    assert failed.attempts == 5
    assert failed.last_error_code == "provider_unavailable"
  end

  test "module adapters can report uncertain provider outcomes" do
    delivery = delivery!("jira_comment")
    now = now()

    assert {:unknown, unknown} =
             Dispatcher.dispatch_one(
               SymphonyElixir.IntakeDispatcherTest.UnknownAdapter,
               claim_opts(now, operation: "jira_comment")
             )

    assert unknown.id == delivery.id
    assert unknown.status == "unknown"
    assert unknown.last_error_code == "provider_timeout"
    assert is_nil(unknown.lease_token)
  end

  test "analysis claims have their own concurrency slot apart from four concurrent I/O claims" do
    Enum.each(1..4, fn _index -> delivery!("email") end)
    pending_io = delivery!("sms")
    analysis = delivery!("analysis")
    now = now()

    Enum.each(1..4, fn _index ->
      assert {:ok, claimed} = Outbox.claim(claim_opts(now, operation: "email"))
      assert claimed.status == "running"
    end)

    assert :empty = Outbox.claim(claim_opts(now, operation: "sms"))
    assert {:ok, analysis_claim} = Outbox.claim(claim_opts(now, operation: "analysis"))
    assert analysis_claim.id == analysis.id
    assert Repo.get!(IntegrationDelivery, pending_io.id).status == "pending"
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
    connection_kind =
      case operation do
        "email" -> "smtp"
        "sms" -> "smsapi"
        "jira_comment" -> "jira_cloud"
        _operation -> nil
      end

    connection_id =
      if connection_kind do
        connection =
          %IntegrationConnection{}
          |> IntegrationConnection.changeset(%{
            kind: connection_kind,
            name: "#{operation} #{System.unique_integer([:positive])}",
            settings:
              case connection_kind do
                "smtp" -> %{host: "smtp.example.test"}
                "smsapi" -> %{sender: "Harmony"}
                "jira_cloud" -> %{site_url: "https://dispatcher-#{System.unique_integer([:positive])}.atlassian.net"}
              end,
            enabled: true
          })
          |> Repo.insert!()

        connection.id
      end

    defaults = %{
      operation: operation,
      connection_id: connection_id,
      dedupe_key: "dispatcher:#{Ecto.UUID.generate()}",
      payload: %{},
      status: "pending",
      attempts: 0,
      next_attempt_at: DateTime.add(now(), -1, :second)
    }

    %IntegrationDelivery{}
    |> IntegrationDelivery.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
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
