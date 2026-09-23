defmodule SymphonyElixir.NotificationsSmtpTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Swoosh.Adapters.SMTP.Helpers, as: SwooshSmtpHelpers
  alias SymphonyElixir.Intake.{Dispatcher, Outbox}
  alias SymphonyElixir.Notifications.{Smtp, Templates}
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{IntegrationConnection, IntegrationDelivery}

  @delivery_id "6f61c847-3a56-4f14-9463-c7b4143f86a1"
  @message_id "<harmony.#{@delivery_id}@example.test>"
  @allowed ["smtp.example.test"]

  describe "templates" do
    test "renders one recipient with a stable Message-ID and a minimal alert" do
      assert {:ok, email} = Templates.render_email(alert_attrs(%{smtp_password: "smtp-password-canary"}))

      assert email.subject == "[Harmony] High · OPS-142 · Finanse"
      assert email.from == {"Harmony", "alerts@example.test"}
      assert email.to == [{"", "oncall@example.test"}]
      assert email.cc == []
      assert email.bcc == []
      assert email.headers["Message-ID"] == @message_id
      assert email.text_body =~ "Analiza została zakolejkowana. Naprawa nie została uruchomiona."
      assert email.html_body =~ "Analiza została zakolejkowana. Naprawa nie została uruchomiona."
      assert email.text_body =~ "https://jira.example.test/browse/OPS-142"
      assert email.text_body =~ "https://harmony.example.test/cases/jira_#{@delivery_id}"
      assert email.text_body =~ "2026-09-22 10:30 UTC"
      refute email.text_body =~ "pełny poufny opis"
      refute email.text_body =~ "linear.example.test"

      for body <- [email.text_body, email.html_body, inspect(email)] do
        refute body =~ "smtp-password-canary"
      end
    end

    test "the Message-ID depends only on the delivery and survives re-rendering for a retry" do
      assert {:ok, first} = Templates.render_email(alert_attrs())
      assert {:ok, second} = Templates.render_email(alert_attrs(%{title: "Zmieniony tytuł"}))

      assert first.headers["Message-ID"] == @message_id
      assert second.headers["Message-ID"] == @message_id

      mime = SwooshSmtpHelpers.body(first, [])
      assert [_single] = Regex.scan(~r/^Message-ID: /m, mime)
      assert mime =~ "Message-ID: #{@message_id}\r\n"
      assert [_single] = Regex.scan(~r/^To: /m, mime)
      refute mime =~ ~r/^(Cc|Bcc): /m
    end

    test "escapes untrusted HTML and excludes descriptions and analysis output" do
      assert {:ok, email} =
               Templates.render_email(
                 alert_attrs(%{
                   title: "<script>alert('title')</script>",
                   description_text: "pełny poufny opis",
                   analysis_result: "sekretna diagnoza",
                   linear_url: "https://linear.example.test/issue/OPS-142"
                 })
               )

      assert email.html_body =~ "&lt;script&gt;alert(&#39;title&#39;)&lt;/script&gt;"
      refute email.html_body =~ "<script>"

      for body <- [email.text_body, email.html_body] do
        refute body =~ "pełny poufny opis"
        refute body =~ "sekretna diagnoza"
        refute body =~ "linear.example.test"
      end
    end

    test "escapes link attributes and rejects links that are not HTTPS" do
      assert {:ok, email} =
               Templates.render_email(alert_attrs(%{jira_url: "https://jira.example.test/browse/OPS-142?a=\"><b>x"}))

      refute email.html_body =~ "\"><b>x"
      assert email.html_body =~ "&quot;&gt;&lt;b&gt;x"

      for url <- ["javascript:alert(1)", "http://jira.example.test/browse/OPS-142", "data:text/html,x"] do
        assert {:error, :invalid_link} = Templates.render_email(alert_attrs(%{jira_url: url}))
        assert {:error, :invalid_link} = Templates.render_email(alert_attrs(%{harmony_url: url}))
      end
    end

    test "rejects CR/LF in every value that reaches an SMTP header" do
      for attrs <- [
            alert_attrs(%{priority_name: "High\r\nBcc: victim@example.test"}),
            alert_attrs(%{jira_key: "OPS-142\nBcc: victim@example.test"}),
            alert_attrs(%{project_name: "Finanse\rBcc: victim@example.test"}),
            alert_attrs(%{from_name: "Harmony\nBcc: victim@example.test"}),
            alert_attrs(%{from_email: "alerts@example.test\r\nBcc: victim@example.test"}),
            alert_attrs(%{recipient: "oncall@example.test\nBcc: victim@example.test"}),
            alert_attrs(%{message_id_domain: "example.test>\r\nBcc: victim@example.test"})
          ] do
        assert {:error, :invalid_header_value} = Templates.render_email(attrs)
      end
    end

    test "accepts exactly one recipient address per message" do
      for recipient <- [
            "oncall@example.test, other@example.test",
            "oncall@example.test;other@example.test",
            "Oncall <oncall@example.test>",
            "not-an-address"
          ] do
        assert {:error, :invalid_address} = Templates.render_email(alert_attrs(%{recipient: recipient}))
      end
    end

    test "requires every field of the alert instead of inventing defaults" do
      for key <- [:delivery_id, :message_id_domain, :recipient, :from_email, :jira_key, :jira_url, :harmony_url] do
        assert {:error, {:missing_field, ^key}} = Templates.render_email(Map.delete(alert_attrs(), key))
      end

      assert {:error, {:missing_field, :delivery_id}} =
               Templates.render_email(alert_attrs(%{delivery_id: "not-a-uuid"}))
    end
  end

  describe "delivery" do
    test "an SMTP timeout is unknown and is never retried automatically" do
      email = email!()
      parent = self()

      smtp_fun = fn _email, smtp_options ->
        send(parent, {:smtp_attempt, smtp_options})
        {:error, {:send, {:network_failure, ~c"smtp.example.test", {:error, :timeout}}}}
      end

      assert {:unknown, "smtp_timeout"} =
               Smtp.deliver_email(email, smtp_connection(),
                 smtp_fun: smtp_fun,
                 smtp_allowed_hosts: @allowed
               )

      assert_received {:smtp_attempt, smtp_options}
      assert smtp_options[:retries] == 0
      refute_received {:smtp_attempt, _smtp_options}
    end

    test "a hung transport is cut at the request timeout and reported as unknown" do
      smtp_fun = fn _email, _smtp_options ->
        Process.sleep(5_000)
        {:ok, "250 late"}
      end

      assert {:unknown, "smtp_timeout"} =
               Smtp.deliver_email(email!(), smtp_connection(),
                 smtp_fun: smtp_fun,
                 smtp_allowed_hosts: @allowed,
                 timeout_ms: 50
               )
    end

    test "a crash inside the transport cannot prove that nothing was sent" do
      assert {:unknown, "smtp_outcome_unknown"} =
               Smtp.deliver_email(email!(), smtp_connection(),
                 smtp_fun: fn _email, _smtp_options -> raise "socket closed after DATA" end,
                 smtp_allowed_hosts: @allowed
               )

      assert {:unknown, "smtp_outcome_unknown"} =
               Smtp.deliver_email(email!(), smtp_connection(),
                 smtp_fun: fn _email, _smtp_options ->
                   {:error, {:send, {:network_failure, ~c"smtp.example.test", {:error, :closed}}}}
                 end,
                 smtp_allowed_hosts: @allowed
               )
    end

    test "classifies definitive SMTP replies separately from uncertain ones" do
      host = ~c"smtp.example.test"

      cases = [
        {{:ok, "2.0.0 Ok: queued as 4F2"}, {:ok, %{provider_id: @message_id}}},
        {{:error, {:send, {:permanent_failure, host, "550 5.1.1 unknown user\r\n"}}}, {:error, "smtp_rejected"}},
        {{:error, {:send, {:temporary_failure, host, "451 4.3.0 try later\r\n"}}}, {:retry, "smtp_temporary_failure", nil}},
        {{:error, {:no_more_hosts, {:permanent_failure, host, :auth_failed}}}, {:error, "smtp_auth_failed"}},
        {{:error, {:no_more_hosts, {:permanent_failure, host, "554 no service\r\n"}}}, {:error, "smtp_rejected"}},
        {{:error, {:retries_exceeded, {:network_failure, host, {:error, :econnrefused}}}}, {:retry, "smtp_unavailable", nil}},
        {{:error, {:retries_exceeded, {:network_failure, host, {:error, :timeout}}}}, {:retry, "smtp_unavailable", nil}},
        {{:error, {:retries_exceeded, {:temporary_failure, host, :tls_failed}}}, {:retry, "smtp_tls_failed", nil}},
        {{:error, {:retries_exceeded, {:missing_requirement, host, :tls}}}, {:error, "smtp_tls_unavailable"}},
        {{:error, {:retries_exceeded, {:missing_requirement, host, :auth}}}, {:error, "smtp_auth_unavailable"}},
        {{:error, :no_credentials}, {:error, "smtp_invalid_settings"}},
        {{:error, :something_new}, {:unknown, "smtp_outcome_unknown"}}
      ]

      for {transport_result, expected} <- cases do
        assert Smtp.deliver_email(email!(), smtp_connection(),
                 smtp_fun: fn _email, _smtp_options -> transport_result end,
                 smtp_allowed_hosts: @allowed
               ) == expected
      end
    end

    test "STARTTLS verifies the peer certificate and host name against the configured relay" do
      smtp_options = captured_options(smtp_connection())

      assert smtp_options[:relay] == "smtp.example.test"
      assert smtp_options[:port] == 587
      assert smtp_options[:ssl] == false
      assert smtp_options[:tls] == :always
      assert smtp_options[:auth] == :always
      assert smtp_options[:no_mx_lookups] == true
      assert smtp_options[:retries] == 0
      assert smtp_options[:username] == "synthetic-user"
      assert smtp_options[:password] == "synthetic-smtp-password"

      tls_options = smtp_options[:tls_options]
      assert tls_options[:verify] == :verify_peer
      assert is_list(tls_options[:cacerts]) and tls_options[:cacerts] != []
      assert tls_options[:server_name_indication] == ~c"smtp.example.test"
      assert is_function(tls_options[:customize_hostname_check][:match_fun])
      refute :tlsv1 in tls_options[:versions]
      refute :"tlsv1.1" in tls_options[:versions]
    end

    test "implicit TLS verifies the peer on the initial socket" do
      smtp_options =
        captured_options(smtp_connection(%{"tls_mode" => "tls", "port" => 465}))

      assert smtp_options[:ssl] == true
      assert smtp_options[:port] == 465
      assert smtp_options[:sockopts][:verify] == :verify_peer
      assert smtp_options[:sockopts][:server_name_indication] == ~c"smtp.example.test"
    end

    test "refuses to send without TLS, credentials or an allowlisted host" do
      no_call = fn _email, _smtp_options -> flunk("SMTP transport must not be called") end

      assert {:error, "smtp_tls_required"} =
               Smtp.deliver_email(email!(), smtp_connection(%{"tls_mode" => "none"}),
                 smtp_fun: no_call,
                 smtp_allowed_hosts: @allowed
               )

      assert {:error, "smtp_host_not_allowed"} =
               Smtp.deliver_email(email!(), smtp_connection(), smtp_fun: no_call, smtp_allowed_hosts: [])

      assert {:error, "smtp_host_not_allowed"} =
               Smtp.deliver_email(email!(), smtp_connection(%{"host" => "evil.example.test"}),
                 smtp_fun: no_call,
                 smtp_allowed_hosts: @allowed
               )

      assert {:error, "smtp_credentials_missing"} =
               Smtp.deliver_email(email!(), %{smtp_connection() | secret: nil},
                 smtp_fun: no_call,
                 smtp_allowed_hosts: @allowed
               )

      assert {:error, "smtp_credentials_missing"} =
               Smtp.deliver_email(email!(), smtp_connection(%{"username" => " "}),
                 smtp_fun: no_call,
                 smtp_allowed_hosts: @allowed
               )
    end

    test "plaintext is limited to an explicit loopback fixture" do
      no_call = fn _email, _smtp_options -> flunk("SMTP transport must not be called") end
      loopback = smtp_connection(%{"host" => "127.0.0.1", "port" => 1025, "tls_mode" => "none"})

      assert {:error, "smtp_tls_required"} =
               Smtp.deliver_email(email!(), loopback, smtp_fun: no_call, smtp_allowed_hosts: ["127.0.0.1"])

      assert {:error, "smtp_tls_required"} =
               Smtp.deliver_email(email!(), smtp_connection(%{"tls_mode" => "none"}),
                 smtp_fun: no_call,
                 smtp_allowed_hosts: @allowed,
                 allow_plaintext_loopback: true
               )

      smtp_options =
        captured_options(loopback, smtp_allowed_hosts: ["127.0.0.1"], allow_plaintext_loopback: true)

      assert smtp_options[:tls] == :never
      assert smtp_options[:ssl] == false
      assert smtp_options[:relay] == "127.0.0.1"
    end

    test "a message with more than one recipient or a missing Message-ID is not sent" do
      no_call = fn _email, _smtp_options -> flunk("SMTP transport must not be called") end
      opts = [smtp_fun: no_call, smtp_allowed_hosts: @allowed]

      assert {:error, "smtp_single_recipient_required"} =
               Smtp.deliver_email(Swoosh.Email.to(email!(), "other@example.test"), smtp_connection(), opts)

      assert {:error, "smtp_single_recipient_required"} =
               Smtp.deliver_email(Swoosh.Email.bcc(email!(), "hidden@example.test"), smtp_connection(), opts)

      assert {:error, "smtp_message_id_required"} =
               Smtp.deliver_email(%{email!() | headers: %{}}, smtp_connection(), opts)
    end

    test "SMTP timeout after DATA leaves the delivery unknown with no automatic resend" do
      :ok = Sandbox.checkout(Repo)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      # The row stays secret-less so the test does not depend on the test CLOAK_KEY;
      # the adapter receives the decrypted secret exactly as the dispatcher would load it.
      connection = %{persisted_smtp_connection!() | secret: "synthetic-smtp-password"}
      delivery = pending_email_delivery!(connection, now)
      parent = self()

      adapter = fn %IntegrationDelivery{} = claimed ->
        send(parent, {:attempt, claimed.id})

        Smtp.deliver_email(email!(), connection,
          smtp_allowed_hosts: @allowed,
          smtp_fun: fn _email, _smtp_options ->
            {:error, {:send, {:network_failure, ~c"smtp.example.test", {:error, :timeout}}}}
          end
        )
      end

      opts = [now: now, intake_enabled: true, effects_enabled: true, operation: "email", connection_id: connection.id]

      assert {:unknown, unknown} = Dispatcher.dispatch_one(adapter, opts)
      assert unknown.id == delivery.id
      assert unknown.status == "unknown"
      assert unknown.last_error_code == "smtp_timeout"
      assert unknown.attempts == 1
      assert_received {:attempt, _id}

      later = DateTime.add(now, 7_200, :second)
      assert :empty = Dispatcher.dispatch_one(adapter, Keyword.put(opts, :now, later))
      assert %{unknown: 0} = Outbox.recover_expired(later)
      refute_received {:attempt, _id}
      assert Repo.get!(IntegrationDelivery, delivery.id).status == "unknown"
    end
  end

  describe "connection check and test-send" do
    test "connection check opens and closes an SMTP session without calling DATA" do
      parent = self()

      open_fun = fn smtp_options ->
        send(parent, {:opened, smtp_options})
        {:ok, :synthetic_smtp_session}
      end

      close_fun = fn session ->
        send(parent, {:closed, session})
        :ok
      end

      data_fun = fn _email, _smtp_options ->
        send(parent, :data_called)
        {:ok, "unexpected"}
      end

      assert :ok =
               Smtp.check_connection(smtp_connection(),
                 smtp_allowed_hosts: @allowed,
                 open_fun: open_fun,
                 close_fun: close_fun,
                 smtp_fun: data_fun
               )

      assert_received {:opened, smtp_options}
      assert smtp_options[:tls] == :always
      assert smtp_options[:auth] == :always
      assert smtp_options[:tls_options][:verify] == :verify_peer
      assert_received {:closed, :synthetic_smtp_session}
      refute_received :data_called
    end

    test "connection check reports EHLO/STARTTLS/AUTH failures as operator error codes" do
      host = ~c"smtp.example.test"

      cases = [
        {{:error, :no_more_hosts, {:permanent_failure, host, :auth_failed}}, "smtp_auth_failed"},
        {{:error, :retries_exceeded, {:missing_requirement, host, :tls}}, "smtp_tls_unavailable"},
        {{:error, :retries_exceeded, {:temporary_failure, host, :tls_failed}}, "smtp_tls_failed"},
        {{:error, :retries_exceeded, {:network_failure, host, {:error, :nxdomain}}}, "smtp_unavailable"},
        {{:error, :bad_option, :no_credentials}, "smtp_invalid_settings"}
      ]

      for {open_result, code} <- cases do
        assert {:error, ^code} =
                 Smtp.check_connection(smtp_connection(),
                   smtp_allowed_hosts: @allowed,
                   open_fun: fn _smtp_options -> open_result end,
                   close_fun: fn _session -> flunk("nothing to close") end
                 )
      end

      assert {:error, "smtp_host_not_allowed"} =
               Smtp.check_connection(smtp_connection(),
                 smtp_allowed_hosts: [],
                 open_fun: fn _smtp_options -> flunk("must not connect") end
               )
    end

    test "test-send requires a separate explicit confirmation" do
      no_call = fn _, _ -> flunk("sent without confirmation") end

      assert {:error, :confirmation_required} =
               Smtp.test_send(smtp_connection(), alert_attrs(), smtp_fun: no_call)

      for confirmation <- ["true", 1, :yes] do
        assert {:error, :confirmation_required} =
                 Smtp.test_send(smtp_connection(), alert_attrs(),
                   smtp_fun: no_call,
                   smtp_allowed_hosts: @allowed,
                   confirm_test_send: confirmation
                 )
      end
    end

    test "a confirmed test-send delivers exactly one message using the connection sender" do
      parent = self()

      smtp_fun = fn email, _smtp_options ->
        send(parent, {:sent, email})
        {:ok, "250 queued"}
      end

      attrs = alert_attrs(%{from_email: "spoofed@example.test", from_name: "Spoofed"})

      assert {:ok, %{provider_id: @message_id}} =
               Smtp.test_send(smtp_connection(), attrs,
                 smtp_fun: smtp_fun,
                 smtp_allowed_hosts: @allowed,
                 confirm_test_send: true
               )

      assert_received {:sent, email}
      assert email.from == {"Harmony", "alerts@example.test"}
      assert email.to == [{"", "oncall@example.test"}]
      refute_received {:sent, _email}
    end
  end

  defp email!, do: Templates.render_email(alert_attrs()) |> elem(1)

  defp captured_options(connection, opts \\ [smtp_allowed_hosts: @allowed]) do
    parent = self()

    smtp_fun = fn _email, smtp_options ->
      send(parent, {:smtp_options, smtp_options})
      {:ok, "250 queued"}
    end

    assert {:ok, _attrs} = Smtp.deliver_email(email!(), connection, Keyword.put(opts, :smtp_fun, smtp_fun))
    assert_received {:smtp_options, smtp_options}
    smtp_options
  end

  defp alert_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        delivery_id: @delivery_id,
        message_id_domain: "example.test",
        recipient: "oncall@example.test",
        from_email: "alerts@example.test",
        from_name: "Harmony",
        priority_name: "High",
        jira_key: "OPS-142",
        project_name: "Finanse",
        title: "Błąd logowania u klientów",
        jira_url: "https://jira.example.test/browse/OPS-142",
        harmony_url: "https://harmony.example.test/cases/jira_#{@delivery_id}",
        detected_at: ~U[2026-09-22 10:30:00Z]
      },
      overrides
    )
  end

  defp smtp_connection(settings_overrides \\ %{}) do
    %IntegrationConnection{
      kind: "smtp",
      enabled: true,
      secret: "synthetic-smtp-password",
      settings: Map.merge(smtp_settings(), settings_overrides)
    }
  end

  defp smtp_settings do
    %{
      "host" => "smtp.example.test",
      "port" => 587,
      "tls_mode" => "starttls",
      "username" => "synthetic-user",
      "from_email" => "alerts@example.test",
      "from_name" => "Harmony",
      "message_id_domain" => "example.test"
    }
  end

  defp persisted_smtp_connection! do
    %IntegrationConnection{}
    |> IntegrationConnection.changeset(%{
      kind: "smtp",
      name: "smtp #{System.unique_integer([:positive])}",
      settings: smtp_settings(),
      enabled: true
    })
    |> Repo.insert!()
  end

  defp pending_email_delivery!(connection, now) do
    %IntegrationDelivery{}
    |> IntegrationDelivery.changeset(%{
      operation: "email",
      connection_id: connection.id,
      dedupe_key: "smtp-test:#{Ecto.UUID.generate()}",
      payload: %{"recipient" => "oncall@example.test"},
      status: "pending",
      attempts: 0,
      next_attempt_at: DateTime.add(now, -1, :second)
    })
    |> Repo.insert!()
  end
end
