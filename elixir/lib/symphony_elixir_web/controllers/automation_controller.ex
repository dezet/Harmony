defmodule SymphonyElixirWeb.AutomationController do
  @moduledoc """
  Jira intake rules: list, create, partial edit, dry-run preview, confirmed
  activation, pause and manual "check now".

  Edits are optimistic on `config_version` (`version` in the body) and never
  activate a rule. Activation is a separate confirmed step, is refused while
  `intake.effects_enabled` is false and first verifies the §7.1 requirements
  with reads only (`ActivationCheck`); the checked `config_version` must still
  be current when the rule is activated. A manual check returns the ID of the
  scan it claimed.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Intake.{ActivationCheck, Preview, Rules, Scheduler}
  alias SymphonyElixirWeb.{IntakeParams, IntakePresenter}

  @rule_fields ~w(
    name project_id jira_connection_id source_type source_id priority_ids interval_seconds
    initial_policy linear_team_id linear_project_id linear_todo_state_id linear_hold_label_id
    email_connection_id sms_connection_id email_recipients sms_recipients
  )

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, params) do
    with {:ok, project_id} <- IntakeParams.optional_uuid(params["project"], "project"),
         scope = "automations:#{project_id}",
         {:ok, page} <- IntakePresenter.page_params(params, scope),
         {:ok, position} <- IntakePresenter.keyset_after(page.after) do
      rules = Rules.list_page(limit: page.page_size + 1, after: position, project_id: project_id)
      json(conn, IntakePresenter.page(rules, page.page_size, scope, &IntakePresenter.rule/1))
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, _params) do
    body = conn.body_params

    with :ok <- IntakeParams.permit(body, @rule_fields),
         {:ok, rule} <- Rules.create(body) do
      conn |> put_status(:created) |> json(%{rule: IntakePresenter.rule(rule)})
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"id" => id}) do
    case Rules.fetch(id) do
      {:ok, rule} -> json(conn, %{rule: IntakePresenter.rule(rule)})
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec update(Conn.t(), map()) :: Conn.t()
  def update(conn, %{"id" => id}) do
    body = conn.body_params

    with {:ok, version} <- IntakeParams.positive_integer(body, "version"),
         attrs = Map.delete(body, "version"),
         :ok <- IntakeParams.permit(attrs, @rule_fields),
         {:ok, rule_id} <- IntakeParams.uuid(id),
         {:ok, rule} <- Rules.patch_versioned(rule_id, version, attrs) do
      json(conn, %{rule: IntakePresenter.rule(rule)})
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec preview(Conn.t(), map()) :: Conn.t()
  def preview(conn, %{"id" => id}) do
    with :ok <- IntakeParams.permit(conn.body_params, []),
         {:ok, rule} <- Rules.fetch(id),
         {:ok, preview} <- Preview.run(rule, IntakeParams.jira_opts()) do
      json(conn, preview)
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec activate(Conn.t(), map()) :: Conn.t()
  def activate(conn, %{"id" => id}) do
    body = conn.body_params

    with :ok <- IntakeParams.permit(body, ~w(version confirmed)),
         {:ok, version} <- IntakeParams.positive_integer(body, "version"),
         :ok <- IntakeParams.confirmed(body),
         :ok <- IntakeParams.effects_enabled(),
         {:ok, current} <- Rules.fetch(id),
         :ok <- if(current.config_version == version, do: :ok, else: {:error, :stale_version}),
         {:ok, %{priority_ranking: ranking}} <- ActivationCheck.run(current, activation_opts()),
         {:ok, rule} <- Rules.activate_versioned(current.id, version, priority_ranking: ranking) do
      status = if rule.enabled, do: "enabled", else: rule.activation_status
      conn |> put_status(:accepted) |> json(%{status: status, rule: IntakePresenter.rule(rule)})
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec pause(Conn.t(), map()) :: Conn.t()
  def pause(conn, %{"id" => id}) do
    body = conn.body_params

    with :ok <- IntakeParams.permit(body, ~w(version)),
         {:ok, version} <- IntakeParams.positive_integer(body, "version"),
         {:ok, rule_id} <- IntakeParams.uuid(id),
         {:ok, rule} <- Rules.pause_versioned(rule_id, version) do
      json(conn, %{rule: IntakePresenter.rule(rule)})
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec check(Conn.t(), map()) :: Conn.t()
  def check(conn, %{"id" => id}) do
    with :ok <- IntakeParams.permit(conn.body_params, []),
         {:ok, rule_id} <- IntakeParams.uuid(id),
         {:accepted, scan_id} <- check_now(rule_id) do
      conn |> put_status(:accepted) |> json(%{status: "accepted", rule_id: rule_id, scan_id: scan_id})
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec check_all(Conn.t(), map()) :: Conn.t()
  def check_all(conn, _params) do
    body = conn.body_params

    with :ok <- IntakeParams.permit(body, ~w(project)),
         {:ok, project_id} <- IntakeParams.optional_uuid(body["project"], "project"),
         {:ok, results} <- check_rules(Rules.list_ids(project_id)) do
      conn
      |> put_status(:accepted)
      |> json(%{
        accepted_rule_ids: for({rule_id, {:accepted, _scan_id}} <- results, do: rule_id),
        skipped: for({rule_id, {:error, code}} <- results, do: %{rule_id: rule_id, code: Atom.to_string(code)})
      })
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params), do: IntakePresenter.render_error(conn, :method_not_allowed)

  defp activation_opts do
    linear_opts =
      case IntakeParams.adapter(:linear_request_fun) do
        nil -> []
        request_fun -> [request_fun: request_fun]
      end

    [jira_opts: IntakeParams.jira_opts(), linear_opts: linear_opts]
    |> then(fn opts ->
      case IntakeParams.adapter(:analysis_profile_fun) do
        nil -> opts
        profile_fun -> Keyword.put(opts, :analysis_profile_fun, profile_fun)
      end
    end)
  end

  defp check_rules(rule_ids) do
    Enum.reduce_while(rule_ids, {:ok, []}, fn rule_id, {:ok, acc} ->
      case check_now(rule_id) do
        {:error, :scheduler_unavailable} = error -> {:halt, error}
        result -> {:cont, {:ok, acc ++ [{rule_id, result}]}}
      end
    end)
  end

  # The scheduler owns the per-rule and global scan limits; a missing
  # scheduler (intake disabled at boot) fails closed.
  defp check_now(rule_id) do
    case Scheduler.check_now(IntakeParams.adapter(:scheduler, Scheduler), rule_id) do
      {:accepted, scan_id} -> {:accepted, scan_id}
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  catch
    :exit, _reason -> {:error, :scheduler_unavailable}
  end
end
