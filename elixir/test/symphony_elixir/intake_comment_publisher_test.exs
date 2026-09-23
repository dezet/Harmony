defmodule SymphonyElixir.IntakeCommentPublisherTest do
  use SymphonyElixir.TestSupport

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Intake.{CommentPublisher, Dispatcher}
  alias SymphonyElixir.Repo

  alias SymphonyElixir.Storage.{
    AutomationRule,
    IntakeAnalysis,
    IntakeCase,
    IntakeEvent,
    IntegrationConnection,
    IntegrationDelivery,
    Project
  }

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "reconciles a marker found on a later Jira comments page without another POST" do
    {_project, _connection, intake_case, delivery} = comment_fixture!()
    parent = self()
    marker = "Harmony analysis #{intake_case.id}/v1"

    request_fun = fn request ->
      send(parent, {:jira_request, request[:method], request[:params][:startAt]})
      assert request[:params][:expand] == "properties"

      case request[:params][:startAt] do
        0 ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "startAt" => 0,
               "maxResults" => 100,
               "total" => 101,
               "isLast" => false,
               "comments" => [%{"id" => "older", "body" => %{"type" => "doc", "content" => []}}]
             }
           }}

        100 ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "startAt" => 100,
               "maxResults" => 100,
               "total" => 101,
               "isLast" => true,
               "comments" => [
                 %{
                   "id" => "already-published",
                   "body" => %{
                     "version" => 1,
                     "type" => "doc",
                     "content" => [
                       %{
                         "type" => "paragraph",
                         "content" => [%{"type" => "text", "text" => marker}]
                       }
                     ]
                   }
                 }
               ]
             }
           }}
      end
    end

    assert {:ok, completed} =
             Dispatcher.dispatch_one(
               fn claimed -> CommentPublisher.perform(claimed, request_fun: request_fun) end,
               claim_opts()
             )

    assert completed.id == delivery.id
    assert completed.status == "succeeded"
    assert completed.provider_id == "already-published"
    assert_receive {:jira_request, :get, 0}
    assert_receive {:jira_request, :get, 100}
    refute_receive {:jira_request, :post, _offset}, 50
  end

  test "does not publish when reading Jira comments is forbidden" do
    {_project, _connection, _intake_case, delivery} = comment_fixture!()
    parent = self()

    request_fun = fn request ->
      send(parent, {:jira_read_method, request[:method]})
      {:ok, %Req.Response{status: 403, body: %{"message" => "forbidden"}}}
    end

    assert {:failed, failed} =
             Dispatcher.dispatch_one(
               fn claimed -> CommentPublisher.perform(claimed, request_fun: request_fun) end,
               claim_opts()
             )

    assert failed.id == delivery.id
    assert failed.last_error_code == "jira_read_permission_denied"
    assert_receive {:jira_read_method, :get}
    refute_receive {:jira_read_method, :post}, 50
  end

  test "preserves Retry-After from Jira comment reads without attempting a POST" do
    {_project, _connection, _intake_case, _delivery} = comment_fixture!()
    claim_time = now()
    parent = self()

    request_fun = fn request ->
      send(parent, {:jira_read_method, request[:method]})

      {:ok,
       %Req.Response{
         status: 429,
         headers: %{"retry-after" => ["41"]},
         body: %{"message" => "rate limited"}
       }}
    end

    assert {:retry_wait, retried} =
             Dispatcher.dispatch_one(
               fn claimed -> CommentPublisher.perform(claimed, request_fun: request_fun) end,
               claim_opts(now: claim_time)
             )

    assert retried.last_error_code == "jira_rate_limited"
    assert DateTime.diff(retried.next_attempt_at, claim_time, :second) == 41
    assert_receive {:jira_read_method, :get}
    refute_receive {:jira_read_method, :post}, 50
  end

  test "treats a forbidden comment POST as terminal and does not reconcile it" do
    {_project, _connection, intake_case, delivery} = comment_fixture!()
    parent = self()

    request_fun = fn request ->
      send(parent, {:jira_post_method, request[:method]})

      case request[:method] do
        :get ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{"startAt" => 0, "maxResults" => 100, "total" => 0, "isLast" => true, "comments" => []}
           }}

        :post ->
          {:ok, %Req.Response{status: 403, body: %{"message" => "forbidden"}}}
      end
    end

    assert {:failed, failed} =
             Dispatcher.dispatch_one(
               fn claimed -> CommentPublisher.perform(claimed, request_fun: request_fun) end,
               claim_opts()
             )

    assert failed.id == delivery.id
    assert failed.last_error_code == "jira_comment_permission_denied"
    assert_receive {:jira_post_method, :get}
    assert_receive {:jira_post_method, :post}
    refute_receive {:jira_post_method, :get}, 50

    assert Repo.exists?(
             from(event in IntakeEvent,
               where:
                 event.case_id == ^intake_case.id and event.type == "jira_comment_post_started" and
                   event.payload["delivery_id"] == ^delivery.id
             )
           )
  end

  test "returns unknown when an accepted POST cannot be reconciled" do
    {_project, _connection, _intake_case, delivery} = comment_fixture!()
    parent = self()

    request_fun = fn request ->
      send(parent, {:jira_request_method, request[:method]})

      case request[:method] do
        :get ->
          if Process.get(:ambiguous_comment_post_sent, false) do
            {:ok, %Req.Response{status: 503, body: %{"message" => "unavailable"}}}
          else
            {:ok,
             %Req.Response{
               status: 200,
               body: %{"startAt" => 0, "maxResults" => 100, "total" => 0, "isLast" => true, "comments" => []}
             }}
          end

        :post ->
          Process.put(:ambiguous_comment_post_sent, true)
          {:ok, %Req.Response{status: 500, body: %{"message" => "unknown outcome"}}}
      end
    end

    assert {:unknown, unknown} =
             Dispatcher.dispatch_one(
               fn claimed -> CommentPublisher.perform(claimed, request_fun: request_fun) end,
               claim_opts()
             )

    assert unknown.id == delivery.id
    assert unknown.last_error_code == "jira_comment_outcome_unknown"
    assert unknown.status == "unknown"
    assert_receive {:jira_request_method, :get}
    assert_receive {:jira_request_method, :post}
    assert_receive {:jira_request_method, :get}
    refute_receive {:jira_request_method, :post}, 50
  end

  test "does not post again when Jira finds the marker but omits the comment ID" do
    {_project, _connection, intake_case, delivery} = comment_fixture!()
    parent = self()
    marker = "Harmony analysis #{intake_case.id}/v1"

    request_fun = fn request ->
      send(parent, {:jira_marker_method, request[:method]})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "startAt" => 0,
           "maxResults" => 100,
           "total" => 1,
           "isLast" => true,
           "comments" => [%{"body" => marker}]
         }
       }}
    end

    assert {:unknown, unknown} =
             Dispatcher.dispatch_one(
               fn claimed -> CommentPublisher.perform(claimed, request_fun: request_fun) end,
               claim_opts()
             )

    assert unknown.id == delivery.id
    assert unknown.last_error_code == "jira_comment_marker_found_without_id"
    assert_receive {:jira_marker_method, :get}
    refute_receive {:jira_marker_method, :post}, 50
  end

  test "keeps an ambiguous publish unknown when reconciliation finds a marker without an ID" do
    {_project, _connection, intake_case, delivery} = comment_fixture!()
    parent = self()
    marker = "Harmony analysis #{intake_case.id}/v1"
    request_count_key = {:ambiguous_marker_reads, make_ref()}

    request_fun = fn request ->
      send(parent, {:ambiguous_marker_method, request[:method]})

      case request[:method] do
        :get ->
          reads = Process.get(request_count_key, 0) + 1
          Process.put(request_count_key, reads)

          comments = if reads == 1, do: [], else: [%{"body" => marker}]

          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "startAt" => 0,
               "maxResults" => 100,
               "total" => length(comments),
               "isLast" => true,
               "comments" => comments
             }
           }}

        :post ->
          {:ok, %Req.Response{status: 201, body: %{}}}
      end
    end

    assert {:unknown, unknown} =
             Dispatcher.dispatch_one(
               fn claimed -> CommentPublisher.perform(claimed, request_fun: request_fun) end,
               claim_opts()
             )

    assert unknown.id == delivery.id
    assert unknown.last_error_code == "jira_comment_marker_found_without_id"
    assert Process.get(request_count_key) == 2
    assert_receive {:ambiguous_marker_method, :get}
    assert_receive {:ambiguous_marker_method, :post}
    assert_receive {:ambiguous_marker_method, :get}
    refute_receive {:ambiguous_marker_method, :post}, 50
  end

  test "preflight and read guards stop publication before a POST" do
    {_project, connection, intake_case, delivery} = comment_fixture!()
    request_fun = fn _request -> flunk("invalid local state must not call Jira") end
    analysis = Repo.get_by!(IntakeAnalysis, case_id: intake_case.id, version: 1)

    assert {:error, "analysis_result_not_ready"} =
             CommentPublisher.perform(%{delivery | payload: %{"version" => 0}}, request_fun: request_fun)

    assert {:error, "analysis_result_not_ready"} =
             CommentPublisher.perform(%{delivery | payload: %{"version" => 99}}, request_fun: request_fun)

    failed_analysis =
      analysis
      |> IntakeAnalysis.changeset(%{status: "failed"})
      |> Repo.update!()

    assert {:error, "analysis_result_not_ready"} =
             CommentPublisher.perform(delivery, request_fun: request_fun)

    failed_analysis
    |> IntakeAnalysis.changeset(%{status: "succeeded"})
    |> Repo.update!()

    disabled_connection =
      connection
      |> IntegrationConnection.changeset(%{enabled: false})
      |> Repo.update!()

    assert {:error, "jira_connection_unavailable"} =
             CommentPublisher.perform(delivery, request_fun: request_fun)

    disabled_connection
    |> IntegrationConnection.changeset(%{enabled: true})
    |> Repo.update!()

    assert {:error, "jira_comment_read_rejected"} =
             CommentPublisher.perform(delivery,
               request_fun: fn request ->
                 assert request[:method] == :get
                 {:ok, %Req.Response{status: 404, body: %{"message" => "issue not found"}}}
               end
             )
  end

  test "reconciles marker properties and safe-to-retry reads through the public reconciler" do
    {_project, _connection, intake_case, delivery} = comment_fixture!()
    marker = "Harmony analysis #{intake_case.id}/v1"

    assert :already_applied =
             CommentPublisher.reconcile(delivery,
               request_fun: fn _request ->
                 {:ok,
                  %Req.Response{
                    status: 200,
                    body: %{
                      "startAt" => 0,
                      "maxResults" => 100,
                      "total" => 1,
                      "isLast" => true,
                      "comments" => [
                        %{
                          "id" => "property-map-marker",
                          "body" => %{},
                          "properties" => %{"harmony.analysis" => %{"value" => marker}}
                        }
                      ]
                    }
                  }}
               end
             )

    assert :safe_to_retry =
             CommentPublisher.reconcile(delivery,
               request_fun: fn _request ->
                 {:ok,
                  %Req.Response{
                    status: 200,
                    body: %{"startAt" => 0, "maxResults" => 100, "total" => 0, "isLast" => true, "comments" => []}
                  }}
               end
             )
  end

  test "posts deterministic text-only ADF and a version marker property once" do
    {_project, intake_connection, intake_case, delivery} = comment_fixture!()
    parent = self()

    request_fun = fn request ->
      send(parent, {:jira_request, request[:method], request})

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
          {:ok, %Req.Response{status: 201, body: %{"id" => "new-comment"}}}
      end
    end

    assert {:ok, completed} =
             Dispatcher.dispatch_one(
               fn claimed -> CommentPublisher.perform(claimed, request_fun: request_fun) end,
               claim_opts()
             )

    assert completed.status == "succeeded"
    assert completed.provider_id == "new-comment"
    assert intake_connection.secret == "synthetic-jira-token"
    assert_receive {:jira_request, :get, _}
    assert_receive {:jira_request, :post, request}

    assert request[:url] == "https://analysis-publisher.atlassian.net/rest/api/3/issue/10001/comment"

    assert request[:json][:properties] == [
             %{
               "key" => "harmony.analysis",
               "value" => "Harmony analysis #{intake_case.id}/v1"
             }
           ]

    body = request[:json][:body]
    assert body["type"] == "doc"
    assert Enum.any?(body["content"], &contains_text?(&1, "Analiza Harmony — OPS-73"))
    assert Enum.any?(body["content"], &contains_text?(&1, "Nie wykonano zmian w kodzie"))
    assert Enum.any?(body["content"], &contains_text?(&1, "Harmony analysis #{intake_case.id}/v1"))
    refute inspect(body) =~ "<script>"
    refute Enum.any?(body["content"], &has_marks?/1)
    assert delivery.operation == "jira_comment"
  end

  test "preserves Retry-After and records a rejected comment POST on rate limiting" do
    {_project, _connection, intake_case, _delivery} = comment_fixture!()
    claim_time = now()

    request_fun = fn request ->
      case request[:method] do
        :get ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{"startAt" => 0, "maxResults" => 100, "total" => 0, "isLast" => true, "comments" => []}
           }}

        :post ->
          {:ok,
           %Req.Response{
             status: 429,
             headers: %{"retry-after" => ["37"]},
             body: %{"message" => "rate limited"}
           }}
      end
    end

    assert {:retry_wait, retried} =
             Dispatcher.dispatch_one(
               fn claimed -> CommentPublisher.perform(claimed, request_fun: request_fun) end,
               claim_opts(now: claim_time)
             )

    assert retried.last_error_code == "jira_rate_limited"
    assert DateTime.diff(retried.next_attempt_at, claim_time, :second) == 37

    assert Repo.exists?(
             from(event in IntakeEvent,
               where:
                 event.case_id == ^intake_case.id and event.type == "jira_comment_post_rejected" and
                   event.payload["delivery_id"] == ^retried.id
             )
           )
  end

  test "reconciles every comments page after an ambiguous post before returning success" do
    {_project, _connection, intake_case, delivery} = comment_fixture!()
    marker = "Harmony analysis #{intake_case.id}/v1"
    request_count_key = {:comment_reconcile_reads, make_ref()}

    request_fun = fn request ->
      case request[:method] do
        :get ->
          count = Process.get(request_count_key, 0) + 1
          Process.put(request_count_key, count)

          case count do
            1 ->
              {:ok,
               %Req.Response{
                 status: 200,
                 body: %{"startAt" => 0, "maxResults" => 100, "total" => 0, "isLast" => true, "comments" => []}
               }}

            2 ->
              {:ok,
               %Req.Response{
                 status: 200,
                 body: %{
                   "startAt" => 0,
                   "maxResults" => 100,
                   "total" => 101,
                   "isLast" => false,
                   "comments" => [%{"id" => "older", "body" => %{"type" => "doc", "content" => []}}]
                 }
               }}

            3 ->
              {:ok,
               %Req.Response{
                 status: 200,
                 body: %{
                   "startAt" => 100,
                   "maxResults" => 100,
                   "total" => 101,
                   "isLast" => true,
                   "comments" => [
                     %{
                       "id" => "created-before-timeout",
                       "body" => %{
                         "type" => "doc",
                         "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => marker}]}]
                       }
                     }
                   ]
                 }
               }}
          end

        :post ->
          {:error, :timeout}
      end
    end

    assert {:ok, completed} =
             Dispatcher.dispatch_one(
               fn claimed -> CommentPublisher.perform(claimed, request_fun: request_fun) end,
               claim_opts()
             )

    assert completed.id == delivery.id
    assert completed.status == "succeeded"
    assert completed.provider_id == "created-before-timeout"
    assert Process.get(request_count_key) == 3
  end

  test "publishes missing data for a valid needs_input analysis" do
    {_project, _connection, intake_case, _delivery} = comment_fixture!()
    analysis = Repo.get_by!(IntakeAnalysis, case_id: intake_case.id, version: 1)

    updated_result =
      analysis.result
      |> Map.put("needs_input", true)
      |> Map.put("missing_data", ["Synthetic deployment log"])

    analysis
    |> IntakeAnalysis.changeset(%{status: "needs_input", result: updated_result})
    |> Repo.update!()

    parent = self()

    request_fun = fn request ->
      case request[:method] do
        :get ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{"startAt" => 0, "maxResults" => 100, "total" => 0, "isLast" => true, "comments" => []}
           }}

        :post ->
          send(parent, {:published_body, request[:json][:body]})
          {:ok, %Req.Response{status: 201, body: %{"id" => "needs-input-comment"}}}
      end
    end

    assert {:ok, _delivery} =
             Dispatcher.dispatch_one(
               fn claimed -> CommentPublisher.perform(claimed, request_fun: request_fun) end,
               claim_opts()
             )

    assert_receive {:published_body, body}
    assert contains_text?(body, "Brakujące dane")
    assert contains_text?(body, "Synthetic deployment log")
  end

  test "reconciles marker results from comment properties after an ambiguous post" do
    {_project, _connection, intake_case, _delivery} = comment_fixture!()
    marker = "Harmony analysis #{intake_case.id}/v1"
    request_count_key = {:comment_property_reads, make_ref()}

    request_fun = fn request ->
      case request[:method] do
        :get ->
          count = Process.get(request_count_key, 0) + 1
          Process.put(request_count_key, count)

          comments =
            if count == 2 do
              [
                %{
                  "id" => "property-marker-comment",
                  "body" => %{"type" => "doc", "content" => []},
                  "properties" => [%{"key" => "harmony.analysis", "value" => marker}]
                }
              ]
            else
              []
            end

          {:ok,
           %Req.Response{
             status: 200,
             body: %{"startAt" => 0, "maxResults" => 100, "total" => length(comments), "isLast" => true, "comments" => comments}
           }}

        :post ->
          {:error, :timeout}
      end
    end

    assert {:ok, completed} =
             Dispatcher.dispatch_one(
               fn claimed -> CommentPublisher.perform(claimed, request_fun: request_fun) end,
               claim_opts()
             )

    assert completed.status == "succeeded"
    assert completed.provider_id == "property-marker-comment"
    assert Process.get(request_count_key) == 2
  end

  test "a version-one delivery cannot publish over an active version two analysis" do
    {_project, _connection, intake_case, _delivery} =
      comment_fixture!(analysis_version: 2, delivery_version: 1)

    request_fun = fn _request -> flunk("stale analysis must not call Jira") end

    assert {:failed, failed} =
             Dispatcher.dispatch_one(
               fn claimed -> CommentPublisher.perform(claimed, request_fun: request_fun) end,
               claim_opts()
             )

    assert failed.last_error_code == "stale_analysis_version"
    assert intake_case.analysis_version == 2
  end

  defp comment_fixture!(opts \\ []) do
    timestamp = now()
    analysis_version = Keyword.get(opts, :analysis_version, 1)
    delivery_version = Keyword.get(opts, :delivery_version, analysis_version)

    connection =
      %IntegrationConnection{}
      |> IntegrationConnection.changeset(%{
        kind: "jira_cloud",
        name: "Comment Jira #{System.unique_integer([:positive])}",
        settings: %{
          auth_mode: "classic",
          account_email: "harmony@example.test",
          site_url: "https://analysis-publisher.atlassian.net"
        },
        secret: "synthetic-jira-token",
        enabled: true,
        health: "ok"
      })
      |> Repo.insert!()

    project =
      %Project{}
      |> Project.changeset(%{
        slug: "comment-publisher-#{System.unique_integer([:positive])}",
        forge_owner: "synthetic-owner",
        forge_repo: "synthetic-repo",
        forge_base_branch: "main",
        forge_type: "github",
        config: %{},
        config_version: 1
      })
      |> Repo.insert!()

    rule =
      %AutomationRule{}
      |> AutomationRule.changeset(%{
        project_id: project.id,
        jira_connection_id: connection.id,
        name: "Comment publisher rule",
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
        jira_key: "OPS-73",
        jira_url: "https://analysis-publisher.atlassian.net/browse/OPS-73",
        title: "Comment publisher case",
        description_text: "Synthetic issue",
        priority_id: "1",
        priority_name: "High",
        jira_updated_at: timestamp,
        detected_at: timestamp,
        rule_snapshot: %{},
        linear_issue_id: Ecto.UUID.generate(),
        linear_identifier: "LIN-73",
        linear_url: "https://linear.app/acme/issue/LIN-73",
        linear_state_name: "Todo",
        linear_confirmed_at: timestamp,
        analysis_version: analysis_version,
        analysis_status: "ready",
        lock_version: 1
      })
      |> Repo.insert!()

    Enum.each(1..analysis_version, fn version ->
      %IntakeAnalysis{}
      |> IntakeAnalysis.changeset(%{
        case_id: intake_case.id,
        version: version,
        status: "succeeded",
        input_snapshot: %{
          "context_scope" => "issue_only",
          "context_reason" => "repository_not_configured"
        },
        result: %{
          "summary" => "A concise finding",
          "facts" => [%{"text" => "Observed a safe value", "source" => "jira:OPS-73"}],
          "hypotheses" => [],
          "missing_data" => [],
          "next_steps" => ["Collect a trace"],
          "needs_input" => false,
          "context_scope" => "issue_only"
        },
        model: "synthetic-model",
        effort: "medium"
      })
      |> Repo.insert!()
    end)

    delivery =
      %IntegrationDelivery{}
      |> IntegrationDelivery.changeset(%{
        case_id: intake_case.id,
        connection_id: connection.id,
        operation: "jira_comment",
        dedupe_key: "case:#{intake_case.id}:jira-comment:#{delivery_version}",
        payload: %{"version" => delivery_version},
        status: "pending",
        attempts: 0,
        next_attempt_at: timestamp,
        lock_version: 1
      })
      |> Repo.insert!()

    {project, connection, intake_case, delivery}
  end

  defp contains_text?(node, text) when is_map(node) do
    Map.get(node, "text") == text or Enum.any?(Map.get(node, "content", []), &contains_text?(&1, text))
  end

  defp contains_text?(_node, _text), do: false

  defp has_marks?(node) when is_map(node) do
    Map.has_key?(node, "marks") or Enum.any?(Map.get(node, "content", []), &has_marks?/1)
  end

  defp has_marks?(_node), do: false

  defp claim_opts(overrides \\ []) do
    Keyword.merge(
      [
        now: now(),
        intake_enabled: true,
        effects_enabled: true,
        analysis_enabled: true,
        jitter: fn -> 0.0 end,
        operation: "jira_comment"
      ],
      overrides
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
