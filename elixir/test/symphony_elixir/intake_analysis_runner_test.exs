defmodule SymphonyElixir.IntakeAnalysisRunnerTest do
  use SymphonyElixir.TestSupport

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Intake.{AnalysisRunner, Dispatcher, Outbox}
  alias SymphonyElixir.Repo

  alias SymphonyElixir.Storage.{
    AutomationRule,
    IntakeEvent,
    IntakeAnalysis,
    IntakeCase,
    IntegrationConnection,
    IntegrationDelivery,
    Project,
    WorkRun
  }

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "a valid analysis is run once when Jira comment publication times out" do
    {project, connection, intake_case, analysis_delivery} = analysis_fixture!()
    parent = self()
    forge_token = "SYNTHETIC-FORGE-TOKEN-CANARY"

    model_fun = fn snapshot_path, prompt, issue, opts ->
      assert :ok = opts[:heartbeat_fun].()
      send(parent, {:analysis_started, snapshot_path, prompt, issue, opts})

      {:ok,
       %{
         result: Jason.encode!(valid_result(intake_case.jira_key)),
         usage: %{"input_tokens" => 9, "output_tokens" => 4},
         model: "synthetic-model",
         effort: "medium"
       }}
    end

    context_fun = fn _workspace_root, _case_id, _version, _project ->
      {:ok,
       %{
         path: Path.join(System.tmp_dir!(), "synthetic-analysis-snapshot"),
         input_snapshot: %{
           "context_scope" => "issue_only",
           "context_reason" => "repository_not_configured"
         }
       }}
    end

    analysis_opts = [
      context_fun: context_fun,
      model_fun: model_fun,
      workspace_root: System.tmp_dir!(),
      timeout_ms: 1_000
    ]

    assert {:ok, completed_analysis_delivery} =
             Dispatcher.dispatch_one(claim_opts(operation: "analysis", analysis_opts: analysis_opts))

    assert completed_analysis_delivery.status == "succeeded"
    assert completed_analysis_delivery.id == analysis_delivery.id
    assert_receive {:analysis_started, _snapshot_path, prompt, issue, model_opts}
    assert is_integer(model_opts[:deadline_ms])
    refute Keyword.has_key?(model_opts, :forge_token)
    refute inspect({prompt, issue, model_opts}) =~ forge_token

    comment_delivery =
      Repo.get_by!(IntegrationDelivery,
        case_id: intake_case.id,
        operation: "jira_comment"
      )

    request_fun = fn request ->
      send(parent, {:jira_request, request[:method], request[:url]})

      case request[:method] do
        :get ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "startAt" => 0,
               "maxResults" => 100,
               "total" => 0,
               "isLast" => true,
               "comments" => []
             }
           }}

        :post ->
          {:error, :timeout}
      end
    end

    assert {:unknown, unknown_comment_delivery} =
             Dispatcher.dispatch_one(claim_opts(operation: "jira_comment", jira_comment_opts: [request_fun: request_fun]))

    assert unknown_comment_delivery.id == comment_delivery.id
    assert unknown_comment_delivery.status == "unknown"
    assert_receive {:jira_request, :get, _url}
    assert_receive {:jira_request, :post, _url}
    assert_receive {:jira_request, :get, _url}
    refute_receive {:jira_request, :post, _url}, 50

    analysis = Repo.get_by!(IntakeAnalysis, case_id: intake_case.id, version: 1)
    assert analysis.status == "succeeded"
    assert analysis.input_snapshot["context_scope"] == "issue_only"
    assert analysis.input_snapshot["context_reason"] == "repository_not_configured"
    assert analysis.result["summary"] == "Issue-only finding"
    assert analysis.token_usage == %{"input_tokens" => 9, "output_tokens" => 4}
    work_run = Repo.get!(SymphonyElixir.Storage.WorkRun, analysis.work_run_id)
    assert work_run.type == "jira_analysis"
    assert work_run.status == "succeeded"
    assert work_run.payload["token_usage"] == analysis.token_usage
    assert :empty = Dispatcher.dispatch_one(claim_opts(operation: "jira_comment"))
    refute_receive {:analysis_started, _, _, _, _}, 50

    assert Repo.get!(Project, project.id).id == project.id
    assert Repo.get!(IntegrationConnection, connection.id).secret == "synthetic-jira-token"
  end

  test "cleans the exact snapshot after successful and aborted model attempts" do
    workspace_root = Path.join(System.tmp_dir!(), "runner-cleanup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf(workspace_root) end)

    {_project, _connection, intake_case, _delivery} = analysis_fixture!()
    snapshot_path = Path.join([workspace_root, "intake", intake_case.id, "1"])

    context_fun = fn _root, case_id, version, _project ->
      path = Path.join([workspace_root, "intake", case_id, Integer.to_string(version)])
      File.mkdir_p!(path)
      File.write!(Path.join(path, "synthetic.ex"), "synthetic")

      {:ok,
       %{
         path: path,
         input_snapshot: %{
           "context_scope" => "issue_only",
           "context_reason" => "repository_not_configured"
         }
       }}
    end

    assert {:ok, _delivery} =
             Dispatcher.dispatch_one(
               claim_opts(
                 operation: "analysis",
                 analysis_opts: [
                   workspace_root: workspace_root,
                   context_fun: context_fun,
                   model_fun: fn _path, _prompt, _issue, _opts ->
                     {:ok, %{result: Jason.encode!(valid_result(intake_case.jira_key))}}
                   end
                 ]
               )
             )

    refute File.exists?(snapshot_path)

    {_project, _connection, failed_case, _delivery} = analysis_fixture!()
    failed_snapshot_path = Path.join([workspace_root, "intake", failed_case.id, "1"])

    raw_stdout = "RAW-STDOUT-CANARY"

    assert {:failed, failed_delivery} =
             Dispatcher.dispatch_one(
               claim_opts(
                 operation: "analysis",
                 analysis_opts: [
                   workspace_root: workspace_root,
                   context_fun: context_fun,
                   model_fun: fn _path, _prompt, _issue, _opts -> {:ok, %{result: raw_stdout}} end
                 ]
               )
             )

    refute File.exists?(failed_snapshot_path)
    failed_analysis = Repo.get_by!(IntakeAnalysis, case_id: failed_case.id, version: 1)
    assert failed_analysis.status == "failed"
    assert failed_analysis.error_code == "invalid_json"
    refute failed_analysis.result
    refute inspect(failed_analysis) =~ raw_stdout
    refute Repo.get_by(IntegrationDelivery, case_id: failed_case.id, operation: "jira_comment")
    failed_work_run = Repo.get!(SymphonyElixir.Storage.WorkRun, failed_analysis.work_run_id)
    refute inspect(failed_work_run.payload) =~ raw_stdout
    assert {:error, :analysis_retry_requires_new_version} = Outbox.manual_retry(failed_delivery.id, now: now())
  end

  test "a snapshot cleanup error fails the analysis without starting another model attempt" do
    {_project, _connection, intake_case, _delivery} = analysis_fixture!()
    parent = self()

    assert {:failed, failed_delivery} =
             Dispatcher.dispatch_one(
               fn claimed ->
                 AnalysisRunner.perform(
                   claimed,
                   workspace_root: System.tmp_dir!(),
                   context_fun: fn _root, _case_id, _version, _project ->
                     {:ok,
                      %{
                        path: Path.join(System.tmp_dir!(), "cleanup-error-snapshot"),
                        input_snapshot: %{"context_scope" => "issue_only"}
                      }}
                   end,
                   model_fun: fn _path, _prompt, _issue, _opts ->
                     send(parent, :cleanup_error_model_started)
                     {:ok, %{result: Jason.encode!(valid_result(intake_case.jira_key))}}
                   end,
                   cleanup_fun: fn _root, _case_id, _version -> {:error, :synthetic_cleanup_failed} end
                 )
               end,
               claim_opts(operation: "analysis")
             )

    assert_receive :cleanup_error_model_started
    assert failed_delivery.status == "failed"
    assert failed_delivery.last_error_code == "analysis_snapshot_cleanup_failed"

    analysis = Repo.get_by!(IntakeAnalysis, case_id: intake_case.id, version: 1)
    assert analysis.status == "failed"
    assert analysis.error_code == "analysis_snapshot_cleanup_failed"
    refute analysis.result

    work_run = Repo.get!(WorkRun, analysis.work_run_id)
    assert work_run.status == "failed"
    assert work_run.payload["error_code"] == "analysis_snapshot_cleanup_failed"
    assert :empty = Dispatcher.dispatch_one(claim_opts(operation: "analysis"))
    refute Repo.get_by(IntegrationDelivery, case_id: intake_case.id, operation: "jira_comment")

    event = Repo.get_by!(IntakeEvent, case_id: intake_case.id, type: "analysis_failed")
    assert event.payload["error_code"] == "analysis_snapshot_cleanup_failed"
  end

  test "a snapshot cleanup exception is reported as a terminal analysis failure" do
    {_project, _connection, intake_case, _delivery} = analysis_fixture!()
    parent = self()

    assert {:failed, failed_delivery} =
             Dispatcher.dispatch_one(
               fn claimed ->
                 AnalysisRunner.perform(
                   claimed,
                   workspace_root: System.tmp_dir!(),
                   context_fun: fn _root, _case_id, _version, _project ->
                     {:ok,
                      %{
                        path: Path.join(System.tmp_dir!(), "cleanup-exception-snapshot"),
                        input_snapshot: %{"context_scope" => "issue_only"}
                      }}
                   end,
                   model_fun: fn _path, _prompt, _issue, _opts ->
                     send(parent, :cleanup_exception_model_started)
                     {:ok, %{result: Jason.encode!(valid_result(intake_case.jira_key))}}
                   end,
                   cleanup_fun: fn _root, _case_id, _version -> raise "synthetic cleanup exception" end
                 )
               end,
               claim_opts(operation: "analysis")
             )

    assert_receive :cleanup_exception_model_started
    assert failed_delivery.status == "failed"
    assert failed_delivery.last_error_code == "analysis_snapshot_cleanup_failed"
    analysis = Repo.get_by!(IntakeAnalysis, case_id: intake_case.id, version: 1)
    assert analysis.status == "failed"
    assert analysis.error_code == "analysis_snapshot_cleanup_failed"
    refute analysis.result
    assert :empty = Dispatcher.dispatch_one(claim_opts(operation: "analysis"))
    refute Repo.get_by(IntegrationDelivery, case_id: intake_case.id, operation: "jira_comment")
  end

  test "does not start analysis before Linear confirmation" do
    {_project, _connection, intake_case, _delivery} = analysis_fixture!()

    intake_case
    |> IntakeCase.changeset(%{linear_confirmed_at: nil})
    |> Repo.update!()

    assert :empty =
             Dispatcher.dispatch_one(
               claim_opts(
                 operation: "analysis",
                 analysis_opts: [
                   model_fun: fn _path, _prompt, _issue, _opts -> flunk("unconfirmed Linear must not start a model") end
                 ]
               )
             )

    analysis = Repo.get_by!(IntakeAnalysis, case_id: intake_case.id, version: 1)
    assert analysis.status == "queued"
    assert is_nil(analysis.work_run_id)
    refute Repo.get_by(SymphonyElixir.Storage.WorkRun, project_id: intake_case.project_id)
  end

  test "a late result after lease loss cannot persist an analysis or comment" do
    {_project, _connection, intake_case, _delivery} = analysis_fixture!()

    assert {:error, :stale_lease} =
             Dispatcher.dispatch_one(
               fn claimed ->
                 AnalysisRunner.perform(
                   claimed,
                   workspace_root: System.tmp_dir!(),
                   context_fun: fn _root, _case_id, _version, _project ->
                     {:ok,
                      %{
                        path: Path.join(System.tmp_dir!(), "stale-lease-snapshot"),
                        input_snapshot: %{"context_scope" => "issue_only"}
                      }}
                   end,
                   model_fun: fn _path, _prompt, _issue, _opts ->
                     assert {:ok, _failed} =
                              Outbox.fail(claimed.id, claimed.lease_token, "synthetic_lease_loss", now: now())

                     {:ok, %{result: Jason.encode!(valid_result(intake_case.jira_key))}}
                   end
                 )
               end,
               claim_opts(operation: "analysis")
             )

    analysis = Repo.get_by!(IntakeAnalysis, case_id: intake_case.id, version: 1)
    assert analysis.status == "failed"
    assert analysis.error_code == "stale_lease"
    refute analysis.result
    refute Repo.get_by(IntegrationDelivery, case_id: intake_case.id, operation: "jira_comment")
    work_run = Repo.get!(SymphonyElixir.Storage.WorkRun, analysis.work_run_id)
    assert work_run.status == "failed"
  end

  test "an old work run cannot fail a newer lease for the same analysis version" do
    {_project, _connection, intake_case, _delivery} = analysis_fixture!()
    parent = self()

    assert {:error, :stale_lease} =
             Dispatcher.dispatch_one(
               fn claimed ->
                 AnalysisRunner.perform(
                   claimed,
                   workspace_root: System.tmp_dir!(),
                   context_fun: fn _root, _case_id, _version, _project ->
                     {:ok,
                      %{
                        path: Path.join(System.tmp_dir!(), "same-version-retry-snapshot"),
                        input_snapshot: %{"context_scope" => "issue_only"}
                      }}
                   end,
                   model_fun: fn _path, _prompt, _issue, _opts ->
                     new_token = Ecto.UUID.generate()
                     current_delivery = Repo.get!(IntegrationDelivery, claimed.id)

                     current_delivery
                     |> IntegrationDelivery.changeset(%{
                       lease_token: new_token,
                       lease_until: DateTime.add(now(), 120, :second),
                       attempts: 2
                     })
                     |> Repo.update!()

                     new_work_run =
                       %WorkRun{}
                       |> WorkRun.changeset(%{
                         project_id: intake_case.project_id,
                         type: "jira_analysis",
                         status: "running",
                         dedupe_key: "intake:#{intake_case.id}:jira_analysis:v1:attempt2",
                         linear_issue_id: intake_case.linear_issue_id,
                         linear_identifier: intake_case.linear_identifier,
                         linear_url: intake_case.linear_url,
                         agent_backend: "codex",
                         payload: %{"case_id" => intake_case.id, "analysis_version" => 1, "attempt" => 2}
                       })
                       |> Repo.insert!()

                     Repo.get_by!(IntakeAnalysis, case_id: intake_case.id, version: 1)
                     |> IntakeAnalysis.changeset(%{status: "running", work_run_id: new_work_run.id})
                     |> Repo.update!()

                     send(parent, {:new_same_version_work_run, new_work_run.id})
                     {:ok, %{result: Jason.encode!(valid_result(intake_case.jira_key))}}
                   end
                 )
               end,
               claim_opts(operation: "analysis")
             )

    assert_receive {:new_same_version_work_run, new_work_run_id}
    analysis = Repo.get_by!(IntakeAnalysis, case_id: intake_case.id, version: 1)
    assert analysis.status == "running"
    assert analysis.work_run_id == new_work_run_id
    assert Repo.get!(WorkRun, new_work_run_id).status == "running"
  end

  test "a late version-one result leaves the active version-two analysis untouched" do
    {_project, _connection, intake_case, _delivery} = analysis_fixture!()

    assert {:failed, failed_delivery} =
             Dispatcher.dispatch_one(
               fn claimed ->
                 AnalysisRunner.perform(
                   claimed,
                   workspace_root: System.tmp_dir!(),
                   context_fun: fn _root, _case_id, _version, _project ->
                     {:ok,
                      %{
                        path: Path.join(System.tmp_dir!(), "stale-version-snapshot"),
                        input_snapshot: %{"context_scope" => "issue_only"}
                      }}
                   end,
                   model_fun: fn _path, _prompt, _issue, _opts ->
                     current_case = Repo.get!(IntakeCase, intake_case.id)

                     current_case
                     |> IntakeCase.changeset(%{analysis_version: 2, analysis_status: "queued"})
                     |> Repo.update!()

                     %IntakeAnalysis{}
                     |> IntakeAnalysis.changeset(%{
                       case_id: intake_case.id,
                       version: 2,
                       status: "queued",
                       input_snapshot: %{"context_scope" => "issue_only"},
                       model: "synthetic-model",
                       effort: "medium"
                     })
                     |> Repo.insert!()

                     {:ok, %{result: Jason.encode!(valid_result(intake_case.jira_key))}}
                   end
                 )
               end,
               claim_opts(operation: "analysis")
             )

    assert failed_delivery.last_error_code == "stale_analysis_version"
    assert Repo.get!(IntakeCase, intake_case.id).analysis_version == 2
    old_analysis = Repo.get_by!(IntakeAnalysis, case_id: intake_case.id, version: 1)
    new_analysis = Repo.get_by!(IntakeAnalysis, case_id: intake_case.id, version: 2)
    assert old_analysis.status == "failed"
    refute old_analysis.result
    assert new_analysis.status == "queued"
    refute new_analysis.result
    refute Repo.get_by(IntegrationDelivery, case_id: intake_case.id, operation: "jira_comment")
  end

  defp analysis_fixture! do
    timestamp = now()

    connection =
      %IntegrationConnection{}
      |> IntegrationConnection.changeset(%{
        kind: "jira_cloud",
        name: "Analysis Jira #{System.unique_integer([:positive])}",
        settings: %{
          auth_mode: "classic",
          account_email: "harmony@example.test",
          site_url: "https://analysis-#{System.unique_integer([:positive])}.atlassian.net"
        },
        secret: "synthetic-jira-token",
        enabled: true,
        health: "ok"
      })
      |> Repo.insert!()

    project =
      %Project{}
      |> Project.changeset(%{
        slug: "analysis-runner-#{System.unique_integer([:positive])}",
        forge_owner: "synthetic-owner",
        forge_repo: "synthetic-repo",
        forge_base_branch: "main",
        forge_type: "github",
        config: %{},
        config_version: 1
      })
      |> Repo.insert!()

    forge_token = "SYNTHETIC-FORGE-TOKEN-CANARY"

    project =
      project
      |> Project.secret_changeset(%{forge_secret: forge_token})
      |> Repo.update!()

    rule =
      %AutomationRule{}
      |> AutomationRule.changeset(%{
        project_id: project.id,
        jira_connection_id: connection.id,
        name: "Analysis runner rule",
        source_type: "board",
        source_id: "42",
        priority_ids: ["1"],
        interval_seconds: 300,
        initial_policy: "new_matches_only",
        linear_team_id: "11111111-1111-4111-8111-111111111111",
        linear_project_id: "22222222-2222-4222-8222-222222222222",
        linear_todo_state_id: "33333333-3333-4333-8333-333333333333",
        linear_hold_label_id: "44444444-4444-4444-8444-444444444444",
        email_recipients: [],
        sms_recipients: []
      })
      |> Repo.insert!()

    intake_case =
      %IntakeCase{}
      |> IntakeCase.changeset(%{
        project_id: project.id,
        rule_id: rule.id,
        jira_connection_id: connection.id,
        jira_issue_id: "10001",
        jira_key: "OPS-42",
        jira_url: "https://analysis.atlassian.net/browse/OPS-42",
        title: "Analysis case",
        description_text: "Synthetic issue description",
        priority_id: "1",
        priority_name: "Highest",
        jira_updated_at: timestamp,
        detected_at: timestamp,
        rule_snapshot: %{},
        linear_issue_id: Ecto.UUID.generate(),
        linear_identifier: "LIN-42",
        linear_url: "https://linear.app/acme/issue/LIN-42",
        linear_state_name: "Todo",
        linear_confirmed_at: timestamp,
        analysis_version: 1,
        analysis_status: "queued",
        lock_version: 1
      })
      |> Repo.insert!()

    %IntakeAnalysis{}
    |> IntakeAnalysis.changeset(%{
      case_id: intake_case.id,
      version: 1,
      status: "queued",
      input_snapshot: %{
        "case_ref" => "jira_#{intake_case.id}",
        "jira_key" => intake_case.jira_key,
        "title" => intake_case.title,
        "description_text" => intake_case.description_text,
        "priority_name" => intake_case.priority_name,
        "rule_snapshot" => %{}
      },
      model: "synthetic-model",
      effort: "medium"
    })
    |> Repo.insert!()

    analysis_delivery =
      %IntegrationDelivery{}
      |> IntegrationDelivery.changeset(%{
        case_id: intake_case.id,
        operation: "analysis",
        dedupe_key: "case:#{intake_case.id}:analysis:1",
        payload: %{"version" => 1},
        status: "pending",
        attempts: 0,
        next_attempt_at: timestamp,
        lock_version: 1
      })
      |> Repo.insert!()

    {project, connection, intake_case, analysis_delivery}
  end

  defp valid_result(jira_key) do
    %{
      summary: "Issue-only finding",
      facts: [%{text: "A synthetic Jira fact", source: "jira:#{jira_key}"}],
      hypotheses: [],
      missing_data: [],
      next_steps: ["Collect a synthetic log"],
      needs_input: false,
      context_scope: "issue_only"
    }
  end

  defp claim_opts(overrides) do
    Keyword.merge(
      [
        now: now(),
        intake_enabled: true,
        effects_enabled: true,
        analysis_enabled: true,
        jitter: fn -> 0.0 end
      ],
      overrides
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
