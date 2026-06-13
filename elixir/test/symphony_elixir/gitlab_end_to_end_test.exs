defmodule SymphonyElixir.GitlabEndToEndTest do
  use SymphonyElixir.TestSupport

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.{Orchestrator, Repo, Storage, Workflow}
  alias SymphonyElixir.Gitlab.MergeRequest
  alias SymphonyElixir.WorkSources.GitlabMrSource

  @tag :db
  test "a gitlab project's open MR flows through the orchestrator poll and persists a PR link" do
    :ok = checkout_repo(%{})

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil
    )

    {:ok, project} =
      Storage.upsert_project(%{
        slug: "gl-demo",
        linear_project_slug: "gl-demo-linear",
        linear_team_key: "ABC",
        linear_human_review_state: "Human Review",
        forge_type: "gitlab",
        forge_owner: "group",
        forge_repo: "api",
        forge_base_branch: "main",
        config_version: 1,
        config: %{}
      })

    mr = %MergeRequest{
      number: 5,
      title: "Fix ABC-1",
      body: "ABC-1",
      head_sha: "abc",
      head_ref: "fix-abc-1",
      base_ref: "main"
    }

    Application.put_env(:symphony_elixir, :project_fetcher, fn -> [project] end)

    Application.put_env(:symphony_elixir, :github_pr_work_source_fetcher, fn proj ->
      GitlabMrSource.fetch_candidates(proj,
        list_merge_requests: fn "group", "api", _ -> {:ok, [mr]} end
      )
    end)

    Application.put_env(:symphony_elixir, :github_ci_work_source_fetcher, fn _ -> {:ok, []} end)
    Application.put_env(:symphony_elixir, :github_review_work_source_fetcher, fn _ -> {:ok, []} end)
    Application.put_env(:symphony_elixir, :linear_work_source_fetcher, fn _ -> {:ok, []} end)

    orchestrator_name = Module.concat(__MODULE__, :GitlabEndToEndOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll_delay_ms: 60_000)
    Sandbox.allow(Repo, self(), pid)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    send(pid, :run_poll_cycle)

    Process.sleep(200)

    links = Storage.list_pull_request_links_for_project(project.id)
    assert Enum.any?(links, &(&1.forge_pr_number == 5 and &1.forge_head_sha == "abc"))
  end

  test "by_forge_type dispatcher routes a gitlab project to the gitlab function" do
    gitlab_called = make_ref()
    parent = self()

    dispatcher =
      Orchestrator.__by_forge_type__(
        fn _proj -> send(parent, :github_called) end,
        fn _proj -> send(parent, {:gitlab_called, gitlab_called}) end
      )

    dispatcher.(%{forge_type: "gitlab", slug: "gl-test"})
    assert_receive {:gitlab_called, ^gitlab_called}, 500

    dispatcher.(%{forge_type: "github", slug: "gh-test"})
    assert_receive :github_called, 500

    dispatcher.(%{slug: "gh-fallback"})
    assert_receive :github_called, 500
  end
end
