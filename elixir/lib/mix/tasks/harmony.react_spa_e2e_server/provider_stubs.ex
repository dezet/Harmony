defmodule Mix.Tasks.Harmony.ReactSpaE2eServer.ProviderStubs do
  @moduledoc """
  Synthetic Jira, Linear, SMTP, SMSAPI, analysis-profile and scheduler
  adapters of the browser E2E harness. They answer in process and never open
  a network connection, so the E2E suite exercises the real controllers
  without any external write or cost.

  Jira answers per site: `harmony-e2e.atlassian.net` succeeds,
  `odmowa-e2e.atlassian.net` rejects every request with 401 and
  `limit-e2e.atlassian.net` with 429.
  """

  use GenServer

  @site "https://harmony-e2e.atlassian.net"
  @team_id "3a1f6c1e-2b7d-4c55-9f1e-000000000001"
  @todo_state_id "3a1f6c1e-2b7d-4c55-9f1e-000000000002"
  @hold_label_id "3a1f6c1e-2b7d-4c55-9f1e-000000000003"
  @linear_project_id "3a1f6c1e-2b7d-4c55-9f1e-000000000004"

  @boards [
    %{"id" => 41, "name" => "Portal klienta / Wsparcie"},
    %{"id" => 42, "name" => "Finanse / Zgłoszenia"},
    %{"id" => 43, "name" => "HR / Wsparcie"}
  ]
  @filters [%{"id" => "1001", "name" => "Pilne HR"}]
  @priorities [
    %{"id" => "1", "name" => "Krytyczny"},
    %{"id" => "2", "name" => "Wysoki"},
    %{"id" => "3", "name" => "Średni"}
  ]

  @doc "Jira site URL of the healthy synthetic connection."
  @spec site() :: String.t()
  def site, do: @site

  @doc "Linear IDs the synthetic team exposes (team, Todo state, hold label, project)."
  @spec linear_ids() :: %{team: String.t(), todo: String.t(), hold_label: String.t(), project: String.t()}
  def linear_ids, do: %{team: @team_id, todo: @todo_state_id, hold_label: @hold_label_id, project: @linear_project_id}

  @doc "Endpoint `intake_adapters` wiring every provider to the stubs above."
  @spec adapters(GenServer.server()) :: keyword()
  def adapters(scheduler) do
    [
      jira_request_fun: &jira/1,
      linear_request_fun: &linear/2,
      smtp_opts: [
        open_fun: fn _options -> {:ok, :synthetic_e2e_session} end,
        close_fun: fn _session -> :ok end,
        smtp_fun: fn _email, _options -> {:ok, "250 queued"} end
      ],
      smsapi_opts: [request_fun: fn _request -> ok(%{"points" => 100.0, "username" => "harmony-e2e"}) end],
      analysis_profile_fun: fn -> {:ok, %{model: "synthetic-e2e-model", effort: "medium"}} end,
      case_action_opts: [
        analysis_profile: %{model: "synthetic-e2e-model", effort: "medium"},
        refresh_fun: fn -> :ok end
      ],
      scheduler: scheduler
    ]
  end

  @doc "Synthetic Jira Cloud response for a `Req`-style request keyword list."
  @spec jira(keyword()) :: {:ok, map()}
  def jira(request) do
    uri = URI.parse(request[:url])

    case uri.host do
      "harmony-e2e.atlassian.net" -> jira_route(request[:method], uri.path)
      "odmowa-e2e.atlassian.net" -> {:ok, %{status: 401, body: %{"errorMessages" => ["synthetic"]}, headers: %{}}}
      "limit-e2e.atlassian.net" -> {:ok, %{status: 429, body: %{}, headers: %{"retry-after" => ["60"]}}}
      _other -> {:ok, %{status: 404, body: %{}, headers: %{}}}
    end
  end

  defp jira_route(:get, "/rest/api/3/myself"), do: ok(%{"accountId" => "harmony-e2e"})
  defp jira_route(:get, "/rest/agile/1.0/board"), do: offset_page(@boards)
  defp jira_route(:get, "/rest/api/3/filter/search"), do: offset_page(@filters)
  defp jira_route(:get, "/rest/api/3/priority/search"), do: offset_page(@priorities)
  defp jira_route(:get, "/rest/api/3/filter/1001"), do: ok(hd(@filters))

  defp jira_route(:get, "/rest/agile/1.0/board/" <> rest) do
    case String.split(rest, "/") do
      [id, "configuration"] when id in ["41", "42", "43"] -> ok(%{"filter" => %{"id" => "20#{id}"}})
      _other -> {:ok, %{status: 404, body: %{}, headers: %{}}}
    end
  end

  defp jira_route(:post, "/rest/api/3/search/jql"), do: ok(%{"issues" => Enum.map(1..3, &issue/1), "isLast" => true})
  defp jira_route(_method, _path), do: {:ok, %{status: 404, body: %{}, headers: %{}}}

  defp issue(index) do
    %{
      "id" => "#{30_000 + index}",
      "key" => "HR-#{70 + index}",
      "fields" => %{
        "summary" => "Przykładowe zgłoszenie HR #{index}",
        "description" => nil,
        "priority" => %{"id" => "2", "name" => "Wysoki"},
        "status" => %{"id" => "1", "name" => "Do zrobienia", "statusCategory" => %{"key" => "new"}},
        "created" => "2026-09-22T09:00:00.000+0000",
        "updated" => "2026-09-22T09:30:00.000+0000",
        "project" => %{"id" => "3", "key" => "HR", "name" => "HR"}
      }
    }
  end

  defp offset_page(values) do
    ok(%{"values" => values, "startAt" => 0, "maxResults" => 100, "total" => length(values), "isLast" => true})
  end

  @doc "Synthetic Linear GraphQL response: one team with Todo, the hold label and one project."
  @spec linear(map(), term()) :: {:ok, map()}
  def linear(%{"query" => query}, _headers) do
    if query =~ "issueLabelCreate" do
      ok(%{
        "data" => %{
          "issueLabelCreate" => %{"success" => true, "issueLabel" => %{"id" => @hold_label_id, "name" => "harmony:analysis-only"}}
        }
      })
    else
      ok(%{"data" => %{"teams" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => [team()]}}})
    end
  end

  def linear(_payload, _headers), do: {:ok, %{status: 400, body: %{}}}

  defp team do
    %{
      "id" => @team_id,
      "key" => "OPS",
      "name" => "Operacje",
      "states" => %{
        "pageInfo" => %{"hasNextPage" => false},
        "nodes" => [
          %{"id" => "3a1f6c1e-2b7d-4c55-9f1e-000000000005", "name" => "Backlog", "type" => "backlog"},
          %{"id" => @todo_state_id, "name" => "Todo", "type" => "unstarted"}
        ]
      },
      "labels" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => [%{"id" => @hold_label_id, "name" => "harmony:analysis-only"}]},
      "projects" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => [%{"id" => @linear_project_id, "name" => "Wsparcie"}]}
    }
  end

  defp ok(body), do: {:ok, %{status: 200, body: body, headers: %{}}}

  # ─── Scheduler stub ──────────────────────────────────────────────────────
  # The real scheduler is not started (intake.enabled stays false), so no
  # scan ever reaches a provider. "Sprawdź teraz" still gets a deterministic
  # answer: enabled rules are accepted, everything else is reported inactive.

  @doc "Starts the scheduler stub answering `Scheduler.check_now/2` calls."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, name: Keyword.fetch!(opts, :name))

  @impl GenServer
  def init(:ok), do: {:ok, 0}

  @impl GenServer
  def handle_call({:check_now, rule_id}, _from, count) do
    case SymphonyElixir.Repo.get(SymphonyElixir.Storage.AutomationRule, rule_id) do
      %{enabled: true} -> {:reply, {:accepted, synthetic_scan_id(count + 1)}, count + 1}
      nil -> {:reply, {:error, :not_found}, count}
      _disabled -> {:reply, {:error, :rule_not_active}, count}
    end
  end

  defp synthetic_scan_id(n), do: "5ca70000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
end
