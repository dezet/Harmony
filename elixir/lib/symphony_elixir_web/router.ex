defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  # React SPA served under /app during Phases 0-2 (LiveView stays default at /).
  # Declared first so it is not shadowed by the API catch-all below.
  scope "/app", SymphonyElixirWeb do
    pipe_through(:browser)

    get("/", SpaController, :index)
    get("/*path", SpaController, :index)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
    live("/projects", ProjectsLive, :index)
    live("/projects/new", ProjectFormLive, :new)
    live("/projects/:id/edit", ProjectFormLive, :edit)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
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

    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
