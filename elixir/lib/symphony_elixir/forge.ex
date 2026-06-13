defmodule SymphonyElixir.Forge do
  @moduledoc "Adapter boundary for forge (GitHub/GitLab) reads and writes."

  @type creds :: map()
  # base_url: nil means the default host (github.com); set for GitHub Enterprise / self-hosted.
  @type repo_ref :: %{owner: String.t(), repo: String.t(), base_url: String.t() | nil}

  @callback list_repositories(creds, keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback get_repository(creds, String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback list_change_requests(creds, repo_ref, keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback list_pipeline_runs(creds, repo_ref, String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback get_pipeline_logs(creds, repo_ref, term()) :: {:ok, binary()} | {:error, term()}
  @callback create_comment(creds, repo_ref, term(), String.t()) :: :ok | {:error, term()}
  @callback create_review(creds, repo_ref, term(), String.t(), keyword()) :: :ok | {:error, term()}

  @spec adapter(map()) :: module()
  def adapter(project) do
    case Map.get(project, :forge_type) || "github" do
      # Forge.Gitlab is a Phase 4 placeholder — a project with forge_type "gitlab" would raise UndefinedFunctionError until it exists.
      "gitlab" -> SymphonyElixir.Forge.Gitlab
      _ -> SymphonyElixir.Forge.Github
    end
  end
end
