defmodule SymphonyElixirWeb.CaseController do
  @moduledoc """
  Case Center reads (spec §11.2–11.3): the paged case list with totals,
  column counts and per-project sums, one case in detail with the actions
  the backend accepts, and the case history.

  `project` is a project UUID or slug, `filter` one of `all|decision|analysis|done`,
  `column` one of the Kanban columns, `q` a search over title and Jira/Linear
  identifiers (trimmed, case-insensitive, at most 200 characters). A cursor
  is bound to the filters that produced it; any other cursor is a 400.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Cases
  alias SymphonyElixirWeb.{IntakeParams, IntakePresenter, ProjectRef}

  @max_query_length 200
  @events_page_size 50

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, params) do
    with {:ok, project_id} <- project_id(params["project"]),
         {:ok, filter} <- enum_param(params["filter"], Cases.filters(), "all"),
         {:ok, column} <- enum_param(params["column"], Cases.columns(), nil),
         {:ok, q} <- search(params["q"]),
         scope = list_scope(project_id, filter, column, q),
         {:ok, page} <- IntakePresenter.page_params(params, scope),
         {:ok, position} <- IntakePresenter.timestamp_after(page.after, &valid_ref?/1) do
      result = Cases.list(project_id: project_id, filter: filter, column: column, q: q, limit: page.page_size, after: position)
      json(conn, IntakePresenter.cases_page(result, page.page_size, scope))
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"ref" => ref}) do
    case Cases.fetch(ref, IntakeParams.adapter(:case_action_opts, [])) do
      {:ok, detail} -> json(conn, IntakePresenter.case_detail(detail))
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec events(Conn.t(), map()) :: Conn.t()
  def events(conn, %{"ref" => ref} = params) do
    scope = "case-events:" <> ref

    with {:ok, _parsed} <- Cases.parse_ref(ref),
         {:ok, page} <- IntakePresenter.page_params(params, scope, @events_page_size),
         {:ok, position} <- IntakePresenter.timestamp_after(page.after, &uuid?/1),
         {:ok, result} <- Cases.events(ref, limit: page.page_size, after: position) do
      json(conn, IntakePresenter.case_events_page(result, page.page_size, scope))
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params), do: IntakePresenter.render_error(conn, :method_not_allowed)

  defp project_id(nil), do: {:ok, nil}
  defp project_id(""), do: {:ok, nil}

  defp project_id(ref) when is_binary(ref) do
    case ProjectRef.resolve(ref) do
      {:ok, project} -> {:ok, project.id}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp project_id(_ref), do: {:error, :invalid_query}

  defp enum_param(nil, _allowed, default), do: {:ok, default}
  defp enum_param(value, allowed, _default) when is_binary(value) and value != "", do: if(value in allowed, do: {:ok, value}, else: {:error, :invalid_query})
  defp enum_param(_value, _allowed, _default), do: {:error, :invalid_query}

  defp search(nil), do: {:ok, nil}

  defp search(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      q -> if String.length(q) <= @max_query_length, do: {:ok, q}, else: {:error, :invalid_query}
    end
  end

  defp search(_value), do: {:error, :invalid_query}

  defp list_scope(project_id, filter, column, q) do
    Enum.join(["cases", project_id || "", filter, column || "", String.downcase(q || "")], "\n")
  end

  defp valid_ref?(ref), do: match?({:ok, _parsed}, Cases.parse_ref(ref))
  defp uuid?(id), do: match?({:ok, _uuid}, Ecto.UUID.cast(id))
end
