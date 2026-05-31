defmodule SymphonyElixir.Evidence.Collector do
  @moduledoc """
  Persists browser evidence artifacts declared by a workspace manifest.
  """

  alias SymphonyElixir.Evidence.Manifest
  alias SymphonyElixir.Storage

  @spec collect(String.t(), String.t() | nil, Path.t(), keyword()) :: {:ok, [term()]} | {:error, term()}
  def collect(project_id, work_run_id, workspace, opts \\ [])
      when is_binary(project_id) and is_binary(workspace) do
    persist_artifact = Keyword.get(opts, :persist_artifact, &Storage.create_artifact/1)

    with {:ok, manifest} <- Manifest.read(workspace) do
      manifest.artifacts
      |> Enum.reduce_while({:ok, []}, fn artifact, {:ok, acc} ->
        attrs = artifact_attrs(project_id, work_run_id, manifest, artifact)

        case persist_artifact.(attrs) do
          {:ok, record} -> {:cont, {:ok, acc ++ [record]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp artifact_attrs(project_id, work_run_id, manifest, artifact) do
    %{
      project_id: project_id,
      work_run_id: work_run_id,
      kind: artifact.kind,
      path: artifact.path,
      metadata: %{
        "scenario" => manifest.scenario,
        "description" => artifact.description
      }
    }
  end
end
