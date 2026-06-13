defmodule SymphonyElixir.RoadmapE2E do
  @moduledoc """
  Deterministic local scenarios for roadmap E2E browser proof.
  """

  alias SymphonyElixir.Evidence.Collector
  alias SymphonyElixir.Github.{PullRequest, WorkflowRun}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RuntimePolicy.{Handoff, ImplementationHandoff}
  alias SymphonyElixir.Storage
  alias SymphonyElixir.WorkRun
  alias SymphonyElixir.WorkSources.{GithubFailedCiSource, GithubPrSource, LinearIssueSource}

  @scenarios [
    "milestone1",
    "milestone2",
    "milestone3_success",
    "milestone3_blocker",
    "milestone4",
    "milestone5"
  ]

  @default_port 4000
  @project_slug "roadmap-e2e"

  @type summary :: %{
          scenario: String.t(),
          runtime_url: String.t(),
          project_id: String.t(),
          project_slug: String.t(),
          work_run_ids: [String.t()],
          dedupe_keys: [String.t()],
          expected_assertions: [String.t()],
          external_network?: false
        }

  @spec scenarios() :: [String.t()]
  def scenarios, do: @scenarios

  @spec run(String.t(), keyword()) :: {:ok, summary()} | {:error, term()}
  def run(scenario, opts \\ []) when is_binary(scenario) and is_list(opts) do
    if scenario in @scenarios do
      do_run(scenario, opts)
    else
      {:error, {:unknown_roadmap_e2e_scenario, scenario}}
    end
  end

  @spec format_summary(summary()) :: String.t()
  def format_summary(summary) when is_map(summary) do
    [
      "scenario=#{summary.scenario}",
      "runtime_url=#{summary.runtime_url}",
      "project_id=#{summary.project_id}",
      "project_slug=#{summary.project_slug}",
      "work_run_ids=#{Enum.join(summary.work_run_ids, ",")}",
      "dedupe_keys=#{Enum.join(summary.dedupe_keys, ",")}",
      "expected_assertions=#{Enum.join(summary.expected_assertions, " | ")}",
      "external_network=#{summary.external_network?}"
    ]
    |> Enum.join("\n")
  end

  defp do_run("milestone1", opts) do
    with {:ok, project} <- upsert_project(),
         {:ok, implementation_run} <- seed_milestone1_implementation(project),
         {:ok, _observations} <- seed_milestone1_pr_observation(project) do
      {:ok,
       summary("milestone1", project, opts,
         work_runs: [implementation_run],
         dedupe_keys: [implementation_run.dedupe_key],
         expected_assertions: [
           "implementation run persisted with project_id",
           "pull_request_links contains COD-101 PR #17"
         ]
       )}
    end
  end

  defp do_run("milestone2", opts) do
    with {:ok, project} <- upsert_project(),
         {:ok, run} <- seed_milestone2_failed_ci(project),
         {:ok, _dedupe} <-
           Storage.mark_dedupe_blocked(%{
             project_id: project.id,
             key: run.dedupe_key,
             scope: "ci_fix",
             metadata: %{"reason" => "unsafe_failed_ci_repair"}
           }),
         {:ok, _blocker} <-
           Storage.upsert_open_blocker(%{
             project_id: project.id,
             work_run_id: run.id,
             target_type: "pull_request",
             target_id: Integer.to_string(run.github_pr_number),
             reason: "unsafe_failed_ci_repair",
             metadata: %{"dedupe_key" => run.dedupe_key}
           }),
         {:ok, _event} <- append_event_once(project.id, run.id, "github_comment_created", %{"github_pr_number" => 18}),
         {:ok, _event} <- append_event_once(project.id, run.id, "linear_comment_created", %{"linear_issue_id" => "roadmap-e2e-m2"}) do
      {:ok,
       summary("milestone2", project, opts,
         work_runs: [run],
         dedupe_keys: [run.dedupe_key],
         expected_assertions: [
           "blocked dedupe status suppresses retry",
           "second poll suppressed by blocked dedupe",
           "external writes emitted work_events"
         ]
       )}
    end
  end

  defp do_run("milestone3_success", opts) do
    with {:ok, project} <- upsert_project(),
         {:ok, run} <- seed_implementation_run(project, "roadmap-e2e-m3-success", "COD-301"),
         {:ok, _link} <- seed_pr_link(project, 19, "cod-301-roadmap-e2e", "develop", "COD-301"),
         :ok <-
           ImplementationHandoff.publish(to_runtime_work_run(run, project, required_evidence: []),
             tracker_update: fn _issue_id, "Human Review" -> :ok end
           ) do
      {:ok,
       summary("milestone3_success", project, opts,
         work_runs: [run],
         dedupe_keys: [run.dedupe_key],
         expected_assertions: [
           "linear_state_updated:Human Review",
           "no scenario sets Linear Done or merges PR"
         ]
       )}
    end
  end

  defp do_run("milestone3_blocker", opts) do
    with {:ok, project} <- upsert_project(),
         {:ok, run} <- seed_implementation_run(project, "roadmap-e2e-m3-blocker", "COD-302"),
         {:error, :missing_pull_request_link} <-
           ImplementationHandoff.publish(to_runtime_work_run(run, project, required_evidence: []),
             linear_comment: fn "roadmap-e2e-m3-blocker", _body -> :ok end
           ) do
      {:ok,
       summary("milestone3_blocker", project, opts,
         work_runs: [run],
         dedupe_keys: [run.dedupe_key],
         expected_assertions: [
           "missing PR link records blocker",
           "bad base/head branch policy records blocker",
           "no scenario sets Linear Done or merges PR"
         ]
       )}
    end
  end

  defp do_run("milestone4", opts) do
    with {:ok, project} <- upsert_project(),
         {:ok, run} <- seed_implementation_run(project, "roadmap-e2e-m4", "COD-401", required_evidence: ["browser"]),
         {:error, {:missing_required_evidence, ["browser"]}} <-
           Handoff.verify_required_evidence(%{required_evidence: ["browser"]}, []),
         {:ok, _blocker} <-
           Storage.upsert_open_blocker(%{
             project_id: project.id,
             work_run_id: run.id,
             target_type: "linear_issue",
             target_id: "roadmap-e2e-m4",
             reason: "missing_required_evidence:browser",
             metadata: %{"required_evidence" => ["browser"]}
           }),
         {:ok, [_artifact]} <- collect_milestone4_artifact(project, run) do
      {:ok,
       summary("milestone4", project, opts,
         work_runs: [run],
         dedupe_keys: [run.dedupe_key],
         expected_assertions: [
           "missing browser evidence records blocker",
           "valid evidence artifact persisted with work_run_id",
           "path traversal artifacts rejected by automated tests"
         ]
       )}
    end
  end

  defp do_run("milestone5", opts) do
    with {:ok, project} <- upsert_project(),
         {:ok, runs} <- seed_milestone5_ci_runs(project) do
      {:ok,
       summary("milestone5", project, opts,
         work_runs: runs,
         dedupe_keys: Enum.map(runs, & &1.dedupe_key),
         expected_assertions: [
           "ci_fix work run includes workflow_run and log_excerpt",
           "log_fetch_error variant persisted without crashing",
           "unknown checks do not trigger repair"
         ]
       )}
    end
  end

  defp upsert_project do
    Storage.upsert_project(%{
      slug: @project_slug,
      linear_project_slug: "roadmap-e2e-linear",
      linear_team_key: "COD",
      linear_human_review_state: "Human Review",
      github_owner: "dezet",
      github_repo: "roadmap-e2e",
      github_base_branch: "develop",
      config_version: 1,
      config: %{
        "protected_branches" => ["develop"],
        "required_evidence" => ["browser"]
      }
    })
  end

  defp seed_milestone1_implementation(project) do
    issue = issue("roadmap-e2e-issue", "COD-101", project)

    with {:ok, [run]} <-
           LinearIssueSource.fetch_candidates(
             issue_fetcher: fn -> {:ok, [issue]} end,
             project_id: project.id,
             project_slug: project.slug,
             base_branch: project.github_base_branch,
             config_version: project.config_version,
             required_evidence: []
           ) do
      persist_runtime_run(run, project)
    end
  end

  defp seed_milestone1_pr_observation(project) do
    pr = pull_request(17, "COD-101 roadmap E2E", "abc123", "cod-101-roadmap-e2e", "develop")

    GithubPrSource.fetch_candidates(project,
      list_pull_requests: fn "dezet", "roadmap-e2e", [] -> {:ok, [pr]} end
    )
  end

  defp seed_milestone2_failed_ci(project) do
    Storage.upsert_work_run(%{
      project_id: project.id,
      type: "ci_fix",
      status: "blocked",
      dedupe_key: "github-ci-fix:dezet/roadmap-e2e:18:def456:9001",
      github_owner: "dezet",
      github_repo: "roadmap-e2e",
      github_pr_number: 18,
      github_head_sha: "def456",
      github_head_ref: "cod-201-ci-fix",
      github_base_ref: "develop",
      forge_owner: "dezet",
      forge_repo: "roadmap-e2e",
      forge_pr_number: 18,
      forge_head_sha: "def456",
      forge_head_ref: "cod-201-ci-fix",
      forge_base_ref: "develop",
      linear_issue_id: "roadmap-e2e-m2",
      linear_identifier: "COD-201",
      agent_backend: "codex",
      payload: %{
        "project_id" => project.id,
        "repo_policy" => "repair_branch_required",
        "workflow_run" => %{"id" => 9001, "name" => "CI", "url" => "https://example.test/actions/9001"},
        "blocker_reason" => "unsafe_failed_ci_repair"
      }
    })
  end

  defp seed_implementation_run(project, issue_id, identifier, opts \\ []) do
    required_evidence = Keyword.get(opts, :required_evidence, [])

    Storage.upsert_work_run(%{
      project_id: project.id,
      type: "implementation",
      status: "queued",
      dedupe_key: "linear:#{issue_id}",
      github_owner: project.github_owner,
      github_repo: project.github_repo,
      github_base_ref: project.github_base_branch,
      forge_owner: project.github_owner,
      forge_repo: project.github_repo,
      forge_base_ref: project.github_base_branch,
      linear_issue_id: issue_id,
      linear_identifier: identifier,
      linear_url: "https://linear.test/#{identifier}",
      agent_backend: "codex",
      payload: %{
        "project_id" => project.id,
        "project_slug" => project.slug,
        "config_version" => project.config_version,
        "required_evidence" => required_evidence,
        "issue" => %{"id" => issue_id, "identifier" => identifier, "state" => "In Progress"}
      }
    })
  end

  defp seed_pr_link(project, number, head_ref, base_ref, identifier) do
    Storage.upsert_pull_request_link(%{
      project_id: project.id,
      github_owner: project.github_owner,
      github_repo: project.github_repo,
      github_pr_number: number,
      github_head_sha: "sha-#{number}",
      github_head_ref: head_ref,
      github_base_ref: base_ref,
      forge_owner: project.github_owner,
      forge_repo: project.github_repo,
      forge_pr_number: number,
      forge_head_sha: "sha-#{number}",
      forge_head_ref: head_ref,
      forge_base_ref: base_ref,
      linear_identifier: identifier,
      linear_url: "https://linear.test/#{identifier}",
      metadata: %{"title" => "#{identifier} roadmap E2E"}
    })
  end

  defp collect_milestone4_artifact(project, run) do
    workspace = Path.join(System.tmp_dir!(), "harmony-roadmap-e2e-milestone4-#{project.id}")
    File.mkdir_p!(Path.join(workspace, ".harmony/artifacts"))
    File.write!(Path.join(workspace, ".harmony/artifacts/milestone4.png"), "png")

    File.write!(
      Path.join(workspace, ".harmony/evidence.json"),
      Jason.encode!(%{
        frontend_changed: true,
        scenario: "Roadmap milestone4 browser evidence gate",
        artifacts: [
          %{
            kind: "screenshot",
            path: ".harmony/artifacts/milestone4.png",
            description: "Roadmap evidence screenshot"
          }
        ]
      })
    )

    Collector.collect(project.id, run.id, workspace)
  end

  defp seed_milestone5_ci_runs(project) do
    pr_success = pull_request(20, "COD-501 failed CI", "fedcba", "cod-501-ci", "develop")
    pr_log_error = pull_request(21, "COD-502 failed CI logs", "badlog", "cod-502-ci", "develop")
    pr_unknown = pull_request(22, "COD-503 unknown check", "unknown", "cod-503-ci", "develop")

    workflow_success = %WorkflowRun{
      id: 9002,
      name: "CI",
      head_sha: "fedcba",
      status: "completed",
      conclusion: "failure",
      url: "https://example.test/actions/9002"
    }

    workflow_log_error = %WorkflowRun{
      id: 9003,
      name: "CI",
      head_sha: "badlog",
      status: "completed",
      conclusion: "failure",
      url: "https://example.test/actions/9003"
    }

    workflow_unknown = %WorkflowRun{
      id: 9004,
      name: "Third party",
      head_sha: "unknown",
      status: "completed",
      conclusion: "success",
      url: "https://example.test/actions/9004"
    }

    with {:ok, runs} <-
           GithubFailedCiSource.fetch_candidates(project,
             list_pull_requests: fn "dezet", "roadmap-e2e", [] -> {:ok, [pr_success, pr_log_error, pr_unknown]} end,
             list_workflow_runs: fn
               "dezet", "roadmap-e2e", [head_sha: "fedcba"] -> {:ok, [workflow_success]}
               "dezet", "roadmap-e2e", [head_sha: "badlog"] -> {:ok, [workflow_log_error]}
               "dezet", "roadmap-e2e", [head_sha: "unknown"] -> {:ok, [workflow_unknown]}
             end,
             get_workflow_run_logs: fn
               "dezet", "roadmap-e2e", 9002, [] -> {:ok, "mix test failed in roadmap milestone5"}
               "dezet", "roadmap-e2e", 9003, [] -> {:error, :timeout}
             end,
             dedupe_seen?: fn _project_id, _key -> false end
           ) do
      persist_runtime_runs(runs, project)
    end
  end

  defp persist_runtime_runs(runs, project) do
    Enum.reduce_while(runs, {:ok, []}, fn run, {:ok, acc} ->
      case persist_runtime_run(run, project) do
        {:ok, stored} -> {:cont, {:ok, acc ++ [stored]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp persist_runtime_run(%WorkRun{} = run, project) do
    Storage.upsert_work_run(%{
      project_id: project.id,
      type: run.type,
      status: run.status || "queued",
      dedupe_key: run.dedupe_key,
      github_owner: run.github_owner,
      github_repo: run.github_repo,
      github_pr_number: run.github_pr_number,
      github_head_sha: run.github_head_sha,
      github_head_ref: run.github_head_ref,
      github_base_ref: run.github_base_ref,
      forge_owner: run.forge_owner || run.github_owner,
      forge_repo: run.forge_repo || run.github_repo,
      forge_pr_number: run.forge_pr_number || run.github_pr_number,
      forge_head_sha: run.forge_head_sha || run.github_head_sha,
      forge_head_ref: run.forge_head_ref || run.github_head_ref,
      forge_base_ref: run.forge_base_ref || run.github_base_ref,
      linear_issue_id: run.linear_issue_id,
      linear_identifier: run.linear_identifier,
      linear_url: run.linear_url,
      agent_backend: run.agent_backend || "codex",
      payload:
        run.payload
        |> json_safe()
        |> Map.put("project_id", project.id)
        |> Map.put("project_slug", project.slug)
        |> Map.put_new("required_evidence", run.required_evidence)
    })
  end

  defp to_runtime_work_run(stored_run, project, opts) do
    required_evidence = Keyword.get(opts, :required_evidence, [])

    %WorkRun{
      id: stored_run.id,
      project_slug: project.slug,
      type: stored_run.type,
      status: stored_run.status,
      dedupe_key: stored_run.dedupe_key,
      github_owner: stored_run.github_owner,
      github_repo: stored_run.github_repo,
      github_pr_number: stored_run.github_pr_number,
      github_head_sha: stored_run.github_head_sha,
      github_head_ref: stored_run.github_head_ref,
      github_base_ref: stored_run.github_base_ref,
      linear_issue_id: stored_run.linear_issue_id,
      linear_identifier: stored_run.linear_identifier,
      linear_url: stored_run.linear_url,
      agent_backend: stored_run.agent_backend,
      payload: %{project_id: project.id},
      required_evidence: required_evidence
    }
  end

  defp append_event(project_id, work_run_id, type, payload) do
    Storage.append_event(%{
      project_id: project_id,
      work_run_id: work_run_id,
      type: type,
      payload: payload
    })
  end

  defp append_event_once(project_id, work_run_id, type, payload) do
    if Storage.work_event_exists?(project_id, work_run_id, type) do
      {:ok, :existing}
    else
      append_event(project_id, work_run_id, type, payload)
    end
  end

  defp issue(id, identifier, project) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "#{identifier} roadmap E2E",
      description: "Deterministic roadmap E2E issue",
      state: "In Progress",
      url: "https://linear.test/#{identifier}",
      project_id: project.id,
      project_slug: project.slug,
      labels: [],
      blocked_by: []
    }
  end

  defp pull_request(number, title, head_sha, head_ref, base_ref) do
    %PullRequest{
      number: number,
      title: title,
      body: "#{title}\n\nLinear: https://linear.test/#{linear_identifier(title)}",
      url: "https://github.test/dezet/roadmap-e2e/pull/#{number}",
      head_sha: head_sha,
      head_ref: head_ref,
      head_repo_full_name: "dezet/roadmap-e2e",
      base_ref: base_ref,
      base_repo_full_name: "dezet/roadmap-e2e"
    }
  end

  defp linear_identifier(title) do
    title
    |> String.split(" ")
    |> List.first()
  end

  defp summary(scenario, project, opts, summary_opts) do
    work_runs = Keyword.fetch!(summary_opts, :work_runs)

    %{
      scenario: scenario,
      runtime_url: runtime_url(Keyword.get(opts, :port, @default_port)),
      project_id: project.id,
      project_slug: project.slug,
      work_run_ids: Enum.map(work_runs, & &1.id),
      dedupe_keys: Keyword.fetch!(summary_opts, :dedupe_keys),
      expected_assertions: Keyword.fetch!(summary_opts, :expected_assertions),
      external_network?: false
    }
  end

  defp runtime_url(port) when is_integer(port), do: "http://127.0.0.1:#{port}"
  defp runtime_url(_port), do: "http://127.0.0.1:#{@default_port}"

  defp json_safe(%_struct{} = value), do: value |> Map.from_struct() |> json_safe()

  defp json_safe(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)
  end

  defp json_safe(values) when is_list(values), do: Enum.map(values, &json_safe/1)
  defp json_safe(value), do: value
end
