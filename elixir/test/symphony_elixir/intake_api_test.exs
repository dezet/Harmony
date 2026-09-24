defmodule SymphonyElixir.IntakeApiTest do
  use SymphonyElixir.TestSupport

  import Ecto.Query
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Intake.{Dispatcher, Rules}
  alias SymphonyElixir.Notifications.Templates
  alias SymphonyElixir.Repo

  alias SymphonyElixir.Storage.{
    AutomationRule,
    AutomationScan,
    IntakeAnalysis,
    IntakeCase,
    IntakeEvent,
    IntegrationConnection,
    IntegrationDelivery,
    JiraObservation,
    Project
  }

  @endpoint SymphonyElixirWeb.Endpoint
  @origin "http://www.example.com"
  @fixture_root Path.expand("../../assets/src/test/fixtures", __DIR__)
  @team_id "33333333-3333-4333-8333-333333333333"
  @project_uuid "44444444-4444-4444-8444-444444444444"
  @todo_id "66666666-6666-4666-8666-666666666666"
  @label_id "77777777-7777-4777-8777-777777777777"

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})
    configure_intake(effects_enabled: true)

    parent = self()

    adapters = [
      jira_request_fun: fn request ->
        send(parent, {:jira_request, request[:method], request[:url]})
        jira_response(request)
      end,
      linear_request_fun: fn payload, headers ->
        send(parent, {:linear_request, payload, headers})
        linear_response(payload)
      end,
      smtp_opts: [
        open_fun: fn options ->
          send(parent, {:smtp_open, options[:relay]})
          {:ok, :synthetic_session}
        end,
        close_fun: fn _session ->
          send(parent, :smtp_close)
          :ok
        end,
        smtp_fun: fn _email, _options ->
          send(parent, :smtp_data)
          {:ok, "250 queued"}
        end
      ],
      smsapi_opts: [
        request_fun: fn request ->
          send(parent, {:smsapi_request, request[:method], request[:url]})
          {:ok, %{status: 200, body: %{"points" => 12.5, "username" => "synthetic"}}}
        end
      ],
      analysis_profile_fun: fn ->
        Process.get(:analysis_profile_result, {:ok, %{model: "synthetic-analysis-model", effort: "medium"}})
      end,
      case_action_opts: [
        analysis_profile: %{model: "synthetic-analysis-model", effort: "medium"},
        refresh_fun: fn ->
          send(parent, :implementation_refresh)
          :ok
        end
      ]
    ]

    start_test_endpoint(adapters)
    {session, token} = csrf_session()
    {:ok, session: session, token: token}
  end

  describe "automations" do
    test "POST creates a disabled rule whose shape matches the shared fixture", ctx do
      %{jira: jira, project: project} = base_fixture!()

      conn = mutate(ctx, :post, "/api/v1/automations", rule_input(project, jira))
      assert %{"rule" => rule} = json_response(conn, 201)

      fixture = fixture!("automation_rule.fixture.json")
      assert Map.keys(rule) |> Enum.sort() == Map.keys(fixture) |> Enum.sort()
      assert rule["enabled"] == false
      assert rule["activation_status"] == "idle"
      assert rule["config_version"] == 1
      assert rule["priority_ids"] == ["1", "2"]
      refute Map.has_key?(rule, "lease_token")
    end

    test "POST rejects unknown fields, malformed ids and invalid recipients with field errors", ctx do
      %{jira: jira, project: project} = base_fixture!()
      input = rule_input(project, jira)

      unknown = mutate(ctx, :post, "/api/v1/automations", Map.merge(input, %{"enabled" => true, "lease_token" => "x"}))
      assert %{"error" => %{"code" => "validation_failed", "fields" => fields}} = json_response(unknown, 422)
      assert Map.has_key?(fields, "enabled")
      assert Map.has_key?(fields, "lease_token")

      invalid =
        mutate(ctx, :post, "/api/v1/automations", %{
          input
          | "source_id" => "board-42",
            "priority_ids" => ["1", "1"],
            "sms_recipients" => ["12"],
            "sms_connection_id" => nil
        })

      assert %{"error" => %{"code" => "validation_failed", "fields" => fields}} = json_response(invalid, 422)
      assert Map.has_key?(fields, "source_id")
      assert Map.has_key?(fields, "priority_ids")
      assert Map.has_key?(fields, "sms_recipients") or Map.has_key?(fields, "sms_connection_id")

      sms = sms_connection!()

      phone =
        mutate(ctx, :post, "/api/v1/automations", %{
          input
          | "sms_connection_id" => sms.id,
            "sms_recipients" => ["not-a-number"]
        })

      assert %{"error" => %{"fields" => %{"sms_recipients" => [_ | _]}}} = json_response(phone, 422)
      assert Repo.aggregate(AutomationRule, :count) == 0
    end

    test "GET lists rules with a stable cursor and rejects malformed paging", ctx do
      %{jira: jira, project: project} = base_fixture!()

      for index <- 1..3 do
        assert %{"rule" => _rule} =
                 ctx
                 |> mutate(:post, "/api/v1/automations", rule_input(project, jira, %{"source_id" => "#{100 + index}"}))
                 |> json_response(201)
      end

      first = json_response(get(build_conn(), "/api/v1/automations?page_size=2"), 200)
      assert length(first["items"]) == 2
      assert %{"next_cursor" => cursor, "page_size" => 2} = first["meta"]
      assert is_binary(cursor)

      second = json_response(get(build_conn(), "/api/v1/automations?page_size=2&cursor=#{cursor}"), 200)
      assert length(second["items"]) == 1
      assert second["meta"]["next_cursor"] == nil

      ids = Enum.map(first["items"] ++ second["items"], & &1["id"])
      assert length(Enum.uniq(ids)) == 3

      assert json_response(get(build_conn(), "/api/v1/automations?cursor=garbage"), 400)["error"]["code"] == "invalid_cursor"
      assert json_response(get(build_conn(), "/api/v1/automations?page_size=0"), 400)["error"]["code"] == "invalid_page_size"
      assert json_response(get(build_conn(), "/api/v1/automations?page_size=101"), 400)["error"]["code"] == "invalid_page_size"
    end

    test "PATCH is partial, needs the current config version and never enables a rule", ctx do
      %{rule: rule} = rule_fixture!()

      assert json_response(get(build_conn(), "/api/v1/automations/#{Ecto.UUID.generate()}"), 404)["error"]["code"] == "not_found"
      assert %{"rule" => %{"id" => id}} = json_response(get(build_conn(), "/api/v1/automations/#{rule.id}"), 200)
      assert id == rule.id

      missing = mutate(ctx, :patch, "/api/v1/automations/#{rule.id}", %{"interval_seconds" => 600})
      assert %{"error" => %{"code" => "validation_failed", "fields" => %{"version" => _}}} = json_response(missing, 422)

      stale = mutate(ctx, :patch, "/api/v1/automations/#{rule.id}", %{"version" => rule.config_version + 1, "interval_seconds" => 600})
      assert json_response(stale, 409)["error"]["code"] == "stale_version"

      ok = mutate(ctx, :patch, "/api/v1/automations/#{rule.id}", %{"version" => rule.config_version, "interval_seconds" => 600})
      assert %{"rule" => patched} = json_response(ok, 200)
      assert patched["interval_seconds"] == 600
      assert patched["config_version"] == rule.config_version + 1
      assert patched["enabled"] == false
      assert patched["name"] == rule.name

      replay = mutate(ctx, :patch, "/api/v1/automations/#{rule.id}", %{"version" => rule.config_version, "interval_seconds" => 900})
      assert json_response(replay, 409)["error"]["code"] == "stale_version"

      invalid = mutate(ctx, :patch, "/api/v1/automations/#{rule.id}", %{"version" => patched["config_version"], "interval_seconds" => 30})
      assert %{"error" => %{"fields" => %{"interval_seconds" => _}}} = json_response(invalid, 422)
    end

    test "after activation the Linear target stays locked and a source change needs a new baseline", ctx do
      %{rule: rule} = rule_fixture!(active: true)

      locked = mutate(ctx, :patch, "/api/v1/automations/#{rule.id}", %{"version" => rule.config_version, "linear_team_id" => Ecto.UUID.generate()})
      assert json_response(locked, 422)["error"]["code"] == "immutable_after_activation"

      interval = mutate(ctx, :patch, "/api/v1/automations/#{rule.id}", %{"version" => rule.config_version, "interval_seconds" => 900})
      assert %{"rule" => %{"enabled" => true} = patched} = json_response(interval, 200)

      source = mutate(ctx, :patch, "/api/v1/automations/#{rule.id}", %{"version" => patched["config_version"], "source_id" => "77"})
      assert %{"rule" => %{"enabled" => false, "baseline_generation" => nil}} = json_response(source, 200)
    end

    test "preview reads the saved rule, returns at most 20 samples and writes nothing", ctx do
      %{rule: rule, jira: jira, project: project} = rule_fixture!()
      issues = Enum.map(1..23, &jira_issue/1)
      Process.put(:jira_issues, issues)
      existing_case!(project, rule, jira, "10001")

      counts_before = side_effect_counts()
      rule_before = Repo.get!(AutomationRule, rule.id)

      conn = mutate(ctx, :post, "/api/v1/automations/#{rule.id}/preview", %{})

      assert %{
               "rule_id" => rule_id,
               "config_version" => version,
               "sample" => sample,
               "sample_limit" => 20,
               "match_count" => 23,
               "truncated" => true,
               "warnings" => warnings
             } = json_response(conn, 200)

      assert rule_id == rule.id
      assert version == rule.config_version
      assert length(sample) == 20
      assert %{"key" => "OPS-1", "already_linked" => true, "url" => url} = hd(sample)
      assert url == "#{jira_site(jira)}/browse/OPS-1"
      refute Enum.any?(sample, &Map.has_key?(&1, "description"))
      assert %{"code" => "already_linked", "count" => 1} in warnings

      assert side_effect_counts() == counts_before
      rule_after = Repo.get!(AutomationRule, rule.id)
      assert rule_after.lock_version == rule_before.lock_version
      assert rule_after.updated_at == rule_before.updated_at

      requests = drain_jira_requests()
      assert requests != []

      assert Enum.all?(requests, fn {method, url} ->
               (method == :get and String.ends_with?(url, "/rest/agile/1.0/board/42/configuration")) or
                 (method == :post and String.ends_with?(url, "/rest/api/3/search/jql"))
             end)
    end

    test "preview maps provider failures to dependency errors without their bodies", ctx do
      %{rule: rule} = rule_fixture!()
      Process.put(:jira_status, {401, "provider-body-canary"})

      conn = mutate(ctx, :post, "/api/v1/automations/#{rule.id}/preview", %{})
      body = response(conn, 503)
      assert Jason.decode!(body)["error"]["code"] == "jira_auth_failed"
      refute body =~ "provider-body-canary"
    end

    test "activation is a separate confirmed step and the kill switch blocks it", ctx do
      %{rule: rule} = rule_fixture!()
      Process.put(:jira_priorities, [%{"id" => "2", "name" => "Medium"}, %{"id" => "1", "name" => "High"}, %{"id" => "7", "name" => "Low"}])
      assert json_response(get(build_conn(), "/api/v1/automations/#{rule.id}"), 200)["rule"]["priority_ranking"] == nil

      unconfirmed = mutate(ctx, :post, "/api/v1/automations/#{rule.id}/activate", %{"version" => rule.config_version})
      assert %{"error" => %{"code" => "confirmation_required", "fields" => %{"confirmed" => _}}} = json_response(unconfirmed, 422)

      configure_intake(effects_enabled: false)
      blocked = mutate(ctx, :post, "/api/v1/automations/#{rule.id}/activate", %{"version" => rule.config_version, "confirmed" => true})
      assert json_response(blocked, 409)["error"]["code"] == "effects_disabled"
      assert Repo.get!(AutomationRule, rule.id).activation_status == "idle"

      configure_intake(effects_enabled: true)
      stale = mutate(ctx, :post, "/api/v1/automations/#{rule.id}/activate", %{"version" => rule.config_version + 1, "confirmed" => true})
      assert json_response(stale, 409)["error"]["code"] == "stale_version"

      accepted = mutate(ctx, :post, "/api/v1/automations/#{rule.id}/activate", %{"version" => rule.config_version, "confirmed" => true})
      assert %{"status" => "activating", "rule" => activated} = json_response(accepted, 202)
      assert activated["enabled"] == false
      assert activated["activation_status"] == "activating"
      assert activated["priority_ranking"] == ["2", "1", "7"]
      assert Repo.get!(AutomationRule, rule.id).priority_ranking == ["2", "1", "7"]
      assert Rules.snapshot(Repo.get!(AutomationRule, rule.id)).priority_ranking == ["2", "1", "7"]

      paused = mutate(ctx, :post, "/api/v1/automations/#{rule.id}/pause", %{"version" => activated["config_version"]})
      assert %{"rule" => %{"enabled" => false, "activation_status" => "idle"}} = json_response(paused, 200)
    end

    test "check claims one scan synchronously, returns its id and fails closed without a scheduler", ctx do
      %{rule: idle} = rule_fixture!()

      no_scheduler = mutate(ctx, :post, "/api/v1/automations/#{idle.id}/check", %{})
      assert json_response(no_scheduler, 503)["error"]["code"] == "scheduler_unavailable"

      parent = self()

      request_fun = fn request ->
        send(parent, {:scan_jira_request, request[:method], URI.parse(request[:url]).path, self()})

        receive do
          :release_scan -> jira_route(request[:method], URI.parse(request[:url]).path, request)
        after
          5_000 -> {:error, :timeout}
        end
      end

      start_supervised!(
        {SymphonyElixir.Intake.Scheduler,
         run_opts: [request_fun: request_fun, analysis_enabled: true, analysis_model: "synthetic", analysis_effort: "medium"],
         tick_interval_ms: 0,
         enabled?: fn -> true end,
         effects_enabled?: fn -> true end,
         result_observer: fn rule_id, error_code -> send(parent, {:scan_reported, rule_id, error_code}) end}
      )

      inactive = mutate(ctx, :post, "/api/v1/automations/#{idle.id}/check", %{})
      assert json_response(inactive, 409)["error"]["code"] == "rule_not_active"

      %{rule: active} = rule_fixture!(active: true, source_id: "43")
      accepted = mutate(ctx, :post, "/api/v1/automations/#{active.id}/check", %{})
      assert %{"status" => "accepted", "rule_id" => rule_id, "scan_id" => scan_id} = json_response(accepted, 202)
      assert rule_id == active.id
      assert %AutomationScan{rule_id: ^rule_id, status: "running"} = Repo.get!(AutomationScan, scan_id)

      assert_receive {:scan_jira_request, :get, _path, worker}, 2_000
      repeated = mutate(ctx, :post, "/api/v1/automations/#{active.id}/check", %{})
      assert json_response(repeated, 409)["error"]["code"] == "scan_in_progress"
      assert Repo.aggregate(from(scan in AutomationScan, where: scan.rule_id == ^rule_id), :count) == 1

      missing = mutate(ctx, :post, "/api/v1/automations/#{Ecto.UUID.generate()}/check", %{})
      assert json_response(missing, 404)["error"]["code"] == "not_found"

      bulk = mutate(ctx, :post, "/api/v1/automations/check", %{})
      assert %{"accepted_rule_ids" => accepted_ids, "skipped" => skipped} = json_response(bulk, 202)
      assert idle.id not in accepted_ids
      assert %{"rule_id" => idle.id, "code" => "rule_not_active"} in skipped
      assert %{"rule_id" => active.id, "code" => "scan_in_progress"} in skipped

      send(worker, :release_scan)
      release_scan_requests()
      assert_receive {:scan_reported, ^rule_id, _code}, 2_000
    end
  end

  describe "activation requirements" do
    test "activation reads Jira, Linear, the analysis profile and channels without writing", ctx do
      %{rule: rule} = rule_fixture!()
      smtp = smtp_connection!()
      sms = sms_connection!()

      Repo.update_all(from(r in AutomationRule, where: r.id == ^rule.id),
        set: [
          email_connection_id: smtp.id,
          email_recipients: ["oncall@example.test"],
          sms_connection_id: sms.id,
          sms_recipients: ["+48600100200"],
          priority_ids: ["1"]
        ]
      )

      conn = mutate(ctx, :post, "/api/v1/automations/#{rule.id}/activate", %{"version" => rule.config_version, "confirmed" => true})
      assert %{"status" => "activating"} = json_response(conn, 202)

      requests = drain_jira_requests()
      assert {:get, _myself} = Enum.find(requests, fn {_method, url} -> String.ends_with?(url, "/rest/api/3/myself") end)
      assert Enum.any?(requests, fn {_method, url} -> String.ends_with?(url, "/rest/agile/1.0/board/42/configuration") end)
      assert Enum.any?(requests, fn {_method, url} -> String.ends_with?(url, "/rest/api/3/priority/search") end)
      assert Enum.all?(requests, fn {method, _url} -> method == :get end)

      assert_received {:linear_request, %{"query" => query}, _headers}
      refute query =~ "mutation"
      refute_mutation_sent()
      assert Repo.aggregate(IntegrationDelivery, :count) == 0
    end

    test "a rule whose requirements are not met stays inactive with a specific 422 code", ctx do
      other_team = "99999999-9999-4999-8999-999999999999"

      cases = [
        {[linear_states: [%{"id" => "backlog-id", "name" => "Backlog", "type" => "backlog"}]], "linear_todo_state_missing", "linear_todo_state_id"},
        {[linear_states: [%{"id" => "other-todo", "name" => "Todo", "type" => "unstarted"}]], "linear_todo_state_mismatch", "linear_todo_state_id"},
        {[linear_labels: [%{"id" => "bug", "name" => "bug"}]], "linear_hold_label_missing", "linear_hold_label_id"},
        {[linear_team_id: other_team], "linear_team_missing", "linear_team_id"},
        {[linear_projects: [%{"id" => "other-project", "name" => "Other"}]], "linear_project_missing", "linear_project_id"},
        {[jira_priorities: [%{"id" => "1", "name" => "High"}]], "jira_priority_unknown", "priority_ids"},
        {[jira_board_missing: true], "jira_source_not_found", "source_id"},
        {[analysis_profile_result: {:error, :analysis_profile_unavailable}], "analysis_profile_unavailable", "analysis_profile"},
        {[email_disabled: true], "email_connection_unavailable", "email_connection_id"}
      ]

      for {overrides, code, field} <- cases do
        %{rule: rule} = rule_fixture!()
        Process.put(:jira_priorities, [%{"id" => "1", "name" => "High"}, %{"id" => "2", "name" => "Medium"}])
        Enum.each(overrides, fn {key, value} -> Process.put(key, value) end)

        if overrides[:email_disabled] do
          smtp = smtp_connection!()
          Repo.update_all(from(c in IntegrationConnection, where: c.id == ^smtp.id), set: [enabled: false])

          Repo.update_all(from(r in AutomationRule, where: r.id == ^rule.id),
            set: [email_connection_id: smtp.id, email_recipients: ["oncall@example.test"]]
          )
        end

        conn = mutate(ctx, :post, "/api/v1/automations/#{rule.id}/activate", %{"version" => rule.config_version, "confirmed" => true})
        assert %{"error" => %{"code" => ^code, "fields" => fields}} = json_response(conn, 422), code
        assert Map.has_key?(fields, field), "#{code}: #{inspect(fields)}"
        assert %AutomationRule{enabled: false, activation_status: "idle"} = Repo.get!(AutomationRule, rule.id)

        Enum.each(overrides, fn {key, _value} -> Process.delete(key) end)
        drain_jira_requests()
      end

      assert Repo.aggregate(AutomationScan, :count) == 0
    end

    test "an unavailable dependency is 503 without the provider body", ctx do
      %{rule: rule} = rule_fixture!()
      Process.put(:jira_status, {500, "provider-body-canary"})

      conn = mutate(ctx, :post, "/api/v1/automations/#{rule.id}/activate", %{"version" => rule.config_version, "confirmed" => true})
      body = response(conn, 503)
      assert Jason.decode!(body)["error"]["code"] == "jira_unavailable"
      refute body =~ "provider-body-canary"
      assert Repo.get!(AutomationRule, rule.id).activation_status == "idle"
      refute_received {:linear_request, _payload, _headers}
    end
  end

  describe "integrations" do
    test "SMTP input follows the spec settings and the runtime host allowlist", ctx do
      created = mutate(ctx, :post, "/api/v1/integrations", smtp_input(%{"port" => nil}))
      assert %{"connection" => connection} = json_response(created, 201)

      fixture = fixture!("integration_connection.fixture.json")
      assert Map.keys(connection) |> Enum.sort() == Map.keys(fixture) |> Enum.sort()
      assert connection["settings"]["port"] == 587
      assert connection["secret_state"] == "set"
      assert connection["enabled"] == false

      for {settings, field} <- [
            {%{"host" => "mail.attacker.example"}, "settings.host"},
            {%{"tls_mode" => "none"}, "settings.tls_mode"},
            {%{"port" => 70_000}, "settings.port"},
            {%{"username" => " "}, "settings.username"},
            {%{"from_email" => "not-an-address"}, "settings.from_email"},
            {%{"from_name" => "Harmony\r\nBcc: x@example.test"}, "settings.from_name"},
            {%{"message_id_domain" => "bad domain"}, "settings.message_id_domain"},
            {%{"relay_url" => "http://169.254.169.254"}, "settings"}
          ] do
        conn = mutate(ctx, :post, "/api/v1/integrations", smtp_input(settings))
        assert %{"error" => %{"code" => "validation_failed", "fields" => fields}} = json_response(conn, 422)
        assert Map.has_key?(fields, field), "expected #{field} in #{inspect(fields)}"
      end
    end

    test "Jira input accepts only Atlassian HTTPS sites and explicit auth modes", ctx do
      for settings <- [
            %{"site_url" => "http://ops.atlassian.net"},
            %{"site_url" => "https://ops.example.com"},
            %{"site_url" => "https://user@ops.atlassian.net"},
            %{"site_url" => "https://ops.atlassian.net/?next=x"},
            %{"auth_mode" => "scoped", "cloud_id" => nil},
            %{"auth_mode" => "classic", "account_email" => nil},
            %{"auth_mode" => "oauth"}
          ] do
        conn = mutate(ctx, :post, "/api/v1/integrations", jira_input(settings))
        assert json_response(conn, 422)["error"]["code"] == "validation_failed", inspect(settings)
      end

      conn = mutate(ctx, :post, "/api/v1/integrations", jira_input(%{}))
      assert %{"connection" => %{"kind" => "jira_cloud", "secret_state" => "set"}} = json_response(conn, 201)
    end

    test "PATCH keeps a blank secret, clear_secret removes it and disables dependent activations", ctx do
      %{rule: rule} = rule_fixture!(active: true)
      smtp = smtp_connection!()

      Repo.update_all(from(r in AutomationRule, where: r.id == ^rule.id),
        set: [email_connection_id: smtp.id, email_recipients: ["oncall@example.test"]]
      )

      stale = mutate(ctx, :patch, "/api/v1/integrations/#{smtp.id}", %{"version" => smtp.lock_version + 1, "name" => "x"})
      assert json_response(stale, 409)["error"]["code"] == "stale_version"

      kept = mutate(ctx, :patch, "/api/v1/integrations/#{smtp.id}", %{"version" => smtp.lock_version, "secret" => "", "name" => "Primary SMTP"})
      assert %{"connection" => %{"secret_state" => "set", "name" => "Primary SMTP"} = kept_connection} = json_response(kept, 200)
      assert Repo.get!(IntegrationConnection, smtp.id).secret == "synthetic-smtp-password"

      kind = mutate(ctx, :patch, "/api/v1/integrations/#{smtp.id}", %{"version" => kept_connection["lock_version"], "kind" => "smsapi"})
      assert %{"error" => %{"fields" => %{"kind" => _}}} = json_response(kind, 422)

      cleared = mutate(ctx, :patch, "/api/v1/integrations/#{smtp.id}", %{"version" => kept_connection["lock_version"], "clear_secret" => true})
      assert %{"connection" => %{"secret_state" => "unset", "enabled" => false}} = json_response(cleared, 200)
      assert Repo.get!(IntegrationConnection, smtp.id).secret == nil
      assert %AutomationRule{enabled: false, activation_status: "idle"} = Repo.get!(AutomationRule, rule.id)

      list = json_response(get(build_conn(), "/api/v1/integrations?page_size=1"), 200)
      assert length(list["items"]) == 1
      assert is_binary(list["meta"]["next_cursor"])
    end

    test "connection tests read identity only and never send a message", ctx do
      smtp = smtp_connection!()
      sms = sms_connection!()
      %{jira: jira} = base_fixture!()

      smtp_result = mutate(ctx, :post, "/api/v1/integrations/#{smtp.id}/test", %{})
      assert %{"health" => "ok", "checked_at" => checked_at, "error_code" => nil} = json_response(smtp_result, 200)
      assert is_binary(checked_at)
      assert_received {:smtp_open, "smtp.example.test"}
      assert_received :smtp_close
      refute_received :smtp_data

      sms_result = mutate(ctx, :post, "/api/v1/integrations/#{sms.id}/test", %{})
      assert %{"health" => "ok"} = json_response(sms_result, 200)
      assert_received {:smsapi_request, :get, "https://api.smsapi.pl/profile"}
      refute_received {:smsapi_request, _method, "https://api.smsapi.pl/sms.do"}

      jira_result = mutate(ctx, :post, "/api/v1/integrations/#{jira.id}/test", %{})
      assert %{"health" => "ok"} = json_response(jira_result, 200)
      assert [{:get, url}] = drain_jira_requests()
      assert String.ends_with?(url, "/rest/api/3/myself")

      stored = Repo.get!(IntegrationConnection, smtp.id)
      assert stored.health == "ok"
      assert stored.last_checked_at
      assert stored.lock_version == smtp.lock_version
      assert Repo.aggregate(IntegrationDelivery, :count) == 0

      Process.put(:jira_status, {403, "provider-body-canary"})
      failed = mutate(ctx, :post, "/api/v1/integrations/#{jira.id}/test", %{})
      body = response(failed, 200)
      assert %{"health" => "error", "error_code" => "jira_auth_failed"} = Jason.decode!(body)
      refute body =~ "provider-body-canary"
    end

    test "test-send validates its key, confirmation, recipient and provider", ctx do
      sms = sms_connection!()
      %{jira: jira} = base_fixture!()
      path = "/api/v1/integrations/#{sms.id}/test-send"
      body = %{"recipient" => "+48 600 100 200", "confirmed" => true}

      missing = mutate(ctx, :post, path, body)
      assert %{"error" => %{"code" => "invalid_idempotency_key", "fields" => %{"idempotency_key" => _}}} = json_response(missing, 422)

      malformed = mutate(ctx, :post, path, body, [{"idempotency-key", "abc"}])
      assert json_response(malformed, 422)["error"]["code"] == "invalid_idempotency_key"

      key = [{"idempotency-key", Ecto.UUID.generate()}]
      unconfirmed = mutate(ctx, :post, path, Map.delete(body, "confirmed"), key)
      assert json_response(unconfirmed, 422)["error"]["code"] == "confirmation_required"

      recipient = mutate(ctx, :post, path, %{body | "recipient" => "12"}, key)
      assert %{"error" => %{"fields" => %{"recipient" => _}}} = json_response(recipient, 422)

      unsupported = mutate(ctx, :post, "/api/v1/integrations/#{jira.id}/test-send", body, key)
      assert json_response(unsupported, 422)["error"]["code"] == "test_send_unsupported"

      Repo.update_all(from(c in IntegrationConnection, where: c.id == ^sms.id), set: [enabled: false])
      disabled = mutate(ctx, :post, path, body, key)
      assert json_response(disabled, 409)["error"]["code"] == "connection_disabled"

      assert Repo.aggregate(IntegrationDelivery, :count) == 0
    end

    test "test-send is an idempotent case-less outbox delivery", ctx do
      sms = sms_connection!()
      path = "/api/v1/integrations/#{sms.id}/test-send"
      key = Ecto.UUID.generate()
      body = %{"recipient" => "+48 600 100 200", "confirmed" => true}

      first = mutate(ctx, :post, path, body, [{"idempotency-key", key}])
      assert %{"test_delivery" => %{"id" => id, "operation" => "sms", "status" => "pending"} = delivery} = json_response(first, 202)
      refute Map.has_key?(delivery, "payload")
      refute response(first, 202) =~ "600100200"

      again = mutate(ctx, :post, path, body, [{"idempotency-key", String.upcase(key)}])
      assert %{"test_delivery" => %{"id" => ^id}} = json_response(again, 202)

      assert [stored] = Repo.all(IntegrationDelivery)
      assert stored.case_id == nil
      assert stored.connection_id == sms.id
      assert stored.payload["test_send"] == true
      assert stored.payload["recipient"] == "+48600100200"

      conflict = mutate(ctx, :post, path, %{body | "recipient" => "+48 600 100 300"}, [{"idempotency-key", key}])
      assert json_response(conflict, 409)["error"]["code"] == "idempotency_key_conflict"
      refute_received {:smsapi_request, _method, _url}
    end

    test "test-send is blocked while effects are disabled", ctx do
      smtp = smtp_connection!()
      configure_intake(effects_enabled: false)

      conn =
        mutate(ctx, :post, "/api/v1/integrations/#{smtp.id}/test-send", %{"recipient" => "oncall@example.test", "confirmed" => true}, [
          {"idempotency-key", Ecto.UUID.generate()}
        ])

      assert json_response(conn, 409)["error"]["code"] == "effects_disabled"
      assert Repo.aggregate(IntegrationDelivery, :count) == 0
    end

    test "test-sends count toward the hourly limit of their connection", ctx do
      sms = sms_connection!()
      path = "/api/v1/integrations/#{sms.id}/test-send"

      for _index <- 1..2 do
        conn = mutate(ctx, :post, path, %{"recipient" => "+48600100200", "confirmed" => true}, [{"idempotency-key", Ecto.UUID.generate()}])
        assert %{"test_delivery" => _delivery} = json_response(conn, 202)
      end

      parent = self()

      sms_opts = [
        request_fun: fn request ->
          send(parent, {:sms_sent, request[:form][:message]})
          {:ok, %{status: 200, body: %{"count" => 1, "list" => [%{"id" => "provider-1", "status" => "QUEUE"}]}}}
        end
      ]

      opts = [sms_opts: sms_opts, rate_limits: %{email: 60, sms: 1}, intake_enabled: true, effects_enabled: true]
      assert {:ok, %IntegrationDelivery{status: "succeeded"}} = Dispatcher.dispatch_one(opts)
      assert_received {:sms_sent, message}
      assert message == Templates.render_test_sms()

      Dispatcher.dispatch_one(opts)
      refute_received {:sms_sent, _message}

      assert [%IntegrationDelivery{status: "retry_wait", last_error_code: "rate_limited"}] =
               Repo.all(from(d in IntegrationDelivery, where: d.status != "succeeded"))
    end

    test "Jira pickers filter by name, paginate with a cursor and reject bad cursors", ctx do
      %{jira: jira} = base_fixture!()
      smtp = smtp_connection!()
      Process.put(:jira_boards, Enum.map(1..30, &%{"id" => &1, "name" => "Board #{&1}"}))

      first = json_response(get(build_conn(), "/api/v1/integrations/#{jira.id}/jira/boards?page_size=25"), 200)
      assert length(first["items"]) == 25
      assert hd(first["items"]) == %{"id" => "1", "name" => "Board 1"}
      assert is_binary(first["meta"]["next_cursor"])

      second = json_response(get(build_conn(), "/api/v1/integrations/#{jira.id}/jira/boards?page_size=25&cursor=#{first["meta"]["next_cursor"]}"), 200)
      assert length(second["items"]) == 5
      assert second["meta"]["next_cursor"] == nil

      filtered = json_response(get(build_conn(), "/api/v1/integrations/#{jira.id}/jira/boards?q=board%203"), 200)
      assert Enum.map(filtered["items"], & &1["id"]) == ["3", "30"]

      mismatched = get(build_conn(), "/api/v1/integrations/#{jira.id}/jira/boards?q=x&cursor=#{first["meta"]["next_cursor"]}")
      assert json_response(mismatched, 400)["error"]["code"] == "invalid_cursor"

      priorities = json_response(get(build_conn(), "/api/v1/integrations/#{jira.id}/jira/priorities"), 200)
      assert priorities["items"] == [%{"id" => "3", "name" => "Highest"}, %{"id" => "1", "name" => "High"}]

      filters = json_response(get(build_conn(), "/api/v1/integrations/#{jira.id}/jira/filters"), 200)
      assert filters["items"] == [%{"id" => "1001", "name" => "Pilne"}]

      wrong_kind = get(build_conn(), "/api/v1/integrations/#{smtp.id}/jira/boards")
      assert json_response(wrong_kind, 422)["error"]["code"] == "connection_kind_mismatch"
      _unused = ctx
    end
  end

  describe "Linear options" do
    test "lists teams, projects, the Todo state and the hold label with explicit IDs", ctx do
      %{project: project} = base_fixture!()

      conn = get(build_conn(), "/api/v1/projects/#{project.id}/linear-options")

      assert %{"teams" => [team], "projects" => projects, "states" => states, "hold_label" => hold_label} =
               json_response(conn, 200)

      assert team == %{
               "id" => @team_id,
               "key" => "OPS",
               "name" => "Operations",
               "todo_state_id" => @todo_id,
               "hold_label_id" => @label_id
             }

      assert %{"id" => @project_uuid, "name" => "Portal", "team_ids" => [@team_id]} in projects
      assert %{"id" => @todo_id, "name" => "Todo", "type" => "unstarted", "team_id" => @team_id} in states
      assert hold_label == %{"name" => "harmony:analysis-only"}

      assert_received {:linear_request, _payload, headers}
      assert {"Authorization", "linear-project-token"} in headers or {"authorization", "linear-project-token"} in headers

      unknown = get(build_conn(), "/api/v1/projects/#{Ecto.UUID.generate()}/linear-options")
      assert json_response(unknown, 404)["error"]["code"] == "not_found"
      _unused = ctx
    end

    test "creating the hold label needs confirmation, reuses a label and respects the kill switch", ctx do
      %{project: project} = base_fixture!()
      path = "/api/v1/projects/#{project.id}/linear-hold-label"

      unconfirmed = mutate(ctx, :post, path, %{"team_id" => @team_id})
      assert json_response(unconfirmed, 422)["error"]["code"] == "confirmation_required"

      reused = mutate(ctx, :post, path, %{"team_id" => @team_id, "confirmed" => true})
      assert %{"label_id" => @label_id, "created" => false} = json_response(reused, 200)
      refute_mutation_sent()

      Process.put(:linear_labels, [])
      created = mutate(ctx, :post, path, %{"team_id" => @team_id, "confirmed" => true})
      assert %{"label_id" => "88888888-8888-4888-8888-888888888888", "created" => true} = json_response(created, 201)

      configure_intake(effects_enabled: false)
      blocked = mutate(ctx, :post, path, %{"team_id" => @team_id, "confirmed" => true})
      assert json_response(blocked, 409)["error"]["code"] == "effects_disabled"
    end
  end

  describe "case actions" do
    test "acknowledge uses the case expected_version and only accepts Jira refs", ctx do
      intake_case = ready_case!()
      path = "/api/v1/cases/jira_#{intake_case.id}/acknowledge"

      missing = mutate(ctx, :post, path, %{})
      assert %{"error" => %{"fields" => %{"expected_version" => _}}} = json_response(missing, 422)

      stale = mutate(ctx, :post, path, %{"expected_version" => intake_case.lock_version + 1})
      assert json_response(stale, 409)["error"]["code"] == "stale_version"

      ok = mutate(ctx, :post, path, %{"expected_version" => intake_case.lock_version})
      assert %{"case" => acknowledged, "version" => version} = json_response(ok, 200)
      assert acknowledged["ref"] == "jira_#{intake_case.id}"
      assert is_binary(acknowledged["acknowledged_at"])
      assert acknowledged["repair_approved_at"] == nil
      assert version == intake_case.lock_version + 1
      refute_received :implementation_refresh

      run_ref = mutate(ctx, :post, "/api/v1/cases/run_#{Ecto.UUID.generate()}/acknowledge", %{"expected_version" => 1})
      assert json_response(run_ref, 422)["error"]["code"] == "unsupported_case_kind"

      unknown = mutate(ctx, :post, "/api/v1/cases/jira_#{Ecto.UUID.generate()}/acknowledge", %{"expected_version" => 1})
      assert json_response(unknown, 404)["error"]["code"] == "not_found"

      garbage = mutate(ctx, :post, "/api/v1/cases/nonsense/acknowledge", %{"expected_version" => 1})
      assert json_response(garbage, 404)["error"]["code"] == "not_found"
    end

    test "approve-repair is confirmed, versioned and idempotent", ctx do
      intake_case = ready_case!()
      path = "/api/v1/cases/jira_#{intake_case.id}/approve-repair"
      body = %{"expected_version" => intake_case.lock_version, "analysis_version" => 1}

      unconfirmed = mutate(ctx, :post, path, Map.put(body, "confirmed", "true"))
      assert json_response(unconfirmed, 422)["error"]["code"] == "confirmation_required"

      unpublished = ready_case!(published?: false)

      not_ready =
        mutate(ctx, :post, "/api/v1/cases/jira_#{unpublished.id}/approve-repair", %{
          "expected_version" => unpublished.lock_version,
          "analysis_version" => 1,
          "confirmed" => true
        })

      assert json_response(not_ready, 409)["error"]["code"] == "analysis_not_published"

      approved = mutate(ctx, :post, path, Map.put(body, "confirmed", true))
      assert %{"status" => "approved", "case" => %{"repair_approved_version" => 1}} = json_response(approved, 200)
      assert_received :implementation_refresh

      repeated = mutate(ctx, :post, path, Map.put(body, "confirmed", true))
      assert %{"status" => "approved"} = json_response(repeated, 200)
      refute_received :implementation_refresh
    end

    test "reanalyze queues the next version and is blocked by approval and the kill switch", ctx do
      intake_case = ready_case!()
      path = "/api/v1/cases/jira_#{intake_case.id}/reanalyze"

      configure_intake(effects_enabled: false)
      blocked = mutate(ctx, :post, path, %{"expected_version" => intake_case.lock_version, "confirmed" => true})
      assert json_response(blocked, 409)["error"]["code"] == "effects_disabled"

      configure_intake(effects_enabled: true)
      queued = mutate(ctx, :post, path, %{"expected_version" => intake_case.lock_version, "confirmed" => true})
      assert %{"analysis_version" => 2, "version" => version} = json_response(queued, 202)
      assert Repo.get_by!(IntakeAnalysis, case_id: intake_case.id, version: 2).status == "queued"

      approved_case = ready_case!(approved?: true)

      refused =
        mutate(ctx, :post, "/api/v1/cases/jira_#{approved_case.id}/reanalyze", %{
          "expected_version" => approved_case.lock_version,
          "confirmed" => true
        })

      assert json_response(refused, 409)["error"]["code"] == "repair_already_approved"
      assert is_integer(version)
    end

    test "approve and reanalyze of the same version: one wins, the other is 409", ctx do
      intake_case = ready_case!()
      version = intake_case.lock_version

      requests = [
        {"/api/v1/cases/jira_#{intake_case.id}/approve-repair", %{"expected_version" => version, "analysis_version" => 1, "confirmed" => true}},
        {"/api/v1/cases/jira_#{intake_case.id}/reanalyze", %{"expected_version" => version, "confirmed" => true}}
      ]

      statuses =
        requests
        |> Enum.map(fn {path, body} -> Task.async(fn -> mutate(ctx, :post, path, body).status end) end)
        |> Enum.map(&Task.await(&1, 10_000))
        |> Enum.sort()

      assert statuses in [[200, 409], [202, 409]]
      stored = Repo.get!(IntakeCase, intake_case.id)
      refute stored.repair_approved_at != nil and stored.analysis_version == 2
    end
  end

  describe "delivery retry" do
    test "retry follows the outbox rules and the expected status", ctx do
      %{jira: jira} = base_fixture!()
      failed = delivery!(jira, "failed", "email")
      succeeded = delivery!(jira, "succeeded", "email")
      unknown = delivery!(jira, "unknown", "email")

      mismatch = mutate(ctx, :post, "/api/v1/deliveries/#{failed.id}/retry", %{"expected_status" => "unknown"})
      assert json_response(mismatch, 409)["error"]["code"] == "status_mismatch"

      ok = mutate(ctx, :post, "/api/v1/deliveries/#{failed.id}/retry", %{"expected_status" => "failed"})
      assert %{"delivery" => %{"id" => id, "status" => "retry_wait", "retry_allowed" => false}} = json_response(ok, 202)
      assert id == failed.id

      done = mutate(ctx, :post, "/api/v1/deliveries/#{succeeded.id}/retry", %{"expected_status" => "succeeded"})
      assert json_response(done, 409)["error"]["code"] == "not_retryable"

      unconfirmed = mutate(ctx, :post, "/api/v1/deliveries/#{unknown.id}/retry", %{"expected_status" => "unknown"})
      assert %{"code" => "confirmation_required", "fields" => %{"confirm_duplicate_risk" => _}} = json_response(unconfirmed, 422)["error"]

      configure_intake(effects_enabled: false)
      blocked = mutate(ctx, :post, "/api/v1/deliveries/#{unknown.id}/retry", %{"expected_status" => "unknown", "confirm_duplicate_risk" => true})
      assert json_response(blocked, 409)["error"]["code"] == "effects_disabled"

      configure_intake(effects_enabled: true)
      confirmed = mutate(ctx, :post, "/api/v1/deliveries/#{unknown.id}/retry", %{"expected_status" => "unknown", "confirm_duplicate_risk" => true})
      assert %{"delivery" => %{"status" => "retry_wait", "duplicate_risk" => false}} = json_response(confirmed, 202)

      missing = mutate(ctx, :post, "/api/v1/deliveries/#{Ecto.UUID.generate()}/retry", %{"expected_status" => "failed"})
      assert json_response(missing, 404)["error"]["code"] == "not_found"
    end
  end

  test "wrong methods on the new routes return 405" do
    id = Ecto.UUID.generate()

    for {method, path} <- [
          {:delete, "/api/v1/automations/#{id}"},
          {:put, "/api/v1/automations"},
          {:get, "/api/v1/automations/#{id}/preview"},
          {:get, "/api/v1/automations/#{id}/activate"},
          {:get, "/api/v1/automations/check"},
          {:put, "/api/v1/integrations/#{id}"},
          {:get, "/api/v1/integrations/#{id}/test-send"},
          {:post, "/api/v1/integrations/#{id}/jira/boards"},
          {:delete, "/api/v1/projects/#{id}/linear-options"},
          {:get, "/api/v1/projects/#{id}/linear-hold-label"},
          {:get, "/api/v1/cases/jira_#{id}/acknowledge"},
          {:get, "/api/v1/deliveries/#{id}/retry"}
        ] do
      conn = dispatch(build_conn(), @endpoint, method, path, nil)
      assert json_response(conn, 405)["error"]["code"] == "method_not_allowed", "#{method} #{path}"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp configure_intake(opts) do
    write_workflow_file!(Workflow.workflow_file_path(),
      intake_enabled: true,
      intake_effects_enabled: Keyword.fetch!(opts, :effects_enabled),
      intake_public_url: "https://harmony.example.test",
      intake_smtp_allowed_hosts: ["smtp.example.test"]
    )
  end

  defp csrf_session do
    conn = get(build_conn(), "/api/v1/csrf")
    {conn, json_response(conn, 200)["csrf_token"]}
  end

  defp mutate(ctx, method, path, body, headers \\ []) do
    conn =
      ctx.session
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", @origin)
      |> put_req_header("x-csrf-token", ctx.token)

    headers
    |> Enum.reduce(conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
    |> dispatch(@endpoint, method, path, Jason.encode!(body))
  end

  defp fixture!(name) do
    @fixture_root |> Path.join(name) |> File.read!() |> Jason.decode!()
  end

  defp side_effect_counts do
    Enum.map([IntakeCase, IntegrationDelivery, IntakeEvent, JiraObservation, AutomationScan], &Repo.aggregate(&1, :count))
  end

  defp drain_jira_requests(acc \\ []) do
    receive do
      {:jira_request, method, url} -> drain_jira_requests([{method, url} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp release_scan_requests do
    receive do
      {:scan_jira_request, _method, _path, worker} ->
        send(worker, :release_scan)
        release_scan_requests()
    after
      200 -> :ok
    end
  end

  defp refute_mutation_sent do
    receive do
      {:linear_request, %{"query" => query}, _headers} ->
        refute query =~ "mutation"
        refute_mutation_sent()
    after
      0 -> :ok
    end
  end

  defp base_fixture! do
    project =
      %Project{}
      |> Project.changeset(%{
        slug: "intake-api-#{System.unique_integer([:positive])}",
        linear_project_slug: "intake-api",
        linear_team_key: "OPS",
        forge_owner: "example",
        forge_repo: "synthetic",
        forge_base_branch: "main",
        config_version: 1,
        config: %{}
      })
      |> Repo.insert!()
      |> Ecto.Changeset.change(tracker_secret: "linear-project-token")
      |> Repo.update!()

    jira =
      %IntegrationConnection{}
      |> IntegrationConnection.changeset(%{
        kind: "jira_cloud",
        name: "Jira #{System.unique_integer([:positive])}",
        settings: %{
          "site_url" => "https://api-#{System.unique_integer([:positive])}.atlassian.net",
          "auth_mode" => "classic",
          "account_email" => "ops@example.test"
        },
        secret: "synthetic-jira-token",
        enabled: true
      })
      |> Repo.insert!()

    %{project: project, jira: jira}
  end

  defp rule_fixture!(opts \\ []) do
    %{project: project, jira: jira} = base_fixture!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    active? = Keyword.get(opts, :active, false)

    rule =
      %AutomationRule{}
      |> AutomationRule.changeset(
        project
        |> rule_input(jira, %{"source_id" => Keyword.get(opts, :source_id, "42")})
        |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
        |> Map.merge(%{
          enabled: active?,
          activation_status: "idle",
          activated_at: if(active?, do: now),
          baseline_generation: if(active?, do: Ecto.UUID.generate()),
          baseline_complete_at: if(active?, do: now)
        })
      )
      |> Repo.insert!()

    %{project: project, jira: jira, rule: rule}
  end

  defp rule_input(project, jira, overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Pilne sprawy portalu",
        "project_id" => project.id,
        "jira_connection_id" => jira.id,
        "source_type" => "board",
        "source_id" => "42",
        "priority_ids" => ["1", "2"],
        "interval_seconds" => 300,
        "initial_policy" => "new_matches_only",
        "linear_team_id" => @team_id,
        "linear_project_id" => @project_uuid,
        "linear_todo_state_id" => @todo_id,
        "linear_hold_label_id" => @label_id,
        "email_connection_id" => nil,
        "sms_connection_id" => nil,
        "email_recipients" => [],
        "sms_recipients" => []
      },
      overrides
    )
  end

  defp smtp_input(overrides) do
    settings =
      %{
        "host" => "smtp.example.test",
        "port" => 587,
        "tls_mode" => "starttls",
        "username" => "harmony",
        "from_email" => "harmony@example.test",
        "from_name" => "Harmony",
        "message_id_domain" => "example.test"
      }
      |> Map.merge(overrides)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    %{"kind" => "smtp", "name" => "SMTP", "settings" => settings, "secret" => "smtp-password"}
  end

  defp jira_input(overrides) do
    settings =
      %{
        "site_url" => "https://input-#{System.unique_integer([:positive])}.atlassian.net",
        "auth_mode" => "classic",
        "account_email" => "ops@example.test"
      }
      |> Map.merge(overrides)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    %{"kind" => "jira_cloud", "name" => "Jira", "settings" => settings, "secret" => "jira-token"}
  end

  defp smtp_connection! do
    %IntegrationConnection{}
    |> IntegrationConnection.changeset(%{
      kind: "smtp",
      name: "SMTP #{System.unique_integer([:positive])}",
      settings: smtp_input(%{})["settings"],
      secret: "synthetic-smtp-password",
      enabled: true
    })
    |> Repo.insert!()
  end

  defp sms_connection! do
    %IntegrationConnection{}
    |> IntegrationConnection.changeset(%{
      kind: "smsapi",
      name: "SMS #{System.unique_integer([:positive])}",
      settings: %{"sender" => "Harmony"},
      secret: "synthetic-sms-token",
      enabled: true
    })
    |> Repo.insert!()
  end

  defp jira_site(jira), do: jira.settings["site_url"]

  defp existing_case!(project, rule, jira, jira_issue_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %IntakeCase{}
    |> IntakeCase.changeset(%{
      project_id: project.id,
      rule_id: rule.id,
      jira_connection_id: jira.id,
      jira_issue_id: jira_issue_id,
      jira_key: "OPS-1",
      jira_url: "#{jira_site(jira)}/browse/OPS-1",
      title: "Existing case",
      description_text: "",
      priority_id: "1",
      priority_name: "Highest",
      jira_updated_at: now,
      detected_at: now,
      rule_snapshot: %{name: rule.name},
      linear_issue_id: Ecto.UUID.generate(),
      analysis_version: 1,
      analysis_status: "queued",
      lock_version: 1
    })
    |> Repo.insert!()
  end

  defp ready_case!(opts \\ []) do
    %{project: project, jira: jira, rule: rule} = rule_fixture!(source_id: "#{System.unique_integer([:positive])}")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    approved? = Keyword.get(opts, :approved?, false)

    intake_case =
      %IntakeCase{}
      |> IntakeCase.changeset(%{
        project_id: project.id,
        rule_id: rule.id,
        jira_connection_id: jira.id,
        jira_issue_id: "issue-#{System.unique_integer([:positive])}",
        jira_key: "OPS-7",
        jira_url: "#{jira_site(jira)}/browse/OPS-7",
        title: "Synthetic case",
        description_text: "Synthetic description",
        priority_id: "1",
        priority_name: "Highest",
        jira_updated_at: now,
        detected_at: now,
        rule_snapshot: %{name: rule.name},
        linear_issue_id: Ecto.UUID.generate(),
        linear_identifier: "OPS-1",
        linear_url: "https://linear.example/issue/OPS-1",
        linear_state_name: "Todo",
        linear_confirmed_at: now,
        analysis_version: 1,
        analysis_status: "ready",
        repair_approved_at: if(approved?, do: now),
        repair_approved_version: if(approved?, do: 1),
        lock_version: 1
      })
      |> Repo.insert!()

    %IntakeAnalysis{}
    |> IntakeAnalysis.changeset(%{
      case_id: intake_case.id,
      version: 1,
      status: "succeeded",
      input_snapshot: %{"case_ref" => "jira_#{intake_case.id}"},
      result: %{"summary" => "Synthetic result", "needs_input" => false},
      model: "synthetic-analysis-model",
      effort: "medium",
      completed_at: now
    })
    |> Repo.insert!()

    if Keyword.get(opts, :published?, true) do
      %IntegrationDelivery{}
      |> IntegrationDelivery.changeset(%{
        case_id: intake_case.id,
        connection_id: jira.id,
        operation: "jira_comment",
        dedupe_key: "case:#{intake_case.id}:jira-comment:1",
        payload: %{"version" => 1},
        status: "succeeded",
        attempts: 1,
        next_attempt_at: now,
        provider_id: "synthetic-comment",
        sent_at: now
      })
      |> Repo.insert!()
    end

    intake_case
  end

  defp delivery!(connection, status, operation) do
    %IntegrationDelivery{}
    |> IntegrationDelivery.changeset(%{
      connection_id: connection.id,
      operation: operation,
      dedupe_key: "api-test:#{Ecto.UUID.generate()}",
      payload: %{"recipient" => "oncall@example.test"},
      status: status,
      attempts: 1,
      next_attempt_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      last_error_code: if(status in ["failed", "unknown"], do: "synthetic_failure")
    })
    |> Repo.insert!()
  end

  defp jira_issue(index) do
    %{
      "id" => "#{10_000 + index}",
      "key" => "OPS-#{index}",
      "fields" => %{
        "summary" => "Synthetic issue #{index}",
        "description" => nil,
        "priority" => %{"id" => "1", "name" => "Highest"},
        "status" => %{"id" => "1", "name" => "Open", "statusCategory" => %{"key" => "new"}},
        "created" => "2026-09-01T10:00:00.000+0000",
        "updated" => "2026-09-01T10:00:00.000+0000",
        "project" => %{"id" => "1", "key" => "OPS", "name" => "Operations"}
      }
    }
  end

  defp jira_response(request) do
    case Process.get(:jira_status) do
      {status, body} -> {:ok, %{status: status, body: body, headers: %{}}}
      nil -> jira_route(request[:method], URI.parse(request[:url]).path, request)
    end
  end

  defp jira_route(:get, "/rest/api/3/myself", _request), do: ok(%{"accountId" => "synthetic"})

  defp jira_route(:get, "/rest/agile/1.0/board/42/configuration", _request) do
    if Process.get(:jira_board_missing),
      do: {:ok, %{status: 404, body: %{"errorMessages" => ["missing"]}, headers: %{}}},
      else: ok(%{"filter" => %{"id" => "1001"}})
  end

  defp jira_route(:get, "/rest/agile/1.0/board/43/configuration", _request), do: ok(%{"filter" => %{"id" => "1002"}})

  defp jira_route(:post, "/rest/api/3/search/jql", _request) do
    ok(%{"issues" => Process.get(:jira_issues, []), "isLast" => true})
  end

  defp jira_route(:get, "/rest/agile/1.0/board", _request), do: offset_page(Process.get(:jira_boards, []))
  defp jira_route(:get, "/rest/api/3/filter/search", _request), do: offset_page([%{"id" => "1001", "name" => "Pilne"}])

  defp jira_route(:get, "/rest/api/3/priority/search", _request) do
    offset_page(Process.get(:jira_priorities, [%{"id" => "3", "name" => "Highest"}, %{"id" => "1", "name" => "High"}]))
  end

  defp jira_route(_method, _path, _request), do: {:ok, %{status: 404, body: %{}, headers: %{}}}

  defp offset_page(values) do
    ok(%{"values" => values, "startAt" => 0, "maxResults" => 100, "total" => length(values), "isLast" => true})
  end

  defp ok(body), do: {:ok, %{status: 200, body: body, headers: %{}}}

  defp linear_response(%{"query" => query}) do
    if query =~ "issueLabelCreate" do
      ok(%{"data" => %{"issueLabelCreate" => %{"success" => true, "issueLabel" => %{"id" => "88888888-8888-4888-8888-888888888888", "name" => "harmony:analysis-only"}}}})
    else
      labels = Process.get(:linear_labels, [%{"id" => @label_id, "name" => "harmony:analysis-only"}, %{"id" => "other", "name" => "bug"}])

      ok(%{
        "data" => %{
          "teams" => %{
            "pageInfo" => %{"hasNextPage" => false},
            "nodes" => [
              %{
                "id" => Process.get(:linear_team_id, @team_id),
                "key" => "OPS",
                "name" => "Operations",
                "states" => %{
                  "nodes" =>
                    Process.get(:linear_states, [
                      %{"id" => "backlog-id", "name" => "Backlog", "type" => "backlog"},
                      %{"id" => @todo_id, "name" => "Todo", "type" => "unstarted"}
                    ])
                },
                "labels" => %{"nodes" => labels},
                "projects" => %{"nodes" => Process.get(:linear_projects, [%{"id" => @project_uuid, "name" => "Portal"}])}
              }
            ]
          }
        }
      })
    end
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
