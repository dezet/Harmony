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

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/github/webhook", GithubWebhookController, :create)
    match(:*, "/api/v1/github/webhook", ObservabilityApiController, :method_not_allowed)

    # Project CRUD. Declared before the :issue_identifier catch-all so that
    # GET /api/v1/projects is not captured as an issue identifier.
    get("/api/v1/projects", ProjectController, :index)
    post("/api/v1/projects", ProjectController, :create)
    get("/api/v1/projects/:id", ProjectController, :show)
    put("/api/v1/projects/:id", ProjectController, :update)
    patch("/api/v1/projects/:id", ProjectController, :update)

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
