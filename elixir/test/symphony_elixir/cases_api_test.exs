defmodule SymphonyElixir.CasesApiTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import SymphonyElixir.CasesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.IntakeCase

  @endpoint SymphonyElixirWeb.Endpoint
  @fixture_root Path.expand("../../assets/src/test/fixtures", __DIR__)
  @query_event [:symphony_elixir, :repo, :query]

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})
    configure_intake(effects_enabled: true)

    start_test_endpoint(
      case_action_opts: [
        analysis_profile: %{model: "synthetic-analysis-model", effort: "medium"},
        refresh_fun: fn -> :ok end
      ]
    )

    :ok
  end

  describe "GET /api/v1/cases" do
    test "returns the shared fixture shape with totals, counts and project sums" do
      scope = scope!(%{ui_color: "gold"})
      ready_case!(scope, %{detected_at: at(1)})
      work_run!(scope.project, %{linear_identifier: "LIN-9", linear_url: "https://linear.example/issue/LIN-9", inserted_at: at(2)})

      body = get(build_conn(), "/api/v1/cases") |> json_response(200)
      fixture = fixture!("cases_page.fixture.json")

      assert keys(body) == keys(fixture)
      assert keys(body["meta"]) == keys(fixture["meta"])
      assert keys(body["counts"]) == keys(fixture["counts"])
      assert keys(hd(body["project_counts"])) == keys(hd(fixture["project_counts"]))

      [jira_item, run_item] = body["items"]
      fixture_jira = hd(fixture["items"])
      fixture_run = Enum.find(fixture["items"], &(&1["kind"] == "agent_work"))

      for {item, expected} <- [{jira_item, fixture_jira}, {run_item, fixture_run}] do
        assert keys(item) == keys(expected)
        assert keys(item["project"]) == keys(expected["project"])
        assert keys(item["priority"]) == keys(expected["priority"])
      end

      assert jira_item["project"] == %{"id" => scope.project.id, "slug" => scope.project.slug, "name" => scope.project.slug, "color" => "gold"}
      assert keys(jira_item["jira"]) == keys(fixture_jira["jira"])
      assert keys(jira_item["linear"]) == keys(fixture_jira["linear"])
      assert run_item["jira"] == nil
      assert run_item["execution_mode"] == "existing_workflow"
      assert body["meta"] == %{"next_cursor" => nil, "total" => 2, "page_size" => 25}
      assert body["project_counts"] == [%{"project_id" => scope.project.id, "total" => 2}]
    end

    test "the case project name is the display name, falling back to the slug" do
      named = scope!(%{display_name: "Finanse", ui_color: "teal"})
      ready_case!(named, %{detected_at: at(1)})

      body = get(build_conn(), "/api/v1/cases") |> json_response(200)
      assert [%{"project" => project}] = body["items"]
      assert project == %{"id" => named.project.id, "slug" => named.project.slug, "name" => "Finanse", "color" => "teal"}
    end

    test "Jira tones of the shared fixture follow a stored Jira ranking" do
      scope = scope!()
      fixture_jira = fixture!("cases_page.fixture.json")["items"] |> Enum.filter(&(&1["kind"] == "jira_intake"))

      for {item, index} <- Enum.with_index(fixture_jira) do
        intake_case!(scope, %{
          priority_ranking: ["1", "2", "3", "4", "5"],
          priority_id: item["priority"]["id"],
          priority_name: item["priority"]["label"],
          detected_at: at(index)
        })
      end

      body = get(build_conn(), "/api/v1/cases") |> json_response(200)
      assert Enum.map(body["items"], & &1["priority"]) == Enum.map(fixture_jira, & &1["priority"])
    end

    test "cursors are stable and bound to the filters that produced them" do
      scope = scope!()
      for index <- 1..30, do: intake_case!(scope, %{detected_at: at(index)})

      first = get(build_conn(), "/api/v1/cases?filter=all&page_size=25") |> json_response(200)
      cursor = first["meta"]["next_cursor"]
      assert is_binary(cursor)
      assert first["meta"]["total"] == 30

      second = get(build_conn(), "/api/v1/cases?filter=all&page_size=25&cursor=#{cursor}") |> json_response(200)
      assert length(second["items"]) == 5
      assert second["meta"]["next_cursor"] == nil
      assert MapSet.disjoint?(refs(first), refs(second))

      other_filter = get(build_conn(), "/api/v1/cases?filter=decision&cursor=#{cursor}")
      assert json_response(other_filter, 400)["error"]["code"] == "invalid_cursor"

      other_query = get(build_conn(), "/api/v1/cases?q=ops&cursor=#{cursor}")
      assert json_response(other_query, 400)["error"]["code"] == "invalid_cursor"

      tampered = Base.url_encode64(Jason.encode!(%{"p" => ["not-a-date", "jira_x"], "s" => "x"}), padding: false)
      assert json_response(get(build_conn(), "/api/v1/cases?cursor=#{tampered}"), 400)["error"]["code"] == "invalid_cursor"
      assert json_response(get(build_conn(), "/api/v1/cases?cursor=%%%"), 400)["error"]["code"] == "invalid_cursor"
    end

    test "rejects malformed query parameters and unknown projects" do
      assert json_response(get(build_conn(), "/api/v1/cases?filter=everything"), 400)["error"]["code"] == "invalid_query"
      assert json_response(get(build_conn(), "/api/v1/cases?column=backlog"), 400)["error"]["code"] == "invalid_query"
      assert json_response(get(build_conn(), "/api/v1/cases?page_size=0"), 400)["error"]["code"] == "invalid_page_size"
      assert json_response(get(build_conn(), "/api/v1/cases?page_size=101"), 400)["error"]["code"] == "invalid_page_size"

      long_query = String.duplicate("a", 201)
      assert json_response(get(build_conn(), "/api/v1/cases?q=#{long_query}"), 400)["error"]["code"] == "invalid_query"
      assert json_response(get(build_conn(), "/api/v1/cases?project=missing-project"), 404)["error"]["code"] == "not_found"
    end

    test "filters by project slug, column and search" do
      scope = scope!()
      other = scope!()
      ready = ready_case!(scope, %{title: "Eksport raportu", detected_at: at(1)}, published?: false)
      intake_case!(scope, %{title: "Eksport faktur", analysis_status: "running", detected_at: at(2)})
      intake_case!(other, %{title: "Eksport HR", detected_at: at(3)})

      body = get(build_conn(), "/api/v1/cases?project=#{scope.project.slug}&q=%20EKSPORT%20&column=decision") |> json_response(200)

      assert Enum.map(body["items"], & &1["ref"]) == ["jira_#{ready.id}"]
      assert body["meta"]["total"] == 1
      assert body["counts"] == %{"all" => 2, "decision" => 1, "analysis" => 1, "done" => 0, "detected" => 0}
    end

    test "a page of 25 cards uses a constant number of queries" do
      scope = scope!()
      ready_case!(scope, %{detected_at: at(1)})
      small = count_queries(fn -> get(build_conn(), "/api/v1/cases?project=#{scope.project.slug}") |> json_response(200) end)

      for index <- 1..20 do
        intake_case = ready_case!(scope, %{detected_at: at(index + 1)})
        delivery!(intake_case, "email", "succeeded")
      end

      for index <- 1..20 do
        work_run!(scope.project, %{linear_issue_id: Ecto.UUID.generate(), inserted_at: at(index + 30)})
      end

      large = count_queries(fn -> get(build_conn(), "/api/v1/cases?project=#{scope.project.slug}") |> json_response(200) end)

      assert small == large
      assert large <= 4
    end
  end

  describe "GET /api/v1/cases/:ref" do
    test "Jira detail matches the T01 fixture shape and exposes backend actions" do
      scope = scope!()
      intake_case = ready_case!(scope)
      delivery!(intake_case, "linear_create", "succeeded")
      delivery!(intake_case, "email", "succeeded")
      delivery!(intake_case, "sms", "succeeded", %{recipient: "+19995550123"})

      body = get(build_conn(), "/api/v1/cases/jira_#{intake_case.id}") |> json_response(200)
      fixture = fixture!("case_detail.fixture.json")

      assert keys(body) == keys(fixture)
      assert keys(body["case"]) == keys(fixture["case"])
      assert keys(body["case"]["rule_snapshot"]) == keys(fixture["case"]["rule_snapshot"])
      assert keys(body["analysis"]) == keys(fixture["analysis"])
      assert keys(body["analysis"]["input_snapshot"]) == keys(fixture["analysis"]["input_snapshot"])
      assert keys(body["analysis"]["result"]) == keys(fixture["analysis"]["result"])
      assert keys(body["links"]) == keys(fixture["links"])
      assert keys(body["publication"]) == keys(fixture["publication"])
      assert Enum.all?(body["deliveries"], &(keys(&1) == keys(hd(fixture["deliveries"]))))
      assert body["actions"] == fixture["actions"]
      assert body["publication"]["status"] == "published"
      assert body["publication"]["marker"] == "Harmony analysis #{intake_case.id}/v1"
      assert body["version"] == intake_case.lock_version

      encoded = Jason.encode!(body)
      refute encoded =~ "oncall@example.test"
      refute encoded =~ "+19995550123"
    end

    test "actions follow the backend rules for every state" do
      scope = scope!()

      approved = ready_case!(scope, %{repair_approved_at: at(-1), repair_approved_version: 1})

      assert actions(approved) == %{
               "acknowledge" => %{"allowed" => true, "reason" => nil},
               "reanalyze" => %{"allowed" => false, "reason" => "repair_already_approved"},
               "approve_repair" => %{"allowed" => false, "reason" => "repair_already_approved"}
             }

      unpublished = ready_case!(scope, %{}, published?: false)
      assert actions(unpublished)["approve_repair"] == %{"allowed" => false, "reason" => "analysis_not_published"}

      unconfirmed = ready_case!(scope, %{linear_confirmed_at: nil})
      assert actions(unconfirmed)["approve_repair"] == %{"allowed" => false, "reason" => "linear_not_confirmed"}

      queued = intake_case!(scope, %{analysis_status: "queued"})
      assert actions(queued)["approve_repair"] == %{"allowed" => false, "reason" => "analysis_not_ready"}

      acknowledged = ready_case!(scope, %{acknowledged_at: at(-1)})
      assert actions(acknowledged)["acknowledge"] == %{"allowed" => false, "reason" => "already_acknowledged"}

      configure_intake(effects_enabled: false)
      assert actions(unpublished)["reanalyze"] == %{"allowed" => false, "reason" => "effects_disabled"}
    end

    test "analysis is null before a result and publication is pending" do
      scope = scope!()
      intake_case = intake_case!(scope, %{analysis_status: "running"})
      analysis!(intake_case, %{status: "running"})

      body = get(build_conn(), "/api/v1/cases/jira_#{intake_case.id}") |> json_response(200)

      assert body["analysis"] == nil
      assert body["publication"]["status"] == "pending"
      assert body["publication"]["comment_id"] == nil
    end

    test "agent work detail has no Jira actions and keeps forge data" do
      %{project: project} = scope!()
      run = work_run!(project, %{type: "ci_fix", status: "failed", forge_owner: "example", forge_repo: "synthetic", forge_pr_number: 12})

      body = get(build_conn(), "/api/v1/cases/run_#{run.id}") |> json_response(200)

      assert body["case"]["kind"] == "agent_work"
      assert body["case"]["work_run"]["forge"]["pr_number"] == 12
      assert body["analysis"] == nil
      assert body["deliveries"] == []
      assert body["links"] == %{"jira" => nil, "linear" => nil}
      assert Enum.all?(body["actions"], fn {_name, action} -> action == %{"allowed" => false, "reason" => "unsupported_case_kind"} end)
    end

    test "unknown or malformed refs are 404" do
      for ref <- ["jira_#{Ecto.UUID.generate()}", "run_#{Ecto.UUID.generate()}", "jira_nope", "nonsense"] do
        assert json_response(get(build_conn(), "/api/v1/cases/#{ref}"), 404)["error"]["code"] == "not_found"
      end
    end
  end

  describe "GET /api/v1/cases/:ref/events" do
    test "pages by 50 with a cursor bound to the case" do
      scope = scope!()
      intake_case = intake_case!(scope)
      other_case = intake_case!(scope)
      sms = delivery!(intake_case, "sms", "failed", %{recipient: "+19995550123"})

      for index <- 1..55 do
        event!(intake_case, "delivery_failed", %{"delivery_id" => sms.id, "error_code" => "synthetic_failure"}, at(-index))
      end

      first = get(build_conn(), "/api/v1/cases/jira_#{intake_case.id}/events") |> json_response(200)
      assert length(first["items"]) == 50
      assert keys(hd(first["items"])) == ~w(actor id occurred_at operation payload recipient type)
      assert hd(first["items"])["recipient"] == "+19******123"
      refute Jason.encode!(first) =~ "+19995550123"

      cursor = first["meta"]["next_cursor"]
      second = get(build_conn(), "/api/v1/cases/jira_#{intake_case.id}/events?cursor=#{cursor}") |> json_response(200)
      assert length(second["items"]) == 5
      assert second["meta"]["next_cursor"] == nil

      foreign = get(build_conn(), "/api/v1/cases/jira_#{other_case.id}/events?cursor=#{cursor}")
      assert json_response(foreign, 400)["error"]["code"] == "invalid_cursor"
    end

    test "agent work history comes from work events" do
      %{project: project} = scope!()
      run = work_run!(project)
      work_event!(run, "turn_started", %{"turn" => 1}, at(-1))

      body = get(build_conn(), "/api/v1/cases/run_#{run.id}/events") |> json_response(200)

      assert [%{"type" => "turn_started", "actor" => "system", "operation" => nil, "recipient" => nil}] = body["items"]
    end
  end

  test "wrong methods on the case read routes return 405" do
    id = Ecto.UUID.generate()

    for {method, path} <- [{:delete, "/api/v1/cases"}, {:put, "/api/v1/cases/jira_#{id}"}, {:post, "/api/v1/cases/jira_#{id}/events"}] do
      conn = dispatch(build_conn(), @endpoint, method, path, nil)
      assert json_response(conn, 405)["error"]["code"] == "method_not_allowed", "#{method} #{path}"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp actions(%IntakeCase{id: id}) do
    get(build_conn(), "/api/v1/cases/jira_#{id}") |> json_response(200) |> Map.fetch!("actions")
  end

  defp refs(page), do: MapSet.new(page["items"], & &1["ref"])

  defp keys(map) when is_map(map), do: map |> Map.keys() |> Enum.sort()

  defp fixture!(name), do: @fixture_root |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp count_queries(fun) do
    test_pid = self()
    handler = "cases-query-count-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        @query_event,
        fn _event, _measurements, _metadata, _config -> if self() == test_pid, do: send(test_pid, :repo_query) end,
        nil
      )

    try do
      fun.()
      drain_queries(0)
    after
      :telemetry.detach(handler)
    end
  end

  defp drain_queries(count) do
    receive do
      :repo_query -> drain_queries(count + 1)
    after
      0 -> count
    end
  end

  defp configure_intake(opts) do
    write_workflow_file!(Workflow.workflow_file_path(),
      intake_enabled: true,
      intake_effects_enabled: Keyword.fetch!(opts, :effects_enabled),
      intake_public_url: "https://harmony.example.test"
    )
  end

  defp start_test_endpoint(adapters) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), intake_adapters: adapters)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    on_exit(fn -> Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, Keyword.delete(endpoint_config, :intake_adapters)) end)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
