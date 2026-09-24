defmodule SymphonyElixir.IntakeApiSecurityTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3, get_resp_header: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Storage.{AutomationRule, IntegrationConnection, IntegrationDelivery}

  @endpoint SymphonyElixirWeb.Endpoint
  @origin "http://www.example.com"
  @smtp_secret "smtp-password-canary-7f3a"
  @jira_secret "jira-api-token-canary-91bd"

  setup do
    :ok = Sandbox.checkout(Repo)

    write_workflow_file!(Workflow.workflow_file_path(),
      intake_effects_enabled: true,
      intake_smtp_allowed_hosts: ["smtp.example.test"]
    )

    start_test_endpoint()
    :ok
  end

  describe "CSRF bootstrap" do
    test "GET /api/v1/csrf returns a session token that is never cached" do
      conn = get(build_conn(), "/api/v1/csrf")

      assert %{"csrf_token" => token} = json_response(conn, 200)
      assert is_binary(token) and byte_size(token) > 20
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert [cookie | _] = get_resp_header(conn, "set-cookie")
      assert cookie =~ "_symphony_elixir_key="
      assert String.downcase(cookie) =~ "httponly"
      assert String.downcase(cookie) =~ "samesite=strict"
    end

    test "the CSRF endpoint only answers GET" do
      conn = post(build_conn(), "/api/v1/csrf")
      assert json_response(conn, 405)["error"]["code"] == "method_not_allowed"
    end
  end

  describe "mutation guard" do
    test "a mutation without a CSRF token is refused before any action runs" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", @origin)
        |> post("/api/v1/integrations", Jason.encode!(smtp_input()))

      assert %{"error" => %{"code" => "csrf_invalid", "message" => message}} = json_response(conn, 403)
      assert is_binary(message)
      assert Repo.aggregate(IntegrationConnection, :count) == 0
    end

    test "a foreign or missing Origin is refused even with a valid session token" do
      {session, token} = csrf_session()

      foreign =
        session
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "https://attacker.example")
        |> put_req_header("x-csrf-token", token)
        |> post("/api/v1/integrations", Jason.encode!(smtp_input()))

      assert json_response(foreign, 403)["error"]["code"] == "origin_rejected"

      missing =
        session
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-csrf-token", token)
        |> post("/api/v1/integrations", Jason.encode!(smtp_input()))

      assert json_response(missing, 403)["error"]["code"] == "origin_rejected"

      cross_site =
        session
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", @origin)
        |> put_req_header("sec-fetch-site", "cross-site")
        |> put_req_header("x-csrf-token", token)
        |> post("/api/v1/integrations", Jason.encode!(smtp_input()))

      assert json_response(cross_site, 403)["error"]["code"] == "origin_rejected"
      assert Repo.aggregate(IntegrationConnection, :count) == 0
    end

    test "a form-encoded cross-site style request is refused" do
      {session, token} = csrf_session()

      conn =
        session
        |> recycle()
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header("origin", @origin)
        |> put_req_header("x-csrf-token", token)
        |> post("/api/v1/integrations", "kind=smtp&name=x")

      assert json_response(conn, 415)["error"]["code"] == "json_required"
      assert Repo.aggregate(IntegrationConnection, :count) == 0
    end

    test "a token from a previous session is refused after the session restarts" do
      {_old_session, stale_token} = csrf_session()
      {fresh_session, _fresh_token} = csrf_session()

      conn =
        fresh_session
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", @origin)
        |> put_req_header("x-csrf-token", stale_token)
        |> post("/api/v1/integrations", Jason.encode!(smtp_input()))

      assert json_response(conn, 403)["error"]["code"] == "csrf_invalid"
      assert Repo.aggregate(IntegrationConnection, :count) == 0

      no_cookie =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", @origin)
        |> put_req_header("x-csrf-token", stale_token)
        |> post("/api/v1/integrations", Jason.encode!(smtp_input()))

      assert json_response(no_cookie, 403)["error"]["code"] == "csrf_invalid"
    end

    test "every new mutation route is guarded" do
      id = Ecto.UUID.generate()

      routes = [
        {:post, "/api/v1/automations"},
        {:patch, "/api/v1/automations/#{id}"},
        {:post, "/api/v1/automations/#{id}/preview"},
        {:post, "/api/v1/automations/#{id}/activate"},
        {:post, "/api/v1/automations/#{id}/pause"},
        {:post, "/api/v1/automations/#{id}/check"},
        {:post, "/api/v1/automations/check"},
        {:post, "/api/v1/integrations"},
        {:patch, "/api/v1/integrations/#{id}"},
        {:post, "/api/v1/integrations/#{id}/test"},
        {:post, "/api/v1/integrations/#{id}/test-send"},
        {:post, "/api/v1/projects/#{id}/linear-hold-label"},
        {:post, "/api/v1/cases/jira_#{id}/acknowledge"},
        {:post, "/api/v1/cases/jira_#{id}/approve-repair"},
        {:post, "/api/v1/cases/jira_#{id}/reanalyze"},
        {:post, "/api/v1/deliveries/#{id}/retry"}
      ]

      for {method, path} <- routes do
        conn =
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("origin", @origin)
          |> dispatch(@endpoint, method, path, "{}")

        assert json_response(conn, 403)["error"]["code"] == "csrf_invalid", "#{method} #{path} was not guarded"
      end
    end

    test "CORS is not widened for the new API" do
      conn =
        build_conn()
        |> put_req_header("origin", "https://attacker.example")
        |> put_req_header("access-control-request-method", "POST")
        |> options("/api/v1/integrations")

      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert conn.status == 405
    end
  end

  describe "secrets and error bodies" do
    test "connection secrets are write-only in every response" do
      {session, token} = csrf_session()

      created = mutate(session, token, :post, "/api/v1/integrations", smtp_input())
      body = response(created, 201)
      refute body =~ @smtp_secret
      assert %{"connection" => %{"id" => id, "secret_state" => "set"} = connection} = Jason.decode!(body)
      refute Map.has_key?(connection, "secret")

      jira = mutate(session, token, :post, "/api/v1/integrations", jira_input())
      refute response(jira, 201) =~ @jira_secret

      for path <- ["/api/v1/integrations", "/api/v1/integrations/#{id}"] do
        listed = get(build_conn(), path)
        refute response(listed, 200) =~ @smtp_secret
        refute response(listed, 200) =~ @jira_secret
      end

      patched =
        mutate(session, token, :patch, "/api/v1/integrations/#{id}", %{
          "version" => connection["lock_version"],
          "name" => "SMTP renamed",
          "secret" => "rotated-canary-5511"
        })

      patched_body = response(patched, 200)
      refute patched_body =~ "rotated-canary-5511"
      refute patched_body =~ @smtp_secret
      assert Repo.get!(IntegrationConnection, id).secret == "rotated-canary-5511"
    end

    test "domain failures never return raw exceptions or stacktraces" do
      {session, token} = csrf_session()

      invalid_id = get(build_conn(), "/api/v1/automations/not-a-uuid")
      assert json_response(invalid_id, 404)["error"]["code"] == "not_found"

      bad_input = mutate(session, token, :post, "/api/v1/automations", %{"name" => 12, "priority_ids" => "1"})
      body = response(bad_input, 422)
      refute body =~ "Ecto."
      refute body =~ "** ("
      assert %{"error" => %{"code" => "validation_failed", "fields" => fields}} = Jason.decode!(body)
      assert is_map(fields)

      malformed =
        assert_error_sent(400, fn ->
          session
          |> recycle()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("accept", "application/json")
          |> put_req_header("origin", @origin)
          |> put_req_header("x-csrf-token", token)
          |> post("/api/v1/automations", "{not json")
        end)

      {400, _headers, malformed_body} = malformed
      refute malformed_body =~ "Jason"
      assert %{"error" => %{"code" => _code}} = Jason.decode!(malformed_body)
    end
  end

  describe "forge webhooks keep their own verification" do
    test "a signed GitHub webhook is accepted without session, CSRF or Origin" do
      Application.put_env(:symphony_elixir, :github_webhook_secret, "hook-secret")
      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_webhook_secret) end)

      body = Jason.encode!(%{"zen" => "ping"})
      signature = "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, "hook-secret", body), case: :lower)

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "https://github.example")
        |> put_req_header("x-github-event", "ping")
        |> put_req_header("x-hub-signature-256", signature)
        |> post("/api/v1/github/webhook", body)

      assert json_response(conn, 202)["status"] == "ignored"

      unsigned =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "ping")
        |> put_req_header("x-hub-signature-256", "sha256=bad")
        |> post("/api/v1/github/webhook", body)

      assert json_response(unsigned, 401)["error"]["code"] == "invalid_signature"
    end

    test "a GitLab webhook still uses its own token check" do
      Application.put_env(:symphony_elixir, :gitlab_webhook_secret, "gitlab-hook-secret")
      on_exit(fn -> Application.delete_env(:symphony_elixir, :gitlab_webhook_secret) end)

      rejected =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-gitlab-token", "wrong")
        |> put_req_header("x-gitlab-event", "Push Hook")
        |> post("/api/v1/gitlab/webhook", Jason.encode!(%{"object_kind" => "push"}))

      assert json_response(rejected, 401)["error"]["code"] == "invalid_token"

      accepted =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "https://gitlab.example")
        |> put_req_header("x-gitlab-token", "gitlab-hook-secret")
        |> put_req_header("x-gitlab-event", "Push Hook")
        |> post("/api/v1/gitlab/webhook", Jason.encode!(%{"object_kind" => "push"}))

      assert json_response(accepted, 200)["status"] == "ignored"
    end
  end

  test "a bulk check without the guard changes nothing" do
    rule_count = Repo.aggregate(AutomationRule, :count)
    delivery_count = Repo.aggregate(IntegrationDelivery, :count)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", @origin)
      |> post("/api/v1/automations/check", "{}")

    assert json_response(conn, 403)["error"]["code"] == "csrf_invalid"
    assert Repo.aggregate(AutomationRule, :count) == rule_count
    assert Repo.aggregate(IntegrationDelivery, :count) == delivery_count
  end

  defp smtp_input do
    %{
      "kind" => "smtp",
      "name" => "SMTP",
      "settings" => %{
        "host" => "smtp.example.test",
        "port" => 587,
        "tls_mode" => "starttls",
        "username" => "harmony",
        "from_email" => "harmony@example.test",
        "from_name" => "Harmony",
        "message_id_domain" => "example.test"
      },
      "secret" => @smtp_secret
    }
  end

  defp jira_input do
    %{
      "kind" => "jira_cloud",
      "name" => "Jira",
      "settings" => %{
        "site_url" => "https://security-#{System.unique_integer([:positive])}.atlassian.net",
        "auth_mode" => "classic",
        "account_email" => "ops@example.test"
      },
      "secret" => @jira_secret
    }
  end

  defp csrf_session do
    conn = get(build_conn(), "/api/v1/csrf")
    {conn, json_response(conn, 200)["csrf_token"]}
  end

  defp mutate(session, token, method, path, body) do
    session
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("origin", @origin)
    |> put_req_header("x-csrf-token", token)
    |> dispatch(@endpoint, method, path, Jason.encode!(body))
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
