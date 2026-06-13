# Dev-only UI preview server with demo data (not part of the app).
# Run: mix run --no-start --no-halt preview.exs
require Logger

alias SymphonyElixir.{Repo, Storage}
alias SymphonyElixirWeb.Endpoint

port = String.to_integer(System.get_env("PREVIEW_PORT", "4080"))
host = System.get_env("PREVIEW_HOST", "100.125.155.110")

# Demo orchestrator: answers :snapshot / :request_refresh like the real one.
defmodule PreviewOrchestrator do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def init(:ok), do: {:ok, :ok}

  def handle_call(:snapshot, _from, state), do: {:reply, snapshot(), state}

  def handle_call(:request_refresh, _from, state) do
    {:reply,
     %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: ["poll"]},
     state}
  end

  defp snapshot do
    now = DateTime.utc_now()

    %{
      running: [
        %{
          issue_id: "iss-101",
          identifier: "HAR-101",
          state: "In Progress",
          session_id: "sess-9f2c1ab47de0",
          turn_count: 12,
          worker_host: "dev-1",
          workspace_path: "/workspaces/HAR-101",
          last_codex_event: :agent_message,
          last_codex_message: "Refactoring auth middleware for modularity",
          last_codex_timestamp: now,
          codex_input_tokens: 18_432,
          codex_output_tokens: 6_210,
          codex_total_tokens: 24_642,
          project_id: "p-portal",
          project_name: "Portal",
          project_slug: "portal",
          started_at: DateTime.add(now, -426, :second)
        },
        %{
          issue_id: "iss-104",
          identifier: "HAR-104",
          state: "In Progress",
          session_id: "sess-1a2b3c4d5e6f",
          turn_count: 4,
          worker_host: "dev-2",
          workspace_path: "/workspaces/HAR-104",
          last_codex_event: :agent_message,
          last_codex_message: "Adding tests for billing webhook handler",
          last_codex_timestamp: now,
          codex_input_tokens: 5_120,
          codex_output_tokens: 1_980,
          codex_total_tokens: 7_100,
          project_id: "p-billing",
          project_name: "Billing",
          project_slug: "billing",
          started_at: DateTime.add(now, -88, :second)
        }
      ],
      retrying: [
        %{
          issue_id: "iss-103",
          identifier: "HAR-103",
          attempt: 2,
          due_in_ms: 45_000,
          error: "rate limit exceeded",
          project_id: "p-billing",
          project_name: "Billing",
          project_slug: "billing"
        }
      ],
      blocked: [
        %{
          issue_id: "iss-102",
          identifier: "HAR-102",
          state: "In Progress",
          error: "codex turn requires operator input",
          worker_host: "dev-2",
          workspace_path: "/workspaces/HAR-102",
          session_id: "sess-def456abc789",
          project_id: "p-portal",
          project_name: "Portal",
          project_slug: "portal",
          blocked_at: DateTime.add(now, -120, :second),
          last_codex_event: :turn_input_required,
          last_codex_message: "Waiting for approval to run database migration",
          last_codex_timestamp: now
        }
      ],
      runtime: %{
        sandbox: %{
          bubblewrap_available: true,
          apparmor_restrict_unprivileged_userns: 1,
          thread_sandbox: "workspace-write",
          turn_sandbox_type: "workspace-write",
          posture: "restricted",
          warnings: ["Network access is restricted to the allowlist"]
        }
      },
      artifacts: [
        %{kind: "walkthrough", path: "/artifacts/HAR-101/walkthrough.webm"},
        %{kind: "screenshot", path: "/artifacts/HAR-101/dashboard.png"}
      ],
      codex_totals: %{
        input_tokens: 42_120,
        output_tokens: 15_980,
        total_tokens: 58_100,
        seconds_running: 1_284.0
      },
      rate_limits: %{
        "primary" => %{"remaining" => 480, "limit" => 500, "reset_at" => "2026-06-01T07:00:00Z"}
      }
    }
  end
end

# Ensure runtime deps are started (we run with --no-start to skip the real app).
Enum.each(
  [:logger, :telemetry, :jason, :postgrex, :ecto_sql, :phoenix_pubsub, :phoenix, :phoenix_html, :phoenix_live_view, :bandit],
  fn app -> {:ok, _} = Application.ensure_all_started(app) end
)

# Start only what isn't already running (works with OR without --no-start).
children =
  [
    if(Process.whereis(SymphonyElixir.Repo), do: nil, else: Repo),
    if(Process.whereis(SymphonyElixir.PubSub), do: nil, else: {Phoenix.PubSub, name: SymphonyElixir.PubSub}),
    PreviewOrchestrator
  ]
  |> Enum.reject(&is_nil/1)

{:ok, _sup} = Supervisor.start_link(children, strategy: :one_for_one, name: Preview.Supervisor)

# Seed a couple of demo projects so /projects has content.
if Storage.list_projects() == [] do
  for {slug, owner, team, review} <- [
        {"portal", "acme", "POR", "In Review"},
        {"billing", "acme", "BIL", "Needs Review"}
      ] do
    Storage.upsert_project(%{
      slug: slug,
      github_owner: owner,
      github_repo: slug,
      github_base_branch: "main",
      linear_project_slug: slug,
      linear_team_key: team,
      linear_human_review_state: review,
      config_version: 1,
      config: %{"poll_interval_ms" => 30_000}
    })
  end
end

endpoint_config =
  :symphony_elixir
  |> Application.get_env(Endpoint, [])
  |> Keyword.merge(
    server: true,
    http: [ip: {0, 0, 0, 0}, port: port],
    url: [host: host],
    orchestrator: PreviewOrchestrator,
    snapshot_timeout_ms: 5_000,
    secret_key_base: String.duplicate("s", 64)
  )

Application.put_env(:symphony_elixir, Endpoint, endpoint_config)

case Endpoint.start_link() do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

Logger.info("PREVIEW server up on http://#{host}:#{port}/  (also 0.0.0.0:#{port})")
IO.puts("\n==> Harmony preview running at http://#{host}:#{port}/  — pages: /  /projects  /projects/new  /runs/HAR-101  /runs/HAR-102\n")

# Keep the owning process alive so the Bandit listener is not torn down when the
# script finishes evaluating (the real cause of "logs up but nothing listens").
Process.sleep(:infinity)
