defmodule SymphonyElixirWeb.CaseActionController do
  @moduledoc """
  Operator decisions on a Jira intake case: acknowledge, approve repair and
  reanalyze. Each needs the case `expected_version`; approve and reanalyze
  also need `confirmed: true`. Only `jira_<uuid>` refs support actions.
  Reanalysis starts a new paid analysis and is refused while
  `intake.effects_enabled` is false.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Intake
  alias SymphonyElixirWeb.{IntakeParams, IntakePresenter}

  @spec acknowledge(Conn.t(), map()) :: Conn.t()
  def acknowledge(conn, %{"ref" => ref}) do
    body = conn.body_params

    with {:ok, case_id} <- parse_ref(ref),
         :ok <- IntakeParams.permit(body, ~w(expected_version)),
         {:ok, expected_version} <- IntakeParams.positive_integer(body, "expected_version"),
         {:ok, intake_case} <- Intake.acknowledge(case_id, expected_version, action_opts()) do
      json(conn, %{case: IntakePresenter.case_state(intake_case), version: intake_case.lock_version})
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec approve_repair(Conn.t(), map()) :: Conn.t()
  def approve_repair(conn, %{"ref" => ref}) do
    body = conn.body_params

    with {:ok, case_id} <- parse_ref(ref),
         :ok <- IntakeParams.permit(body, ~w(expected_version analysis_version confirmed)),
         {:ok, expected_version} <- IntakeParams.positive_integer(body, "expected_version"),
         {:ok, analysis_version} <- IntakeParams.positive_integer(body, "analysis_version"),
         :ok <- IntakeParams.confirmed(body),
         {:ok, intake_case} <-
           Intake.approve_repair(case_id, expected_version, analysis_version, true, action_opts()) do
      json(conn, %{
        status: "approved",
        case: IntakePresenter.case_state(intake_case),
        version: intake_case.lock_version
      })
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec reanalyze(Conn.t(), map()) :: Conn.t()
  def reanalyze(conn, %{"ref" => ref}) do
    body = conn.body_params

    with {:ok, case_id} <- parse_ref(ref),
         :ok <- IntakeParams.permit(body, ~w(expected_version confirmed)),
         {:ok, expected_version} <- IntakeParams.positive_integer(body, "expected_version"),
         :ok <- IntakeParams.confirmed(body),
         :ok <- IntakeParams.effects_enabled(),
         {:ok, intake_case} <- Intake.reanalyze(case_id, expected_version, true, action_opts()) do
      conn
      |> put_status(:accepted)
      |> json(%{
        analysis_version: intake_case.analysis_version,
        case: IntakePresenter.case_state(intake_case),
        version: intake_case.lock_version
      })
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params), do: IntakePresenter.render_error(conn, :method_not_allowed)

  defp parse_ref("jira_" <> id), do: IntakeParams.uuid(id)
  defp parse_ref("run_" <> _id), do: {:error, :unsupported_case_kind}
  defp parse_ref(_ref), do: {:error, :not_found}

  defp action_opts, do: IntakeParams.adapter(:case_action_opts, [])
end
