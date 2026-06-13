defmodule SymphonyElixir.ProjectConfig.Sync do
  @moduledoc """
  Synchronizes project YAML files into durable storage.
  """

  alias SymphonyElixir.ProjectConfig.{Loader, Schema}
  alias SymphonyElixir.Storage

  @default_projects_dir "projects"

  @spec sync_default_dir() :: :ok | {:error, term()}
  def sync_default_dir do
    projects_dir = Application.get_env(:symphony_elixir, :projects_dir, Path.join(File.cwd!(), @default_projects_dir))

    if File.dir?(projects_dir) do
      case sync_dir(projects_dir) do
        {:ok, _projects} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  @spec sync_dir(Path.t()) :: {:ok, [Storage.Project.t()]} | {:error, term()}
  def sync_dir(projects_dir) when is_binary(projects_dir) do
    with {:ok, configs} <- Loader.load_dir(projects_dir) do
      sync_configs(configs, [])
    end
  end

  defp sync_configs([], projects), do: {:ok, Enum.reverse(projects)}

  defp sync_configs([config | rest], projects) do
    case Storage.upsert_project(attrs(config)) do
      {:ok, project} -> sync_configs(rest, [project | projects])
      {:error, reason} -> {:error, {:project_config_sync_error, config.slug, reason}}
    end
  end

  defp attrs(%Schema{} = config) do
    %{
      slug: config.slug,
      linear_project_slug: config.linear.project_slug,
      linear_team_key: config.linear.team_key,
      linear_human_review_state: config.linear.human_review_state,
      forge_type: config.forge.type,
      forge_owner: config.forge.owner,
      forge_repo: config.forge.repo,
      forge_base_branch: config.forge.base_branch,
      forge_base_url: config.forge.base_url,
      config_version: config.review.template_version,
      config: config.raw
    }
  end
end
