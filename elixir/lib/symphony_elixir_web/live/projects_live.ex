defmodule SymphonyElixirWeb.ProjectsLive do
  @moduledoc """
  Database-backed project configuration index.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Storage

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :projects, Storage.list_projects())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Harmony Configuration</p>
            <h1 class="hero-title">Projects</h1>
            <p class="hero-copy">Database-backed project records used by scheduling, GitHub polling, and Linear routing.</p>
          </div>

          <div class="status-stack">
            <a class="subtle-button" href="/projects/new">New project</a>
          </div>
        </div>
      </header>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Configured projects</h2>
            <p class="section-copy">Project settings currently stored in Postgres.</p>
          </div>
        </div>

        <%= if @projects == [] do %>
          <p class="empty-state">No projects configured.</p>
        <% else %>
          <div class="table-wrap">
            <table class="data-table" style="min-width: 860px;">
              <thead>
                <tr>
                  <th>Slug</th>
                  <th>GitHub</th>
                  <th>Base</th>
                  <th>Linear</th>
                  <th>Review state</th>
                  <th>Version</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={project <- @projects}>
                  <td><span class="issue-id"><%= project.slug %></span></td>
                  <td><%= project.github_owner %>/<%= project.github_repo %></td>
                  <td><span class="state-badge"><%= project.github_base_branch %></span></td>
                  <td>
                    <div class="issue-stack">
                      <span><%= project.linear_project_slug || "n/a" %></span>
                      <span class="muted"><%= project.linear_team_key || "n/a" %></span>
                    </div>
                  </td>
                  <td><%= project.linear_human_review_state || "n/a" %></td>
                  <td class="numeric"><%= project.config_version %></td>
                  <td><a class="issue-link" href={"/projects/#{project.id}/edit"}>Edit</a></td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>
    </section>
    """
  end
end
