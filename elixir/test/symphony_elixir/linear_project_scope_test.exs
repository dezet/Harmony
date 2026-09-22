defmodule SymphonyElixir.LinearProjectScopeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.WorkSources.LinearIssueSource

  test "per-project Linear sources do not receive another project's issues" do
    issues = [linear_issue("portal"), linear_issue("billing")]

    for {project_slug, token} <- [{"portal", "portal-token"}, {"billing", "billing-token"}] do
      assert {:ok, [run]} =
               LinearIssueSource.fetch_candidates(
                 project_id: "storage-#{project_slug}",
                 project_slug: project_slug,
                 linear_project_slug: project_slug,
                 token: token,
                 issue_fetcher: fn -> {:ok, issues} end,
                 execution_gate_fun: fn _issue, _project_id -> :ok end
               )

      assert run.linear_issue_id == "issue-#{project_slug}"
    end
  end

  test "scoped source fetchers receive the explicit project and token" do
    parent = self()

    issue_fetcher = fn opts ->
      send(parent, {:linear_scope, opts[:linear_project_slug], opts[:token]})
      {:ok, [linear_issue(opts[:linear_project_slug])]}
    end

    assert {:ok, [run]} =
             LinearIssueSource.fetch_candidates(
               project_id: "storage-portal",
               project_slug: "harmony-portal",
               linear_project_slug: "portal",
               token: "portal-token",
               issue_fetcher: issue_fetcher,
               execution_gate_fun: fn _issue, _project_id -> :ok end
             )

    assert run.project_slug == "harmony-portal"
    assert run.linear_issue_id == "issue-portal"
    assert_received {:linear_scope, "portal", "portal-token"}
  end

  test "client polls one project with only its explicit token" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "global-project",
      tracker_project_slugs: ["global-project"]
    )

    parent = self()

    for {project_slug, token} <- [{"portal", "portal-token"}, {"billing", "billing-token"}] do
      request_fun = fn payload, headers ->
        send(parent, {:candidate_request, payload, headers})
        {:ok, %{status: 200, body: candidate_response(project_slug)}}
      end

      assert {:ok, [issue]} =
               Client.fetch_candidate_issues(
                 linear_project_slug: project_slug,
                 token: token,
                 request_fun: request_fun
               )

      assert issue.id == "issue-#{project_slug}"
      assert issue.project_slug == project_slug

      assert_receive {:candidate_request, %{"variables" => %{projectSlug: ^project_slug}}, headers}
      assert {"Authorization", ^token} = List.keyfind(headers, "Authorization", 0)
    end
  end

  test "retry candidate lookup and issue revalidation keep the same project scope" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "portal")

    projects = [
      %{
        id: "storage-portal",
        linear_project_slug: "portal",
        tracker_secret: "portal-token"
      },
      %{
        id: "storage-billing",
        linear_project_slug: "billing",
        tracker_secret: "billing-token"
      }
    ]

    Application.put_env(:symphony_elixir, :project_fetcher, fn -> projects end)
    parent = self()

    candidate_request_fun = fn payload, headers ->
      send(parent, {:retry_candidate_request, payload, headers})
      {:ok, %{status: 200, body: candidate_response("portal")}}
    end

    assert {:ok, [candidate]} = Orchestrator.fetch_project_candidates_for_test("portal", candidate_request_fun)
    assert candidate.id == "issue-portal"
    assert_receive {:retry_candidate_request, %{"variables" => %{projectSlug: "portal"}}, headers}
    assert {"Authorization", "portal-token"} = List.keyfind(headers, "Authorization", 0)

    issue = linear_issue("portal")

    state_request_fun = fn payload, headers ->
      send(parent, {:revalidation_request, payload, headers})
      {:ok, %{status: 200, body: issue_state_response("portal")}}
    end

    assert {:ok, [refreshed_issue]} = Orchestrator.fetch_project_issue_states_for_test(issue, state_request_fun)
    assert refreshed_issue.project_slug == "portal"
    assert_receive {:revalidation_request, %{"query" => query, "variables" => variables}, state_headers}
    assert query =~ "project: {slugId: {eq: $projectSlug}}"
    assert variables.projectSlug == "portal"
    assert variables.ids == ["issue-portal"]
    assert {"Authorization", "portal-token"} = List.keyfind(state_headers, "Authorization", 0)
  end

  test "orchestrator source options choose the project's token and Linear slug" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "global-token")

    opts =
      Orchestrator.linear_project_source_options_for_test(%{
        id: "storage-portal",
        slug: "harmony-portal",
        linear_project_slug: "portal",
        tracker_secret: "portal-token",
        forge_base_branch: "main",
        config_version: 2,
        config: %{}
      })

    assert opts[:project_id] == "storage-portal"
    assert opts[:project_slug] == "harmony-portal"
    assert opts[:linear_project_slug] == "portal"
    assert opts[:token] == "portal-token"

    parent = self()

    request_fun = fn payload, headers ->
      send(parent, {:source_request, payload, headers})
      {:ok, %{status: 200, body: candidate_response("portal")}}
    end

    assert {:ok, [run]} =
             LinearIssueSource.fetch_candidates(
               Keyword.merge(opts,
                 request_fun: request_fun,
                 execution_gate_fun: fn _issue, _project_id -> :ok end
               )
             )

    assert run.project_slug == "harmony-portal"
    assert_receive {:source_request, %{"variables" => %{projectSlug: "portal"}}, headers}
    assert {"Authorization", "portal-token"} = List.keyfind(headers, "Authorization", 0)

    fallback_opts =
      Orchestrator.linear_project_source_options_for_test(%{
        id: "storage-billing",
        slug: "harmony-billing",
        linear_project_slug: "billing",
        tracker_secret: nil,
        forge_base_branch: "main",
        config_version: 2,
        config: %{}
      })

    assert fallback_opts[:token] == "global-token"
  end

  test "HTTP 200 GraphQL errors fail and transport logs omit token and description" do
    token = "secret-token-that-must-not-be-logged"
    description = "sensitive source description that must not be logged"

    graphql_log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :linear_graphql_errors} =
                 Client.graphql(
                   "query Issue { issue { id } }",
                   %{description: description},
                   token: token,
                   request_fun: fn _payload, _headers ->
                     {:ok, %{status: 200, body: %{"errors" => [%{"message" => description}]}}}
                   end
                 )
      end)

    refute graphql_log =~ token
    refute graphql_log =~ description

    transport_log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_request, :transport_error}} =
                 Client.graphql(
                   "query Issue { issue { id } }",
                   %{description: description},
                   token: token,
                   request_fun: fn _payload, _headers ->
                     {:error, {:request_failed, token, description}}
                   end
                 )
      end)

    refute transport_log =~ token
    refute transport_log =~ description
  end

  defp linear_issue(project_slug) do
    %Issue{
      id: "issue-#{project_slug}",
      identifier: "#{project_slug}-1",
      title: "Issue for #{project_slug}",
      state: "Todo",
      project_slug: project_slug
    }
  end

  defp candidate_response(project_slug) do
    %{
      "data" => %{
        "issues" => %{
          "nodes" => [raw_linear_issue(project_slug)],
          "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
        }
      }
    }
  end

  defp issue_state_response(project_slug) do
    %{"data" => %{"issues" => %{"nodes" => [raw_linear_issue(project_slug)]}}}
  end

  defp raw_linear_issue(project_slug) do
    %{
      "id" => "issue-#{project_slug}",
      "identifier" => "#{project_slug}-1",
      "title" => "Issue for #{project_slug}",
      "description" => "Source description for #{project_slug}",
      "state" => %{"name" => "Todo"},
      "project" => %{
        "id" => "linear-#{project_slug}",
        "name" => String.capitalize(project_slug),
        "slugId" => project_slug
      },
      "labels" => %{"nodes" => []},
      "inverseRelations" => %{"nodes" => []}
    }
  end
end
