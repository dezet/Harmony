defmodule SymphonyElixir.IntakeDispatcherKillSwitchTest do
  use SymphonyElixir.TestSupport

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Intake.{Dispatcher, Outbox}
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{IntegrationConnection, IntegrationDelivery}

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "effects switch blocks new claims while a claimed delivery can complete" do
    delivery = delivery!()
    now = now()

    assert :empty =
             Dispatcher.dispatch_one(
               fn _delivery -> flunk("effects kill switch must stop dispatch") end,
               claim_opts(now, effects_enabled: false)
             )

    assert {:ok, claimed} = Outbox.claim(claim_opts(now))
    assert claimed.id == delivery.id

    assert {:ok, completed} =
             Outbox.complete(
               delivery.id,
               claimed.lease_token,
               %{provider_id: "accepted-before-stop"},
               intake_enabled: true,
               effects_enabled: false
             )

    assert completed.status == "succeeded"
    assert completed.provider_id == "accepted-before-stop"
  end

  defp claim_opts(now, overrides \\ []) do
    Keyword.merge(
      [now: now, intake_enabled: true, effects_enabled: true, analysis_enabled: true, jitter: fn -> 0.0 end],
      overrides
    )
  end

  defp delivery! do
    connection =
      %IntegrationConnection{}
      |> IntegrationConnection.changeset(%{
        kind: "smtp",
        name: "kill switch #{System.unique_integer([:positive])}",
        settings: %{host: "smtp.example.test"},
        enabled: true
      })
      |> Repo.insert!()

    %IntegrationDelivery{}
    |> IntegrationDelivery.changeset(%{
      operation: "email",
      connection_id: connection.id,
      dedupe_key: "kill-switch:#{Ecto.UUID.generate()}",
      payload: %{},
      status: "pending",
      attempts: 0,
      next_attempt_at: DateTime.add(now(), -1, :second)
    })
    |> Repo.insert!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
