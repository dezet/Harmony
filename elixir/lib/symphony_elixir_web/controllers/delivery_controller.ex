defmodule SymphonyElixirWeb.DeliveryController do
  @moduledoc """
  Manual retry of one outbox delivery (spec §6.2). The body names the status
  the operator saw (`expected_status`); a changed status is a conflict. An
  `unknown` delivery needs `confirm_duplicate_risk: true`. Retrying sends to a
  provider, so it is refused while `intake.effects_enabled` is false.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Intake.Outbox
  alias SymphonyElixirWeb.{IntakeParams, IntakePresenter}

  @statuses ~w(pending running retry_wait succeeded failed unknown paused)

  @spec retry(Conn.t(), map()) :: Conn.t()
  def retry(conn, %{"id" => id}) do
    body = conn.body_params

    with :ok <- IntakeParams.permit(body, ~w(expected_status confirm_duplicate_risk)),
         {:ok, expected_status} <- expected_status(body),
         {:ok, confirm_duplicate_risk?} <- IntakeParams.optional_boolean(body, "confirm_duplicate_risk"),
         {:ok, delivery} <- Outbox.fetch(id),
         :ok <- if(delivery.status == expected_status, do: :ok, else: {:error, :status_mismatch}),
         :ok <- IntakeParams.effects_enabled(),
         {:ok, retried} <- Outbox.manual_retry(delivery.id, confirm_duplicate_risk: confirm_duplicate_risk?) do
      conn |> put_status(:accepted) |> json(%{delivery: IntakePresenter.delivery(retried)})
    else
      {:error, :confirmation_required} ->
        IntakePresenter.render_error(conn, {:confirmation_required, "confirm_duplicate_risk"})

      {:error, reason} ->
        IntakePresenter.render_error(conn, reason)
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params), do: IntakePresenter.render_error(conn, :method_not_allowed)

  defp expected_status(%{"expected_status" => status}) when status in @statuses, do: {:ok, status}

  defp expected_status(_body),
    do: {:error, {:validation, %{"expected_status" => ["must be one of: " <> Enum.join(@statuses, ", ")]}}}
end
