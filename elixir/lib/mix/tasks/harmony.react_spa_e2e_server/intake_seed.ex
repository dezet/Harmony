defmodule Mix.Tasks.Harmony.ReactSpaE2eServer.IntakeSeed do
  @moduledoc """
  Deterministic Case Center data of the browser E2E harness: three projects
  (purple, gold, teal), synthetic Jira/SMTP/SMSAPI connections, one rule per
  project and Jira cases in every Kanban column. Every name, key, URL and
  recipient is synthetic and every timestamp is fixed relative to
  `base_time/0`, which is also the frozen browser clock of the suite.

  Finanse holds 30 cases, 27 of them in "Do decyzji", so both the list and a
  Kanban column need „Pokaż więcej” (pages of 25).
  """

  alias Mix.Tasks.Harmony.ReactSpaE2eServer.ProviderStubs
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

  @base_time ~U[2026-09-22 12:00:00.000000Z]
  @ranking ["1", "2", "3"]
  @priority_names %{"1" => "Krytyczny", "2" => "Wysoki", "3" => "Średni"}
  @filler_count 24

  @doc "The fixed \"now\" of the seeded data (the E2E suite freezes the browser clock here)."
  @spec base_time() :: DateTime.t()
  def base_time, do: @base_time

  @doc "Inserts the intake data. `portal` is the already seeded legacy project."
  @spec seed!(Project.t()) :: :ok
  def seed!(%Project{} = portal) do
    finanse = project!("finanse", "Finanse", "gold", "FIN")
    hr = project!("hr", "HR", "teal", "HR")

    jira = connection!("jira_cloud", "Jira · Harmony E2E", jira_settings(ProviderStubs.site()), health: "ok")
    connection!("jira_cloud", "Jira · Odmowa dostępu", jira_settings("https://odmowa-e2e.atlassian.net"), [])
    connection!("jira_cloud", "Jira · Limit zapytań", jira_settings("https://limit-e2e.atlassian.net"), [])
    smtp = connection!("smtp", "Poczta dyżurna", smtp_settings(), health: "ok")
    sms = connection!("smsapi", "SMSAPI dyżur", %{"sender" => "Harmony"}, health: "ok")

    portal_rule =
      rule!(portal, jira, %{name: "Pilne zgłoszenia portalu", source_id: "41", enabled: true, last_success: -3, next_poll: 2})

    finanse_rule =
      rule!(finanse, jira, %{
        name: "Pilne zgłoszenia Finanse",
        source_id: "42",
        enabled: true,
        last_success: -5,
        next_poll: 5,
        email: {smtp, ["finanse-dyzur@example.test"]},
        sms: {sms, ["+48600100200"]}
      })

    hr_rule = rule!(hr, jira, %{name: "Zgłoszenia HR", source_type: "filter", source_id: "1001", enabled: false})

    seed_finanse(%{project: finanse, jira: jira, rule: finanse_rule, smtp: smtp})
    seed_portal(%{project: portal, jira: jira, rule: portal_rule})
    seed_hr(%{project: hr, jira: jira, rule: hr_rule})
    :ok
  end

  # ─── Cases ───────────────────────────────────────────────────────────────

  defp seed_finanse(scope) do
    ready!(scope, "FIN-142", "Płatności kartą odrzucane po aktualizacji bramki", "1", -12, published?: true)
    case!(scope, "FIN-141", "Eksport faktur do CSV pomija korekty", "2", -4, analysis_status: "running")
    case!(scope, "FIN-140", "Import wyciągu bankowego zatrzymuje się na 80%", "2", -1, linear?: false)
    needs_input!(scope, "FIN-139", "Różnica w sumie faktur po imporcie", "2", -28)
    handed_off!(scope, "FIN-138", "Raport VAT za sierpień ma zdublowane pozycje", "2", -42)

    failed = ready!(scope, "FIN-137", "Powiadomienie o zaległej płatności nie dotarło", "3", -55, published?: true)
    delivery!(failed, "email", "failed", connection_id: scope.smtp.id, recipient: "finanse-dyzur@example.test")

    for n <- 1..@filler_count do
      ready!(scope, "FIN-#{100 + n}", "Rozbieżność salda na koncie rozliczeniowym nr #{n}", "3", -(120 + n * 10), published?: true)
    end
  end

  defp seed_portal(scope) do
    ready!(scope, "POR-58", "Formularz kontaktowy zwraca błąd 500", "1", -20, published?: true)
    case!(scope, "POR-57", "Powiadomienia push nie docierają na Androida", "2", -8, analysis_status: "running")
  end

  defp seed_hr(scope) do
    case!(scope, "HR-65", "Lista obecności nie uwzględnia pracy zdalnej", "3", -30, [])
    handed_off!(scope, "HR-64", "Wniosek urlopowy nie trafia do przełożonego", "2", -180)
  end

  defp ready!(scope, key, title, priority, minutes, opts) do
    intake_case = case!(scope, key, title, priority, minutes, analysis_status: "ready")
    analysis!(intake_case, "succeeded", minutes)
    if Keyword.get(opts, :published?, false), do: delivery!(intake_case, "jira_comment", "succeeded", [])
    event!(intake_case, "analysis_completed", %{"analysis_version" => 1}, minutes + 3)
    event!(intake_case, "jira_comment_post_started", %{"version" => 1}, minutes + 4)
    intake_case
  end

  defp needs_input!(scope, key, title, priority, minutes) do
    intake_case = case!(scope, key, title, priority, minutes, analysis_status: "needs_input")
    analysis!(intake_case, "needs_input", minutes)
    delivery!(intake_case, "jira_comment", "succeeded", [])
    intake_case
  end

  defp handed_off!(scope, key, title, priority, minutes) do
    intake_case = ready!(scope, key, title, priority, minutes, published?: true)

    intake_case
    |> Ecto.Changeset.change(acknowledged_at: at(minutes + 20))
    |> Repo.update!()
    |> tap(&event!(&1, "case_acknowledged", %{}, minutes + 20, "operator"))
  end

  defp case!(%{project: project, jira: jira, rule: rule}, key, title, priority, minutes, opts) do
    detected_at = at(minutes)
    linear? = Keyword.get(opts, :linear?, true)
    number = key |> String.split("-") |> List.last()
    linear_identifier = "OPS-#{number}"

    intake_case =
      %IntakeCase{}
      |> IntakeCase.changeset(%{
        project_id: project.id,
        rule_id: rule.id,
        jira_connection_id: jira.id,
        jira_issue_id: "e2e-#{key}",
        jira_key: key,
        jira_url: "#{jira.settings["site_url"]}/browse/#{key}",
        title: title,
        description_text: "Zgłoszenie syntetyczne środowiska testowego.\nOpis problemu: #{title}.\nKroki: otworzyć moduł i powtórzyć operację.",
        priority_id: priority,
        priority_name: Map.fetch!(@priority_names, priority),
        jira_updated_at: DateTime.add(detected_at, -60, :second),
        detected_at: detected_at,
        rule_snapshot: rule_snapshot(rule, project, detected_at),
        linear_identifier: if(linear?, do: linear_identifier),
        linear_url: if(linear?, do: "https://linear.app/harmony-e2e/issue/#{linear_identifier}"),
        linear_state_name: if(linear?, do: "Todo"),
        linear_confirmed_at: if(linear?, do: detected_at),
        analysis_version: 1,
        analysis_status: Keyword.get(opts, :analysis_status, "queued"),
        lock_version: 1
      })
      |> Repo.insert!()

    event!(intake_case, "case_detected", %{"priority" => Map.fetch!(@priority_names, priority)}, minutes)
    if linear?, do: event!(intake_case, "linear_issue_confirmed", %{}, minutes + 1)
    intake_case
  end

  defp rule_snapshot(rule, project, qualified_at) do
    %{
      "name" => rule.name,
      "project_id" => project.id,
      "project_name" => project.display_name,
      "source_type" => rule.source_type,
      "source_id" => rule.source_id,
      "priority_ids" => rule.priority_ids,
      "priority_ranking" => @ranking,
      "initial_policy" => rule.initial_policy,
      "email_recipients" => rule.email_recipients,
      "sms_recipients" => rule.sms_recipients,
      "config_version" => rule.config_version,
      "qualified_at" => DateTime.to_iso8601(qualified_at)
    }
  end

  defp analysis!(intake_case, status, minutes) do
    %IntakeAnalysis{}
    |> IntakeAnalysis.changeset(%{
      case_id: intake_case.id,
      version: 1,
      status: status,
      input_snapshot: %{"case_ref" => "jira_#{intake_case.id}", "jira_key" => intake_case.jira_key, "context_scope" => "issue_only"},
      result: analysis_result(intake_case, status),
      model: "synthetic-e2e-model",
      effort: "medium",
      started_at: at(minutes + 1),
      completed_at: at(minutes + 3),
      token_usage: %{"input_tokens" => 1200, "output_tokens" => 340, "total_tokens" => 1540}
    })
    |> Repo.insert!()
  end

  defp analysis_result(intake_case, status) do
    source = "jira:#{intake_case.jira_key}"

    %{
      "summary" => "Opis zgłoszenia wskazuje, że problem pojawia się po ostatniej zmianie konfiguracji. To hipoteza wymagająca potwierdzenia w logach.",
      "facts" => [%{"text" => "Problem występuje od ostatniego wdrożenia", "source" => source}],
      "hypotheses" => [
        %{"text" => "Zmieniony limit czasu po stronie integracji", "confidence" => "medium", "evidence" => [source]}
      ],
      "missing_data" => if(status == "needs_input", do: ["Przykładowy plik i oczekiwana kwota"], else: []),
      "next_steps" => ["Zebrać logi dla wskazanego żądania i porównać je z poprzednią wersją."],
      "needs_input" => status == "needs_input",
      "context_scope" => "issue_only"
    }
  end

  defp delivery!(intake_case, operation, status, opts) do
    succeeded? = status == "succeeded"

    payload =
      case Keyword.get(opts, :recipient) do
        nil -> %{"version" => 1}
        recipient -> %{"recipient" => recipient}
      end

    %IntegrationDelivery{}
    |> IntegrationDelivery.changeset(%{
      case_id: intake_case.id,
      connection_id: Keyword.get(opts, :connection_id),
      operation: operation,
      dedupe_key: dedupe_key(intake_case, operation),
      payload: payload,
      status: status,
      attempts: 1,
      next_attempt_at: intake_case.detected_at,
      provider_id: if(succeeded?, do: "e2e-#{intake_case.jira_key}-#{operation}"),
      first_attempt_at: intake_case.detected_at,
      sent_at: if(succeeded?, do: DateTime.add(intake_case.detected_at, 240, :second)),
      last_error_code: if(succeeded?, do: nil, else: "smtp_rejected")
    })
    |> Repo.insert!()
  end

  # The canonical keys of the outbox: the projection only counts the effects
  # of the current analysis version.
  defp dedupe_key(intake_case, "jira_comment"), do: "case:#{intake_case.id}:jira-comment:1"
  defp dedupe_key(intake_case, channel), do: "case:#{intake_case.id}:#{channel}:e2e:detected:v1"

  defp event!(intake_case, type, payload, minutes, actor \\ "system") do
    %IntakeEvent{}
    |> IntakeEvent.changeset(%{
      case_id: intake_case.id,
      rule_id: intake_case.rule_id,
      type: type,
      payload: payload,
      actor: actor,
      occurred_at: at(minutes)
    })
    |> Repo.insert!()
  end

  # ─── Projects, connections, rules ───────────────────────────────────────

  defp project!(slug, name, color, team_key) do
    project =
      %Project{}
      |> Project.changeset(%{
        slug: slug,
        display_name: name,
        ui_color: color,
        forge_owner: "harmony-e2e",
        forge_repo: slug,
        forge_base_branch: "main",
        linear_project_slug: slug,
        linear_team_key: team_key,
        linear_human_review_state: "Human Review",
        config_version: 1,
        config: %{}
      })
      |> Repo.insert!()

    project |> Project.secret_changeset(%{tracker_secret: "synthetic-e2e-linear-token"}) |> Repo.update!()
  end

  defp jira_settings(site_url), do: %{"site_url" => site_url, "auth_mode" => "classic", "account_email" => "ops@example.test"}

  defp smtp_settings do
    %{
      "host" => "smtp.e2e.example.test",
      "port" => 587,
      "tls_mode" => "starttls",
      "username" => "harmony",
      "from_email" => "harmony@example.test",
      "from_name" => "Harmony",
      "message_id_domain" => "example.test"
    }
  end

  defp connection!(kind, name, settings, opts) do
    health = Keyword.get(opts, :health, "unchecked")

    %IntegrationConnection{}
    |> IntegrationConnection.changeset(%{
      kind: kind,
      name: name,
      settings: settings,
      secret: "synthetic-e2e-secret",
      enabled: true,
      health: health,
      last_checked_at: if(health == "ok", do: at(-10))
    })
    |> Repo.insert!()
  end

  defp rule!(project, jira, attrs) do
    ids = ProviderStubs.linear_ids()
    {email, email_recipients} = Map.get(attrs, :email, {nil, []})
    {sms, sms_recipients} = Map.get(attrs, :sms, {nil, []})
    enabled? = attrs.enabled

    %AutomationRule{}
    |> AutomationRule.changeset(%{
      name: attrs.name,
      project_id: project.id,
      jira_connection_id: jira.id,
      source_type: Map.get(attrs, :source_type, "board"),
      source_id: attrs.source_id,
      priority_ids: ["1", "2"],
      priority_ranking: @ranking,
      interval_seconds: 300,
      initial_policy: "new_matches_only",
      linear_team_id: ids.team,
      linear_project_id: ids.project,
      linear_todo_state_id: ids.todo,
      linear_hold_label_id: ids.hold_label,
      email_connection_id: email && email.id,
      sms_connection_id: sms && sms.id,
      email_recipients: email_recipients,
      sms_recipients: sms_recipients,
      enabled: enabled?,
      activated_at: if(enabled?, do: at(-24 * 60)),
      baseline_complete_at: at(-24 * 60),
      last_success_at: if(enabled?, do: at(attrs.last_success), else: at(-24 * 60)),
      next_poll_at: if(enabled?, do: at(attrs.next_poll))
    })
    |> Repo.insert!()
  end

  defp at(minutes), do: DateTime.add(@base_time, minutes * 60, :second)
end
