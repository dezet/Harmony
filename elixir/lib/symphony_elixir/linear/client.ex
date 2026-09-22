defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_page_size 50

  @query """
  query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        project {
          id
          name
          slugId
        }
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        project {
          id
          name
          slugId
        }
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @query_by_ids_in_project """
  query SymphonyLinearIssuesByIdInProject($ids: [ID!]!, $projectSlug: String!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}, project: {slugId: {eq: $projectSlug}}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state { name }
        branchName
        url
        project { id name slugId }
        assignee { id }
        labels { nodes { name } }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue { id identifier state { name } }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues, do: fetch_candidate_issues([])

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts) when is_list(opts) do
    tracker = Config.settings!().tracker
    project_slugs = requested_project_slugs(opts, tracker.project_slugs)

    cond do
      is_nil(Keyword.get(opts, :token) || tracker.api_key) ->
        {:error, :missing_linear_api_token}

      project_slugs == [] ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter(opts) do
          do_fetch_by_states(project_slugs, tracker.active_states, assignee_filter, graphql_fun(opts))
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    fetch_issues_by_states(state_names, [])
  end

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, opts) when is_list(state_names) and is_list(opts) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker
      project_slugs = requested_project_slugs(opts, tracker.project_slugs)

      cond do
        is_nil(Keyword.get(opts, :token) || tracker.api_key) ->
          {:error, :missing_linear_api_token}

        project_slugs == [] ->
          {:error, :missing_linear_project_slug}

        true ->
          do_fetch_by_states(project_slugs, normalized_states, nil, graphql_fun(opts))
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    fetch_issue_states_by_ids(issue_ids, [])
  end

  @spec fetch_issue_states_by_ids([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, opts) when is_list(issue_ids) and is_list(opts) do
    ids = Enum.uniq(issue_ids)
    project_slug = requested_project_slug(opts)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter(opts) do
          do_fetch_issue_states(ids, assignee_filter, graphql_fun(opts), project_slug)
        end
    end
  end

  @list_projects_query """
  query SymphonyListProjects {
    teams {
      nodes {
        key
        projects(first: 250) {
          nodes { id name slugId }
        }
      }
    }
  }
  """

  @spec list_projects(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_projects(creds, opts \\ []) when is_map(creds) do
    opts = Keyword.put_new(opts, :token, Map.get(creds, :token))

    with {:ok, body} <- graphql(@list_projects_query, %{}, opts) do
      {:ok, normalize_projects(body)}
    end
  end

  defp normalize_projects(body) do
    body
    |> get_in(["data", "teams", "nodes"])
    |> List.wrap()
    |> Enum.flat_map(fn team ->
      team
      |> get_in(["projects", "nodes"])
      |> List.wrap()
      |> Enum.map(fn p ->
        %{id: p["id"], name: p["name"], slug: p["slugId"], team_key: team["key"]}
      end)
    end)
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))

    request_fun =
      Keyword.get(opts, :request_fun, fn request_payload, headers ->
        post_graphql_request(request_payload, headers, Keyword.get(opts, :timeout_ms, 30_000))
      end)

    with {:ok, headers} <- graphql_headers(Keyword.get(opts, :token)) do
      case safely_request(request_fun, payload, headers) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          if graphql_errors?(body) do
            Logger.error("Linear GraphQL request failed with GraphQL errors")
            {:error, :linear_graphql_errors}
          else
            {:ok, body}
          end

        {:ok, %{status: 200}} ->
          Logger.error("Linear GraphQL request returned an invalid response")
          {:error, :linear_unknown_payload}

        {:ok, %{status: status}} ->
          Logger.error("Linear GraphQL request failed status=#{status}")
          {:error, {:linear_api_status, status}}

        {:error, _reason} ->
          Logger.error("Linear GraphQL request failed at transport")
          {:error, {:linear_api_request, :transport_error}}
      end
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        do_fetch_issue_states(ids, nil, graphql_fun, nil)
    end
  end

  @doc false
  @spec fetch_issues_by_states_for_test(
          [String.t()],
          [String.t()],
          (String.t(), map() -> {:ok, map()} | {:error, term()})
        ) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(project_slugs, state_names, graphql_fun)
      when is_list(project_slugs) and is_list(state_names) and is_function(graphql_fun, 2) do
    do_fetch_by_states(project_slugs, state_names, nil, graphql_fun)
  end

  defp do_fetch_by_states(project_slugs, state_names, assignee_filter, graphql_fun)
       when is_list(project_slugs) and is_function(graphql_fun, 2) do
    Enum.reduce_while(project_slugs, {:ok, []}, fn project_slug, {:ok, acc_issues} ->
      case do_fetch_by_states(project_slug, state_names, assignee_filter, graphql_fun) do
        {:ok, issues} -> {:cont, {:ok, acc_issues ++ issues}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp do_fetch_by_states(project_slug, state_names, assignee_filter, graphql_fun)
       when is_binary(project_slug) and is_function(graphql_fun, 2) do
    do_fetch_by_states_page(project_slug, state_names, assignee_filter, nil, [], graphql_fun)
  end

  defp do_fetch_by_states_page(project_slug, state_names, assignee_filter, after_cursor, acc_issues, graphql_fun) do
    with {:ok, body} <-
           graphql_fun.(@query, %{
             projectSlug: project_slug,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      issues = filter_issues_by_project(issues, project_slug)
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(project_slug, state_names, assignee_filter, next_cursor, updated_acc, graphql_fun)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, assignee_filter, graphql_fun, project_slug)
       when is_list(ids) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, project_slug, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _assignee_filter, _graphql_fun, _project_slug, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, project_slug, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    {query, variables} =
      case project_slug do
        slug when is_binary(slug) ->
          {@query_by_ids_in_project,
           %{
             ids: batch_ids,
             projectSlug: slug,
             first: length(batch_ids),
             relationFirst: @issue_page_size
           }}

        _ ->
          {@query_by_ids,
           %{
             ids: batch_ids,
             first: length(batch_ids),
             relationFirst: @issue_page_size
           }}
      end

    case graphql_fun.(query, variables) do
      {:ok, body} ->
        with {:ok, issues} <- decode_linear_response(body, assignee_filter) do
          issues = filter_issues_by_project(issues, project_slug)
          updated_acc = prepend_page_issues(issues, acc_issues)
          do_fetch_issue_states_page(rest_ids, assignee_filter, graphql_fun, project_slug, updated_acc, issue_order_index)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp graphql_headers(override_token) do
    case override_token || Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp safely_request(request_fun, payload, headers) do
    request_fun.(payload, headers)
  rescue
    _exception -> {:error, :transport_error}
  catch
    _kind, _reason -> {:error, :transport_error}
  end

  defp post_graphql_request(payload, headers, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    Req.post(Config.settings!().tracker.endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: timeout_ms]
    )
  end

  defp post_graphql_request(payload, headers, _timeout_ms), do: post_graphql_request(payload, headers, 30_000)

  defp decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil(&1))

    {:ok, issues}
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  defp requested_project_slugs(opts, defaults) do
    case requested_project_slug(opts) do
      slug when is_binary(slug) and slug != "" -> [slug]
      _ -> defaults
    end
  end

  defp requested_project_slug(opts) do
    Keyword.get(opts, :linear_project_slug) || Keyword.get(opts, :project_slug)
  end

  defp graphql_fun(opts) do
    graphql_opts = Keyword.take(opts, [:token, :request_fun, :timeout_ms])

    fn query, variables ->
      graphql(query, variables, graphql_opts)
    end
  end

  defp graphql_errors?(%{"errors" => _errors}), do: true
  defp graphql_errors?(%{errors: _errors}), do: true
  defp graphql_errors?(_body), do: false

  defp filter_issues_by_project(issues, nil), do: issues

  defp filter_issues_by_project(issues, project_slug) when is_list(issues) and is_binary(project_slug) do
    Enum.filter(issues, &match?(%Issue{project_slug: ^project_slug}, &1))
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter
       ) do
    with {:ok, issues} <- decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter), do: decode_linear_response(response, assignee_filter)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      project_id: get_in(issue, ["project", "id"]),
      project_name: get_in(issue, ["project", "name"]),
      project_slug: get_in(issue, ["project", "slugId"]),
      assignee_id: assignee_field(assignee, "id"),
      blocked_by: extract_blockers(issue),
      labels: extract_labels(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter(opts) do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee, opts)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    build_assignee_filter(assignee, [])
  end

  defp build_assignee_filter(assignee, opts) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter(opts)

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter(opts) do
    case graphql(@viewer_query, %{}, Keyword.take(opts, [:token, :request_fun])) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
