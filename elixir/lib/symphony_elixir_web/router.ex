defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's JSON API, realtime socket, and the React SPA.
  """

  use Phoenix.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :csrf_bootstrap do
    plug(:fetch_session)
    plug(:protect_from_forgery)
  end

  # Operator mutations need a JSON body, a same-origin Origin and the session
  # CSRF token. Forge webhooks are routed outside this pipeline and keep
  # their own signature checks.
  pipeline :operator_api do
    plug(:fetch_session)
    plug(SymphonyElixirWeb.Plugs.OperatorMutation)
  end

  # Intake API. Declared before the /api/v1/:issue_identifier catch-all so the
  # single-segment paths (/csrf, /automations, /integrations, /cases) are not captured.
  scope "/api/v1", SymphonyElixirWeb do
    pipe_through(:csrf_bootstrap)

    get("/csrf", CsrfController, :show)
  end

  scope "/api/v1", SymphonyElixirWeb do
    pipe_through(:operator_api)

    get("/automations", AutomationController, :index)
    post("/automations", AutomationController, :create)
    post("/automations/check", AutomationController, :check_all)
    # Keeps GET/PATCH /automations/check from being read as a rule ID.
    get("/automations/check", AutomationController, :method_not_allowed)
    patch("/automations/check", AutomationController, :method_not_allowed)
    get("/automations/:id", AutomationController, :show)
    patch("/automations/:id", AutomationController, :update)
    post("/automations/:id/preview", AutomationController, :preview)
    post("/automations/:id/activate", AutomationController, :activate)
    post("/automations/:id/pause", AutomationController, :pause)
    post("/automations/:id/check", AutomationController, :check)

    get("/integrations", IntegrationController, :index)
    post("/integrations", IntegrationController, :create)
    get("/integrations/:id", IntegrationController, :show)
    patch("/integrations/:id", IntegrationController, :update)
    post("/integrations/:id/test", IntegrationController, :test)
    post("/integrations/:id/test-send", IntegrationController, :test_send)
    get("/integrations/:id/jira/boards", IntegrationController, :jira_boards)
    get("/integrations/:id/jira/filters", IntegrationController, :jira_filters)
    get("/integrations/:id/jira/priorities", IntegrationController, :jira_priorities)

    get("/projects/:id/linear-options", LinearOptionsController, :show)
    post("/projects/:id/linear-hold-label", LinearOptionsController, :create_hold_label)

    get("/cases", CaseController, :index)
    get("/cases/:ref", CaseController, :show)
    get("/cases/:ref/events", CaseController, :events)
    post("/cases/:ref/acknowledge", CaseActionController, :acknowledge)
    post("/cases/:ref/approve-repair", CaseActionController, :approve_repair)
    post("/cases/:ref/reanalyze", CaseActionController, :reanalyze)

    post("/deliveries/:id/retry", DeliveryController, :retry)
  end

  # 405 for any other method on the intake paths, outside the mutation guard.
  scope "/api/v1", SymphonyElixirWeb do
    match(:*, "/csrf", CsrfController, :method_not_allowed)
    match(:*, "/automations", AutomationController, :method_not_allowed)
    match(:*, "/automations/check", AutomationController, :method_not_allowed)
    match(:*, "/automations/:id", AutomationController, :method_not_allowed)
    match(:*, "/automations/:id/preview", AutomationController, :method_not_allowed)
    match(:*, "/automations/:id/activate", AutomationController, :method_not_allowed)
    match(:*, "/automations/:id/pause", AutomationController, :method_not_allowed)
    match(:*, "/automations/:id/check", AutomationController, :method_not_allowed)
    match(:*, "/integrations", IntegrationController, :method_not_allowed)
    match(:*, "/integrations/:id", IntegrationController, :method_not_allowed)
    match(:*, "/integrations/:id/test", IntegrationController, :method_not_allowed)
    match(:*, "/integrations/:id/test-send", IntegrationController, :method_not_allowed)
    match(:*, "/integrations/:id/jira/boards", IntegrationController, :method_not_allowed)
    match(:*, "/integrations/:id/jira/filters", IntegrationController, :method_not_allowed)
    match(:*, "/integrations/:id/jira/priorities", IntegrationController, :method_not_allowed)
    match(:*, "/projects/:id/linear-options", LinearOptionsController, :method_not_allowed)
    match(:*, "/projects/:id/linear-hold-label", LinearOptionsController, :method_not_allowed)
    match(:*, "/cases", CaseController, :method_not_allowed)
    match(:*, "/cases/:ref", CaseController, :method_not_allowed)
    match(:*, "/cases/:ref/events", CaseController, :method_not_allowed)
    match(:*, "/cases/:ref/acknowledge", CaseActionController, :method_not_allowed)
    match(:*, "/cases/:ref/approve-repair", CaseActionController, :method_not_allowed)
    match(:*, "/cases/:ref/reanalyze", CaseActionController, :method_not_allowed)
    match(:*, "/deliveries/:id/retry", DeliveryController, :method_not_allowed)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/github/webhook", GithubWebhookController, :create)
    match(:*, "/api/v1/github/webhook", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/gitlab/webhook", GitlabWebhookController, :create)
    match(:*, "/api/v1/gitlab/webhook", ObservabilityApiController, :method_not_allowed)

    # Project CRUD. Declared before the :issue_identifier catch-all so that
    # GET /api/v1/projects is not captured as an issue identifier.
    get("/api/v1/projects", ProjectController, :index)
    post("/api/v1/projects", ProjectController, :create)
    get("/api/v1/projects/:id", ProjectController, :show)
    put("/api/v1/projects/:id", ProjectController, :update)
    patch("/api/v1/projects/:id", ProjectController, :update)

    post("/api/v1/forge/repositories", ForgePickerController, :repositories)
    post("/api/v1/tracker/projects", TrackerPickerController, :projects)

    # Per-project summary endpoint. Must come after the CRUD routes (which bind
    # /projects/:id) but before the :issue_identifier catch-all. The :project_ref
    # segment accepts a UUID or slug.
    get("/api/v1/projects/:project_ref/summary", ProjectSummaryController, :summary)
    match(:*, "/api/v1/projects/:project_ref/summary", ProjectSummaryController, :method_not_allowed)

    # Project artifacts listing endpoint. Must come before the :issue_identifier catch-all.
    get("/api/v1/projects/:project_ref/artifacts", ProjectArtifactsController, :index)
    match(:*, "/api/v1/projects/:project_ref/artifacts", ProjectArtifactsController, :method_not_allowed)

    # Project activity (work events) pagination endpoint. Must come before the :issue_identifier catch-all.
    get("/api/v1/projects/:project_ref/activity", ProjectActivityController, :index)
    match(:*, "/api/v1/projects/:project_ref/activity", ProjectActivityController, :method_not_allowed)

    # Paginated work-runs endpoint. Uses ?project=<slug> query param. Must come
    # before the :issue_identifier catch-all.
    get("/api/v1/work_runs", WorkRunController, :index)
    match(:*, "/api/v1/work_runs", WorkRunController, :method_not_allowed)

    # Run action endpoints (stop, retry-now). Declared before the run-detail GETs
    # so Phoenix matches the more specific sub-paths first. POST won't collide
    # with the GET run-detail route, but grouping them here keeps the routes
    # readable and the match(:*) 405 guards correct.
    post("/api/v1/runs/:identifier/stop", RunActionController, :stop)
    match(:*, "/api/v1/runs/:identifier/stop", RunActionController, :method_not_allowed)
    post("/api/v1/runs/:identifier/retry", RunActionController, :retry)
    match(:*, "/api/v1/runs/:identifier/retry", RunActionController, :method_not_allowed)

    # Per-run detail and stream endpoints. Must come before the :issue_identifier
    # catch-all so that /api/v1/runs/:identifier is not captured as an issue identifier.
    get("/api/v1/runs/:identifier", RunDetailController, :show)
    match(:*, "/api/v1/runs/:identifier", RunDetailController, :method_not_allowed)
    get("/api/v1/runs/:identifier/stream", RunDetailController, :stream)
    match(:*, "/api/v1/runs/:identifier/stream", RunDetailController, :method_not_allowed)

    # Artifact content endpoint. Must come before the :issue_identifier catch-all.
    get("/api/v1/artifacts/:id", ArtifactController, :show)
    match(:*, "/api/v1/artifacts/:id", ArtifactController, :method_not_allowed)

    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/*path", ObservabilityApiController, :not_found)
  end

  # SPA fallback: any non-API GET serves the React index.html. Declared last so it
  # cannot shadow the API routes or the /socket transport.
  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    get("/", SpaController, :index)
    get("/*path", SpaController, :index)
  end
end
