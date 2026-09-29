defmodule SymphonyElixir.NotificationSmsapiTest do
  use SymphonyElixir.TestSupport

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Intake.{Dispatcher, Outbox, Poller, Rules}
  alias SymphonyElixir.Notifications.{Smsapi, Templates}
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

  @delivery_id "0b6f5e2e-8d7c-4a51-9f3e-2c1d4b5a6f70"
  @token "synthetic-smsapi-token-canary"
  @endpoint "https://api.smsapi.pl/sms.do"
  @public_url "https://harmony.example.test"
  @smtp_hosts ["smtp.example.test"]

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  describe "SMS template" do
    test "carries only the Jira key, priority and case link" do
      case_url = "#{@public_url}/cases/jira_#{@delivery_id}"

      assert {:ok, message} =
               Templates.render_sms(%{
                 jira_key: "OPS-142",
                 priority_name: "Highest",
                 case_url: case_url,
                 title: "Tajny tytuł zgłoszenia"
               })

      assert message == "Harmony: OPS-142, Highest. Nowa sprawa: #{case_url}"
      refute message =~ "Tajny tytuł"
    end

    test "counts UTF-16 units and rejects a message over 134 units instead of cutting the URL" do
      prefix = "Harmony: OPS-1, Pilne😀. Nowa sprawa: "
      base_url = "https://h.example.test/cases/jira_"
      fitting_url = base_url <> String.duplicate("a", 134 - Templates.sms_units(prefix) - String.length(base_url))
      too_long_url = fitting_url <> "b"

      assert {:ok, message} = Templates.render_sms(%{jira_key: "OPS-1", priority_name: "Pilne😀", case_url: fitting_url})
      assert Templates.sms_units(message) == 134
      assert String.length(message) < 134
      assert String.ends_with?(message, fitting_url)

      assert {:error, :message_too_long} =
               Templates.render_sms(%{jira_key: "OPS-1", priority_name: "Pilne😀", case_url: too_long_url})
    end

    test "requires every field, an HTTPS case link and single-line values" do
      attrs = %{jira_key: "OPS-1", priority_name: "High", case_url: "#{@public_url}/cases/jira_#{@delivery_id}"}

      for key <- [:jira_key, :priority_name, :case_url] do
        assert {:error, {:missing_field, ^key}} = Templates.render_sms(Map.delete(attrs, key))
      end

      assert {:error, :invalid_link} = Templates.render_sms(%{attrs | case_url: "http://harmony.example.test/cases/x"})
      assert {:error, :invalid_header_value} = Templates.render_sms(%{attrs | priority_name: "High\nKup teraz"})
    end
  end

  describe "SMSAPI transport" do
    test "POSTs one form with Bearer auth to the fixed endpoint without secrets in the URL" do
      parent = self()

      request_fun = fn request ->
        send(parent, {:request, request})
        {:ok, %{status: 200, body: accepted_body("sms-id-1")}}
      end

      assert {:ok, %{provider_id: "sms-id-1"}} =
               Smsapi.deliver_sms(sms_attrs(), sms_connection(), request_fun: request_fun)

      assert_received {:request, request}
      refute_received {:request, _another}

      assert request[:method] == :post
      assert request[:url] == @endpoint
      assert request[:retry] == false
      refute Keyword.has_key?(request, :params)
      assert {"authorization", "Bearer #{@token}"} in request[:headers]

      assert Map.new(request[:form]) == %{
               to: "48600100200",
               from: "Harmony",
               message: "Harmony: OPS-142, High. Nowa sprawa: #{@public_url}/cases/jira_#{@delivery_id}",
               format: "json",
               encoding: "utf-8",
               idx: @delivery_id,
               check_idx: "1"
             }

      refute request[:url] =~ @token
      refute request[:url] =~ "600100200"
    end

    test "HTTP 200 with a provider error or a rejected recipient is never success" do
      for {body, expected} <- [
            {%{"error" => 13, "message" => "No correct phone numbers"}, {:error, "sms_invalid_recipient"}},
            {%{"error" => 14, "message" => "Invalid sender"}, {:error, "sms_invalid_sender"}},
            {%{"error" => 101, "message" => "Authorization failed"}, {:error, "sms_auth_failed"}},
            {%{"error" => "103", "message" => "No points"}, {:error, "sms_insufficient_points"}},
            {%{"error" => 203, "message" => "Too many requests"}, {:retry, "sms_provider_busy", nil}},
            {%{"error" => 999, "message" => "Internal error"}, {:unknown, "sms_provider_internal_error"}},
            {%{"error" => 4242, "message" => "Future error"}, {:error, "sms_provider_error"}},
            {accepted_body("sms-id-2", "UNDELIVERED"), {:error, "sms_rejected"}},
            {accepted_body("sms-id-3", "SOMETHING_NEW"), {:unknown, "sms_outcome_unknown"}},
            {%{"count" => 1, "list" => []}, {:unknown, "sms_outcome_unknown"}},
            {%{}, {:unknown, "sms_outcome_unknown"}},
            {"not json", {:unknown, "sms_outcome_unknown"}}
          ] do
        request_fun = fn _request -> {:ok, %{status: 200, body: body}} end
        assert Smsapi.deliver_sms(sms_attrs(), sms_connection(), request_fun: request_fun) == expected
      end
    end

    test "duplicate idx (code 53) means the SMS was already accepted and nothing new is sent" do
      parent = self()

      request_fun = fn request ->
        send(parent, {:idx, Map.new(request[:form])[:idx]})
        {:ok, %{status: 200, body: %{"error" => 53, "message" => "Not unique idx"}}}
      end

      assert {:ok, %{provider_id: nil}} = Smsapi.deliver_sms(sms_attrs(), sms_connection(), request_fun: request_fun)
      assert_received {:idx, @delivery_id}
      refute_received {:idx, _another}
    end

    test "HTTP status and transport failures separate retryable, failed and unknown outcomes" do
      for {response, expected} <- [
            {{:ok, %{status: 401, body: ""}}, {:error, "sms_auth_failed"}},
            {{:ok, %{status: 429, headers: %{"retry-after" => ["120"]}, body: ""}}, {:retry, "sms_rate_limited", "120"}},
            {{:ok, %{status: 400, body: ""}}, {:error, "sms_rejected"}},
            {{:ok, %{status: 502, body: ""}}, {:unknown, "sms_outcome_unknown"}},
            {{:error, %{reason: :econnrefused}}, {:retry, "sms_unavailable", nil}},
            {{:error, %{reason: :timeout}}, {:unknown, "sms_timeout"}},
            {{:error, %{reason: :closed}}, {:unknown, "sms_outcome_unknown"}}
          ] do
        assert Smsapi.deliver_sms(sms_attrs(), sms_connection(), request_fun: fn _request -> response end) == expected
      end
    end

    test "a hung or crashing transport is unknown and never leaks the token" do
      hung = fn _request -> Process.sleep(:infinity) end

      assert {:unknown, "sms_timeout"} =
               Smsapi.deliver_sms(sms_attrs(), sms_connection(), request_fun: hung, timeout_ms: 50)

      log =
        capture_log(fn ->
          crashing = fn request -> raise "transport failed for #{inspect(request[:headers])}" end

          assert {:unknown, "sms_outcome_unknown"} =
                   Smsapi.deliver_sms(sms_attrs(), sms_connection(), request_fun: crashing)
        end)

      refute log =~ @token
      refute log =~ "600100200"
    end

    test "normalizes recipients to E.164 and rejects numbers without a country code" do
      assert {:ok, "+48600100200"} = Smsapi.normalize_phone(" +48 600-100-200 ")
      assert {:ok, "+48600100200"} = Smsapi.normalize_phone("0048 (600) 100 200")

      for invalid <- ["600100200", "48600100200", "+48", "+0600100200", "+48 600 abc 200", "+4860010020012345"] do
        assert {:error, "sms_invalid_recipient"} = Smsapi.normalize_phone(invalid)
      end
    end

    test "invalid input and missing credentials fail before any request" do
      no_request = fn _request -> flunk("must not call SMSAPI") end
      long_message = "Harmony: " <> String.duplicate("ż", 126)

      for {attrs, connection, code} <- [
            {%{sms_attrs() | recipient: "600100200"}, sms_connection(), "sms_invalid_recipient"},
            {%{sms_attrs() | message: long_message}, sms_connection(), "sms_message_too_long"},
            {%{sms_attrs() | delivery_id: "not-a-uuid"}, sms_connection(), "sms_invalid_idx"},
            {sms_attrs(), %{sms_connection() | secret: nil}, "sms_credentials_missing"},
            {sms_attrs(), %{sms_connection() | settings: %{"sender" => " "}}, "sms_invalid_settings"},
            {sms_attrs(), %{sms_connection() | kind: "smtp"}, "sms_invalid_settings"}
          ] do
        assert {:error, ^code} = Smsapi.deliver_sms(attrs, connection, request_fun: no_request)
      end
    end
  end

  describe "dispatcher" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path(), intake_public_url: @public_url)
      :ok
    end

    test "sends the SMS template with the Harmony case link and stores the SMSAPI id" do
      connection = sms_connection!()
      intake_case = case_fixture!()
      delivery = delivery!("sms", connection, case_id: intake_case.id, payload: %{"recipient" => "+48 600 100 200"})
      parent = self()

      request_fun = fn request ->
        send(parent, {:form, Map.new(request[:form])})
        {:ok, %{status: 200, body: accepted_body("sms-accepted-1")}}
      end

      assert {:ok, succeeded} = Dispatcher.dispatch_one(dispatch_opts(now(), "sms", sms_opts: [request_fun: request_fun]))
      assert succeeded.id == delivery.id
      assert succeeded.status == "succeeded"
      assert succeeded.provider_id == "sms-accepted-1"

      assert_received {:form, form}
      assert form.to == "48600100200"
      assert form.idx == delivery.id
      assert form.message == "Harmony: #{intake_case.jira_key}, Highest. Nowa sprawa: #{@public_url}/cases/jira_#{intake_case.id}"
    end

    test "HTTP 200 with a provider error leaves the delivery failed, not succeeded" do
      connection = sms_connection!()
      intake_case = case_fixture!()
      delivery = delivery!("sms", connection, case_id: intake_case.id)
      request_fun = fn _request -> {:ok, %{status: 200, body: %{"error" => 13, "message" => "No correct phone numbers"}}} end

      assert {:failed, failed} = Dispatcher.dispatch_one(dispatch_opts(now(), "sms", sms_opts: [request_fun: request_fun]))
      assert failed.id == delivery.id
      assert failed.status == "failed"
      assert failed.last_error_code == "sms_invalid_recipient"
      assert is_nil(failed.provider_id)
    end

    test "an uncertain SMS stays unknown; a confirmed retry reuses the idx and code 53 completes it" do
      connection = sms_connection!()
      intake_case = case_fixture!()
      delivery = delivery!("sms", connection, case_id: intake_case.id)
      parent = self()
      scripted = [{:error, %{reason: :timeout}}, {:ok, %{status: 200, body: %{"error" => 53}}}]
      {:ok, responses} = Agent.start_link(fn -> scripted end)

      request_fun = fn request ->
        send(parent, {:form, Map.new(request[:form])})
        Agent.get_and_update(responses, fn [next | rest] -> {next, rest} end)
      end

      opts = dispatch_opts(now(), "sms", sms_opts: [request_fun: request_fun])

      assert {:unknown, unknown} = Dispatcher.dispatch_one(opts)
      assert unknown.id == delivery.id
      assert unknown.last_error_code == "sms_timeout"
      assert_received {:form, first_form}

      later = DateTime.add(now(), 7_200, :second)
      assert :empty = Dispatcher.dispatch_one(Keyword.put(opts, :now, later))
      assert %{unknown: 0} = Outbox.recover_expired(later)
      refute_received {:form, _form}

      assert {:ok, _retrying} = Outbox.manual_retry(delivery.id, confirm_duplicate_risk: true, now: later)
      assert {:ok, accepted} = Dispatcher.dispatch_one(Keyword.put(opts, :now, later))
      assert accepted.status == "succeeded"
      assert accepted.attempts == 2

      assert_received {:form, second_form}
      assert first_form.idx == delivery.id
      assert second_form.idx == delivery.id
      assert second_form.check_idx == "1"
      refute_received {:form, _form}
    end

    test "a missing Harmony public URL is an explicit error instead of an invented link" do
      write_workflow_file!(Workflow.workflow_file_path(), intake_public_url: nil)
      intake_case = case_fixture!()
      sms = delivery!("sms", sms_connection!(), case_id: intake_case.id)
      email = delivery!("email", smtp_connection!(), case_id: intake_case.id, payload: %{"recipient" => "oncall@example.test"})
      no_request = fn _request -> flunk("must not call SMSAPI") end
      no_smtp = fn _email, _options -> flunk("must not call SMTP") end

      assert {:failed, failed_sms} =
               Dispatcher.dispatch_one(dispatch_opts(now(), "sms", sms_opts: [request_fun: no_request]))

      assert failed_sms.id == sms.id
      assert failed_sms.last_error_code == "missing_intake_public_url"

      assert {:failed, failed_email} = Dispatcher.dispatch_one(dispatch_opts(now(), "email", smtp_opts: smtp_opts(no_smtp)))
      assert failed_email.id == email.id
      assert failed_email.last_error_code == "missing_intake_public_url"
    end

    test "an unknown SMS does not block e-mail, Linear or analysis" do
      intake_case = case_fixture!()
      sms = delivery!("sms", sms_connection!(), case_id: intake_case.id)
      email = delivery!("email", smtp_connection!(), case_id: intake_case.id, payload: %{"recipient" => "oncall@example.test"})
      linear = delivery!("linear_create", nil, case_id: intake_case.id, payload: %{"linear_issue_id" => intake_case.linear_issue_id})
      analysis = delivery!("analysis", nil, case_id: intake_case.id, payload: %{"version" => 1})
      queued_analysis!(intake_case)
      parent = self()

      smtp_fun = fn email_message, _options ->
        send(parent, {:smtp, email_message})
        {:ok, "250 queued"}
      end

      failing_sms = fn _request -> {:ok, %{status: 503, body: ""}} end
      now = now()

      assert {:unknown, unknown_sms} =
               Dispatcher.dispatch_one(dispatch_opts(now, "sms", sms_opts: [request_fun: failing_sms]))

      assert unknown_sms.id == sms.id

      assert {:ok, sent_email} = Dispatcher.dispatch_one(dispatch_opts(now, "email", smtp_opts: smtp_opts(smtp_fun)))
      assert sent_email.id == email.id
      assert sent_email.provider_id == "<harmony.#{email.id}@example.test>"
      assert_received {:smtp, email_message}
      assert email_message.to == [{"", "oncall@example.test"}]
      assert email_message.text_body =~ "#{@public_url}/cases/jira_#{intake_case.id}"

      for {operation, expected} <- [{"linear_create", linear}, {"analysis", analysis}] do
        assert {:ok, completed} =
                 Dispatcher.dispatch_one(fn claimed -> {:ok, %{provider_id: "#{claimed.operation}-ok"}} end, dispatch_opts(now, operation))

        assert completed.id == expected.id
      end

      statuses =
        Repo.all(from(d in IntegrationDelivery, where: d.case_id == ^intake_case.id, select: {d.operation, d.status}))

      assert Enum.sort(statuses) == [
               {"analysis", "succeeded"},
               {"email", "succeeded"},
               {"linear_create", "succeeded"},
               {"sms", "unknown"}
             ]
    end

    test "a test-send counts toward the hourly SMS limit and is limited itself" do
      connection = sms_connection!()
      intake_case = case_fixture!()
      now = now()
      test_send = delivery!("sms", connection, payload: %{"recipient" => "+48600100200", "test_send" => true}, next_attempt_at: DateTime.add(now, -60, :second))

      case_deliveries =
        Enum.map(1..20, fn index ->
          delivery!("sms", connection,
            case_id: intake_case.id,
            payload: %{"recipient" => "+486001002#{String.pad_leading("#{index}", 2, "0")}"},
            next_attempt_at: DateTime.add(now, -30, :second)
          )
        end)

      parent = self()

      request_fun = fn request ->
        send(parent, {:sms, Map.new(request[:form])})
        {:ok, %{status: 200, body: accepted_body("sms-#{System.unique_integer([:positive])}")}}
      end

      opts = dispatch_opts(now, "sms", sms_opts: [request_fun: request_fun])

      assert {:ok, test_sent} = Dispatcher.dispatch_one(opts)
      assert test_sent.id == test_send.id
      assert_received {:sms, test_form}
      assert test_form.message == Templates.render_test_sms()

      results = drain(opts)
      assert length(results) == 19
      assert Enum.all?(results, &match?({:ok, _delivery}, &1))

      limited = Enum.map(case_deliveries, &Repo.get!(IntegrationDelivery, &1.id)) |> Enum.filter(&(&1.status == "retry_wait"))
      assert [%IntegrationDelivery{last_error_code: "rate_limited", attempts: 0} = waiting] = limited
      assert DateTime.diff(waiting.next_attempt_at, now, :second) == 3_600

      # Due at the claim clock `now`, not at the wall clock of this insert.
      second_test_send =
        delivery!("sms", connection,
          payload: %{"recipient" => "+48600100200", "test_send" => true},
          next_attempt_at: DateTime.add(now, -60, :second)
        )

      assert :empty = Dispatcher.dispatch_one(opts)
      assert Repo.get!(IntegrationDelivery, second_test_send.id).last_error_code == "rate_limited"
      assert sms_requests() == 19
    end

    test "default hourly limits are 60 e-mails and 20 SMS per connection, resuming in the next window" do
      now = now()
      smtp = smtp_connection!()
      sms = sms_connection!()
      Enum.each(1..61, fn _index -> delivery!("email", smtp) end)
      Enum.each(1..21, fn _index -> delivery!("sms", sms) end)
      adapter = fn claimed -> {:ok, %{provider_id: "accepted-#{claimed.id}"}} end

      for {operation, connection, limit} <- [{"email", smtp, 60}, {"sms", sms, 20}] do
        opts = dispatch_opts(now, operation, connection_id: connection.id)
        assert length(drain(adapter, opts)) == limit

        [waiting] =
          Repo.all(from(d in IntegrationDelivery, where: d.connection_id == ^connection.id and d.status == "retry_wait"))

        assert waiting.last_error_code == "rate_limited"
        assert DateTime.diff(waiting.next_attempt_at, now, :second) == 3_600

        next_window = DateTime.add(now, 3_601, :second)
        assert {:ok, resumed} = Dispatcher.dispatch_one(adapter, Keyword.put(opts, :now, next_window))
        assert resumed.id == waiting.id
      end
    end

    test "two parallel dispatchers on PostgreSQL never exceed 20 SMS per hour on one connection" do
      ids = committed_sms_fixture!(25)
      on_exit(fn -> cleanup_committed_sms_fixture!(ids) end)
      {:ok, calls} = Agent.start_link(fn -> [] end)
      now = now()

      request_fun = fn request ->
        Agent.update(calls, &[Map.new(request[:form])[:idx] | &1])
        Process.sleep(5)
        {:ok, %{status: 200, body: accepted_body("sms-#{System.unique_integer([:positive])}")}}
      end

      opts = dispatch_opts(now, "sms", connection_id: ids.connection, sms_opts: [request_fun: request_fun])
      parent = self()

      dispatchers =
        Enum.map(1..2, fn _index ->
          Task.async(fn ->
            send(parent, {:ready, self()})
            receive do: (:go -> :ok)
            Sandbox.unboxed_run(Repo, fn -> drain(opts) end)
          end)
        end)

      pids =
        for _index <- 1..2 do
          assert_receive {:ready, pid}, 5_000
          pid
        end

      Enum.each(pids, &send(&1, :go))
      results = Enum.flat_map(dispatchers, &Task.await(&1, 30_000))

      sent_idx = Agent.get(calls, & &1)
      assert length(sent_idx) == 20
      assert length(Enum.uniq(sent_idx)) == 20
      assert Enum.count(results, &match?({:ok, _delivery}, &1)) == 20

      Sandbox.unboxed_run(Repo, fn ->
        statuses =
          Repo.all(from(d in IntegrationDelivery, where: d.id in ^ids.deliveries, select: {d.status, d.last_error_code}))

        assert Enum.frequencies(statuses) == %{{"succeeded", nil} => 20, {"retry_wait", "rate_limited"} => 5}

        attempts =
          Repo.aggregate(
            from(e in IntakeEvent, where: e.type == "delivery_attempt" and e.payload["connection_id"] == ^ids.connection),
            :count,
            :id
          )

        assert attempts == 20
      end)
    end
  end

  describe "intake flow" do
    test "two scans and two channels give every recipient exactly one logical delivery" do
      write_workflow_file!(Workflow.workflow_file_path(), intake_effects_enabled: true, intake_public_url: @public_url)
      smtp = smtp_connection!()
      sms = sms_connection!()

      rule =
        rule!(%{
          email_connection_id: smtp.id,
          email_recipients: ["oncall@example.test", "Lead@Example.TEST"],
          sms_connection_id: sms.id,
          sms_recipients: ["+48600100200", "+48600100201"]
        })

      assert {:ok, _activating} = Rules.activate(rule)
      assert {:ok, _baseline} = Poller.run(rule.id, poll_opts([page([])]))
      assert {:ok, first_scan} = Poller.run(rule.id, poll_opts([page([jira_issue()])]))
      assert {:ok, second_scan} = Poller.run(rule.id, poll_opts([page([jira_issue()])]))
      assert first_scan.accepted_count == 1
      assert second_scan.accepted_count == 0

      intake_case = Repo.one!(IntakeCase)

      deliveries =
        Repo.all(from(d in IntegrationDelivery, where: d.case_id == ^intake_case.id and d.operation in ["email", "sms"]))

      assert deliveries |> Enum.map(&{&1.operation, &1.payload["recipient"]}) |> Enum.sort() == [
               {"email", "Lead@example.test"},
               {"email", "oncall@example.test"},
               {"sms", "+48600100200"},
               {"sms", "+48600100201"}
             ]

      parent = self()

      smtp_fun = fn email, _options ->
        send(parent, {:sent, :email, email.to, email.headers["Message-ID"]})
        {:ok, "250 queued"}
      end

      request_fun = fn request ->
        form = Map.new(request[:form])
        send(parent, {:sent, :sms, form.to, form.idx})
        {:ok, %{status: 200, body: accepted_body("sms-#{form.idx}")}}
      end

      opts = [smtp_opts: smtp_opts(smtp_fun), sms_opts: [request_fun: request_fun]]
      dispatch_at = ~U[2026-09-23 10:00:05.000000Z]

      for _round <- 1..2, operation <- ["email", "sms"] do
        drain(dispatch_opts(dispatch_at, operation, opts))
      end

      sent = collect_sent()

      assert sent |> Enum.map(fn {channel, to, _id} -> {channel, to} end) |> Enum.sort() == [
               {:email, [{"", "Lead@example.test"}]},
               {:email, [{"", "oncall@example.test"}]},
               {:sms, "48600100200"},
               {:sms, "48600100201"}
             ]

      delivery_ids = MapSet.new(deliveries, & &1.id)
      assert sent |> Enum.map(fn {_channel, _to, id} -> id end) |> Enum.uniq() |> length() == 4

      for {channel, _to, id} <- sent do
        delivery_id = if channel == :email, do: id |> String.trim_leading("<harmony.") |> String.split("@") |> hd(), else: id
        assert MapSet.member?(delivery_ids, delivery_id)
      end

      assert Repo.all(from(d in IntegrationDelivery, where: d.id in ^MapSet.to_list(delivery_ids), select: d.status)) ==
               List.duplicate("succeeded", 4)
    end
  end

  defp drain(opts), do: drain(nil, opts)

  defp drain(adapter, opts) do
    result = if adapter, do: Dispatcher.dispatch_one(adapter, opts), else: Dispatcher.dispatch_one(opts)

    case result do
      :empty -> []
      {:error, reason} -> flunk("dispatch failed: #{inspect(reason)}")
      other -> [other | drain(adapter, opts)]
    end
  end

  defp sms_requests(count \\ 0) do
    receive do
      {:sms, _form} -> sms_requests(count + 1)
    after
      0 -> count
    end
  end

  defp collect_sent(acc \\ []) do
    receive do
      {:sent, channel, to, id} -> collect_sent([{channel, to, id} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp dispatch_opts(now, operation, overrides \\ []) do
    defaults = [now: now, intake_enabled: true, effects_enabled: true, analysis_enabled: true, jitter: fn -> 0.0 end]
    defaults |> Keyword.put(:operation, operation) |> Keyword.merge(overrides)
  end

  defp smtp_opts(smtp_fun), do: [smtp_fun: smtp_fun, smtp_allowed_hosts: @smtp_hosts, cacerts: [:synthetic_ca]]

  defp sms_attrs do
    %{
      delivery_id: @delivery_id,
      recipient: "+48 600 100 200",
      message: "Harmony: OPS-142, High. Nowa sprawa: #{@public_url}/cases/jira_#{@delivery_id}"
    }
  end

  defp sms_connection do
    %IntegrationConnection{kind: "smsapi", enabled: true, secret: @token, settings: %{"sender" => "Harmony"}}
  end

  defp accepted_body(id, status \\ "QUEUE") do
    %{
      "count" => 1,
      "list" => [%{"id" => id, "points" => 0.16, "number" => "48600100200", "status" => status, "idx" => @delivery_id}]
    }
  end

  defp sms_connection! do
    insert_connection!(%{kind: "smsapi", settings: %{"sender" => "Harmony"}, secret: @token})
  end

  defp smtp_connection! do
    insert_connection!(%{
      kind: "smtp",
      settings: %{
        "host" => "smtp.example.test",
        "port" => 587,
        "tls_mode" => "starttls",
        "username" => "synthetic-user",
        "from_email" => "alerts@example.test",
        "from_name" => "Harmony",
        "message_id_domain" => "example.test"
      },
      secret: "synthetic-smtp-password"
    })
  end

  defp insert_connection!(attrs) do
    %IntegrationConnection{}
    |> IntegrationConnection.changeset(Map.merge(%{name: "#{attrs.kind} #{System.unique_integer([:positive])}", enabled: true}, attrs))
    |> Repo.insert!()
  end

  defp delivery!(operation, connection, attrs) do
    attrs = Map.new(attrs)

    defaults = %{
      operation: operation,
      connection_id: connection && connection.id,
      dedupe_key: "smsapi-test:#{Ecto.UUID.generate()}",
      payload: %{"recipient" => "+48600100200"},
      status: "pending",
      attempts: 0,
      next_attempt_at: DateTime.add(now(), -1, :second)
    }

    %IntegrationDelivery{}
    |> IntegrationDelivery.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp delivery!(operation, connection), do: delivery!(operation, connection, [])

  defp case_fixture! do
    jira = insert_connection!(%{kind: "jira_cloud", settings: %{"site_url" => "https://smsapi-#{System.unique_integer([:positive])}.atlassian.net"}})
    project = project!()

    rule =
      %AutomationRule{}
      |> AutomationRule.changeset(%{
        project_id: project.id,
        jira_connection_id: jira.id,
        name: "SMS rule",
        source_type: "board",
        source_id: "42",
        priority_ids: ["1"],
        interval_seconds: 300,
        initial_policy: "new_matches_only",
        linear_team_id: "team",
        linear_project_id: "project",
        linear_todo_state_id: "todo",
        linear_hold_label_id: "hold",
        email_recipients: [],
        sms_recipients: [],
        enabled: false,
        config_version: 1,
        activation_status: "idle",
        lock_version: 1
      })
      |> Repo.insert!()

    timestamp = now()

    %IntakeCase{}
    |> IntakeCase.changeset(%{
      project_id: project.id,
      rule_id: rule.id,
      jira_connection_id: jira.id,
      jira_issue_id: Ecto.UUID.generate(),
      jira_key: "OPS-#{System.unique_integer([:positive])}",
      jira_url: "https://example.atlassian.net/browse/OPS-1",
      title: "Awaria logowania",
      description_text: "Pełny poufny opis",
      priority_id: "1",
      priority_name: "Highest",
      jira_updated_at: timestamp,
      detected_at: timestamp,
      rule_snapshot: %{"project_name" => project.slug},
      linear_issue_id: Ecto.UUID.generate(),
      linear_confirmed_at: timestamp,
      analysis_version: 1,
      analysis_status: "queued",
      lock_version: 1
    })
    |> Repo.insert!()
  end

  defp queued_analysis!(intake_case) do
    %IntakeAnalysis{}
    |> IntakeAnalysis.changeset(%{
      case_id: intake_case.id,
      version: 1,
      status: "queued",
      input_snapshot: %{},
      model: "analysis-model",
      effort: "low"
    })
    |> Repo.insert!()
  end

  defp project! do
    %Project{}
    |> Project.changeset(%{
      slug: "smsapi-project-#{System.unique_integer([:positive])}",
      forge_owner: "example",
      forge_repo: "harmony",
      forge_base_branch: "main",
      config: %{},
      config_version: 1,
      ui_color: "purple"
    })
    |> Repo.insert!()
  end

  defp rule!(channels) do
    project = project!()

    jira =
      insert_connection!(%{
        kind: "jira_cloud",
        settings: %{"site_url" => "https://harmony.atlassian.net", "auth_mode" => "classic", "account_email" => "harmony@example.test"},
        secret: "synthetic-jira-token"
      })

    {:ok, rule} =
      Rules.create(
        Map.merge(
          %{
            project_id: project.id,
            jira_connection_id: jira.id,
            name: "Two channel rule",
            source_type: "board",
            source_id: "42",
            priority_ids: ["1"],
            interval_seconds: 300,
            initial_policy: "new_matches_only",
            linear_team_id: "team-id",
            linear_project_id: "project-id",
            linear_todo_state_id: "todo-id",
            linear_hold_label_id: "hold-id"
          },
          channels
        )
      )

    rule
  end

  defp poll_opts(pages) do
    {:ok, agent} = Agent.start_link(fn -> pages end)

    [
      request_fun: fn request -> jira_response(request, agent) end,
      clock: fn -> ~U[2026-09-23 10:00:00Z] end,
      uuid_fun: &Ecto.UUID.generate/0,
      analysis_enabled: true,
      analysis_model: "synthetic-test-model",
      analysis_effort: "low"
    ]
  end

  defp jira_response(request, agent) do
    case Keyword.fetch!(request, :method) do
      :get -> {:ok, %{status: 200, body: %{"filter" => %{"id" => "77"}}}}
      :post -> {:ok, %{status: 200, body: Agent.get_and_update(agent, &next_page/1)}}
    end
  end

  defp next_page([next | rest]), do: {next, rest}

  defp page(issues), do: %{"issues" => issues, "isLast" => true}

  defp jira_issue do
    %{
      "id" => "10001",
      "key" => "OPS-1",
      "fields" => %{
        "summary" => "Dwa kanały powiadomień",
        "description" => nil,
        "priority" => %{"id" => "1", "name" => "P1"},
        "status" => %{"id" => "1", "name" => "Open", "statusCategory" => %{"key" => "new"}},
        "created" => "2026-09-22T00:00:00.000+0000",
        "updated" => "2026-09-23T09:00:00.000+0000",
        "project" => %{"id" => "7", "key" => "OPS", "name" => "Operations"}
      }
    }
  end

  defp committed_sms_fixture!(count) do
    Sandbox.unboxed_run(Repo, fn ->
      connection = sms_connection!()
      deliveries = Enum.map(1..count, fn _index -> delivery!("sms", connection, payload: %{"recipient" => "+48600100200", "test_send" => true}) end)
      %{connection: connection.id, deliveries: Enum.map(deliveries, & &1.id)}
    end)
  end

  defp cleanup_committed_sms_fixture!(%{connection: connection_id, deliveries: delivery_ids}) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.delete_all(from(e in IntakeEvent, where: fragment("?->>'delivery_id'", e.payload) in ^delivery_ids))
      Repo.delete_all(from(d in IntegrationDelivery, where: d.id in ^delivery_ids))
      Repo.delete_all(from(c in IntegrationConnection, where: c.id == ^connection_id))
    end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
