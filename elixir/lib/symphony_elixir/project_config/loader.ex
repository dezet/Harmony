defmodule SymphonyElixir.ProjectConfig.Loader do
  @moduledoc """
  Loads typed Harmony project configs from a directory of YAML files.
  """

  alias SymphonyElixir.ProjectConfig.Schema

  @spec load_dir(Path.t()) :: {:ok, [Schema.t()]} | {:error, term()}
  def load_dir(projects_dir) when is_binary(projects_dir) do
    if File.dir?(projects_dir) do
      projects_dir
      |> Path.join("*.yaml")
      |> Path.wildcard()
      |> Enum.sort()
      |> load_files([])
    else
      {:error, {:missing_projects_dir, projects_dir}}
    end
  end

  defp load_files([], configs), do: {:ok, Enum.reverse(configs)}

  defp load_files([path | rest], configs) do
    with {:ok, raw} <- YamlElixir.read_from_file(path),
         {:ok, config} <- Schema.parse(raw) do
      load_files(rest, [config | configs])
    else
      {:error, reason} -> {:error, {:project_config_load_error, path, reason}}
    end
  end
end
