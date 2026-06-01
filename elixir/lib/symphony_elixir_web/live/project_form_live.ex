defmodule SymphonyElixirWeb.ProjectFormLive do
  @moduledoc """
  Project configuration form backed by Postgres.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  import Ecto.Changeset

  alias SymphonyElixir.Storage
  alias SymphonyElixir.Storage.Project

  @impl true
  def mount(params, _session, socket) do
    project = load_project(socket.assigns.live_action, params)
    changeset = Project.changeset(project, %{})

    {:ok,
     socket
     |> assign(:project, project)
     |> assign(:changeset, changeset)
     |> assign(:config_json, encode_config(project.config))
     |> assign(:title, page_title(socket.assigns.live_action))}
  end

  @impl true
  def handle_event("validate", %{"project" => params}, socket) do
    {changeset, config_json} = form_changeset(socket.assigns.project, params, :validate)

    {:noreply,
     socket
     |> assign(:changeset, changeset)
     |> assign(:config_json, config_json)}
  end

  def handle_event("save", %{"project" => params}, socket) do
    {changeset, config_json} = form_changeset(socket.assigns.project, params, :insert)

    if changeset.valid? do
      attrs = apply_changes(changeset) |> project_attrs()

      case Storage.upsert_project(attrs) do
        {:ok, _project} ->
          {:noreply, push_navigate(socket, to: "/projects")}

        {:error, changeset} ->
          {:noreply,
           socket
           |> assign(:changeset, %{changeset | action: :insert})
           |> assign(:config_json, config_json)}
      end
    else
      {:noreply,
       socket
       |> assign(:changeset, changeset)
       |> assign(:config_json, config_json)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Harmony Configuration</p>
            <h1 class="hero-title"><%= @title %></h1>
            <p class="hero-copy">Create or edit the Postgres project record used by Harmony scheduling.</p>
          </div>

          <div class="status-stack">
            <a class="subtle-button" href="/projects">Projects</a>
          </div>
        </div>
      </header>

      <section class="section-card">
        <form id="project-form" phx-change="validate" phx-submit="save">
          <div class="project-form-grid">
            <label class="form-field">
              <span class="metric-label">Slug</span>
              <input class="text-input" name="project[slug]" value={field_value(@changeset, :slug)} />
              <.field_errors changeset={@changeset} field={:slug} />
            </label>

            <label class="form-field">
              <span class="metric-label">GitHub owner</span>
              <input class="text-input" name="project[github_owner]" value={field_value(@changeset, :github_owner)} />
              <.field_errors changeset={@changeset} field={:github_owner} />
            </label>

            <label class="form-field">
              <span class="metric-label">GitHub repo</span>
              <input class="text-input" name="project[github_repo]" value={field_value(@changeset, :github_repo)} />
              <.field_errors changeset={@changeset} field={:github_repo} />
            </label>

            <label class="form-field">
              <span class="metric-label">Base branch</span>
              <input class="text-input" name="project[github_base_branch]" value={field_value(@changeset, :github_base_branch)} />
              <.field_errors changeset={@changeset} field={:github_base_branch} />
            </label>

            <label class="form-field">
              <span class="metric-label">Linear project</span>
              <input class="text-input" name="project[linear_project_slug]" value={field_value(@changeset, :linear_project_slug)} />
            </label>

            <label class="form-field">
              <span class="metric-label">Linear team</span>
              <input class="text-input" name="project[linear_team_key]" value={field_value(@changeset, :linear_team_key)} />
            </label>

            <label class="form-field">
              <span class="metric-label">Human review state</span>
              <input class="text-input" name="project[linear_human_review_state]" value={field_value(@changeset, :linear_human_review_state)} />
            </label>

            <label class="form-field">
              <span class="metric-label">Config version</span>
              <input class="text-input numeric" name="project[config_version]" value={field_value(@changeset, :config_version)} />
              <.field_errors changeset={@changeset} field={:config_version} />
            </label>
          </div>

          <div class="section-header" style="margin-top: 1rem;">
            <div>
              <h2 class="section-title">Raw config</h2>
              <p class="section-copy">JSON map persisted to the project config column.</p>
            </div>
          </div>

          <textarea class="code-panel" name="project[config_json]" rows="8"><%= @config_json %></textarea>
          <.field_errors changeset={@changeset} field={:config} />

          <div class="status-stack" style="margin-top: 1rem;">
            <button class="subtle-button" type="submit">Save</button>
            <a class="issue-link" href="/projects">Cancel</a>
          </div>
        </form>
      </section>
    </section>
    """
  end

  defp load_project(:edit, %{"id" => id}), do: Storage.get_project!(id)
  defp load_project(_action, _params), do: %Project{config: %{}, config_version: 1}

  defp page_title(:edit), do: "Edit project"
  defp page_title(_action), do: "New project"

  defp form_changeset(%Project{} = project, params, action) do
    config_json = Map.get(params, "config_json", "{}")

    attrs =
      params
      |> Map.drop(["config_json"])
      |> Map.put("config", %{})

    changeset =
      case decode_config(config_json) do
        {:ok, config} ->
          Project.changeset(project, Map.put(attrs, "config", config))

        {:error, message} ->
          project
          |> Project.changeset(attrs)
          |> add_error(:config, message)
      end

    {%{changeset | action: action}, config_json}
  end

  defp decode_config(config_json) when is_binary(config_json) do
    case Jason.decode(config_json) do
      {:ok, config} when is_map(config) -> {:ok, config}
      {:ok, _other} -> {:error, "must be a JSON object"}
      {:error, _reason} -> {:error, "must be valid JSON"}
    end
  end

  defp decode_config(_config_json), do: {:error, "must be valid JSON"}

  defp project_attrs(%Project{} = project) do
    %{
      slug: project.slug,
      linear_project_slug: project.linear_project_slug,
      linear_team_key: project.linear_team_key,
      linear_human_review_state: project.linear_human_review_state,
      github_owner: project.github_owner,
      github_repo: project.github_repo,
      github_base_branch: project.github_base_branch,
      config_version: project.config_version,
      config: project.config || %{}
    }
  end

  defp encode_config(config) when is_map(config), do: Jason.encode!(config, pretty: true)
  defp encode_config(_config), do: "{}"

  defp field_value(changeset, field) do
    case Ecto.Changeset.get_field(changeset, field) do
      nil -> ""
      value -> to_string(value)
    end
  end

  attr(:changeset, Ecto.Changeset, required: true)
  attr(:field, :atom, required: true)

  defp field_errors(assigns) do
    ~H"""
    <p :for={message <- field_error_messages(@changeset, @field)} class="error-copy"><%= message %></p>
    """
  end

  defp field_error_messages(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
