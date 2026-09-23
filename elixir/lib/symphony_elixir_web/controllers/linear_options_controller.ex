defmodule SymphonyElixirWeb.LinearOptionsController do
  @moduledoc """
  Linear targets for the rule form of one project, read with that project's
  Linear token, and the confirmed creation of the analysis-only hold label.
  Creating the label writes to Linear, so it is refused while
  `intake.effects_enabled` is false.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Intake.LinearOptions
  alias SymphonyElixirWeb.{IntakeParams, IntakePresenter}

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, project} <- LinearOptions.fetch_project(id),
         {:ok, options} <- LinearOptions.list(project, linear_opts()) do
      json(conn, options)
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec create_hold_label(Conn.t(), map()) :: Conn.t()
  def create_hold_label(conn, %{"id" => id}) do
    body = conn.body_params

    with :ok <- IntakeParams.permit(body, ~w(team_id confirmed)),
         {:ok, team_id} <- team_id(body),
         :ok <- IntakeParams.confirmed(body),
         {:ok, project} <- LinearOptions.fetch_project(id),
         :ok <- IntakeParams.effects_enabled(),
         {:ok, %{created: created?} = label} <- LinearOptions.ensure_hold_label(project, team_id, linear_opts()) do
      conn
      |> put_status(if(created?, do: :created, else: :ok))
      |> json(label)
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params), do: IntakePresenter.render_error(conn, :method_not_allowed)

  defp team_id(%{"team_id" => team_id}) when is_binary(team_id) and team_id != "", do: {:ok, team_id}
  defp team_id(_body), do: {:error, {:validation, %{"team_id" => ["is required"]}}}

  defp linear_opts do
    case IntakeParams.adapter(:linear_request_fun) do
      nil -> []
      request_fun -> [request_fun: request_fun]
    end
  end
end
