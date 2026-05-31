defmodule SymphonyElixir.Evidence.Manifest do
  @moduledoc """
  Reads browser evidence manifests from workspaces.
  """

  @allowed_artifact_kinds ["screenshot", "trace", "report"]

  defstruct frontend_changed: false, scenario: nil, artifacts: []

  @type artifact :: %{
          kind: String.t(),
          path: Path.t(),
          description: String.t() | nil
        }

  @type t :: %__MODULE__{
          frontend_changed: boolean(),
          scenario: String.t() | nil,
          artifacts: [artifact()]
        }

  @spec read(Path.t()) :: {:ok, t()} | {:error, term()}
  def read(workspace) when is_binary(workspace) do
    workspace = Path.expand(workspace)
    manifest_path = Path.join([workspace, ".harmony", "evidence.json"])

    with {:ok, raw} <- File.read(manifest_path),
         {:ok, decoded} <- Jason.decode(raw),
         {:ok, artifacts} <- parse_artifacts(Map.get(decoded, "artifacts", []), workspace) do
      {:ok,
       %__MODULE__{
         frontend_changed: Map.get(decoded, "frontend_changed") == true,
         scenario: string_or_nil(Map.get(decoded, "scenario")),
         artifacts: artifacts
       }}
    else
      {:error, :enoent} -> {:error, :missing_evidence_manifest}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_evidence_manifest, Exception.message(error)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_artifacts(artifacts, workspace) when is_list(artifacts) do
    artifacts
    |> Enum.reduce_while({:ok, []}, fn artifact, {:ok, acc} ->
      case parse_artifact(artifact, workspace) do
        {:ok, parsed} -> {:cont, {:ok, acc ++ [parsed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_artifacts(_artifacts, _workspace), do: {:error, :invalid_evidence_artifacts}

  defp parse_artifact(%{"kind" => kind, "path" => path} = artifact, workspace)
       when is_binary(kind) and is_binary(path) do
    with :ok <- validate_artifact_kind(kind),
         {:ok, expanded_path} <- expand_artifact_path(path, workspace) do
      {:ok,
       %{
         kind: kind,
         path: expanded_path,
         description: string_or_nil(Map.get(artifact, "description"))
       }}
    end
  end

  defp parse_artifact(_artifact, _workspace), do: {:error, :invalid_evidence_artifact}

  defp validate_artifact_kind(kind) when kind in @allowed_artifact_kinds, do: :ok
  defp validate_artifact_kind(kind), do: {:error, {:unsupported_evidence_artifact_kind, kind}}

  defp expand_artifact_path(path, workspace) do
    expanded_path = Path.expand(path, workspace)

    if inside_workspace?(expanded_path, workspace) do
      {:ok, expanded_path}
    else
      {:error, {:evidence_artifact_path_escapes_workspace, path}}
    end
  end

  defp inside_workspace?(path, workspace) do
    path == workspace or String.starts_with?(path, workspace <> "/")
  end

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil
end
