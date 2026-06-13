defmodule SymphonyElixirWeb.ProjectRef do
  @moduledoc """
  Shared helper for resolving a project reference (UUID or slug) to a
  `SymphonyElixir.Storage.Project` struct.

  Accepts a `ref` string that may be either a valid UUID or a project slug:

  - If `ref` is a valid UUID, look up the project by UUID first; on
    `Ecto.NoResultsError` fall through to a slug lookup (handles the edge case
    where a slug happens to be UUID-shaped).
  - Otherwise look up directly by slug.

  Returns `{:ok, project}` or `{:error, :not_found}`.
  """

  alias SymphonyElixir.Storage

  @spec resolve(binary()) :: {:ok, Storage.Project.t()} | {:error, :not_found}
  def resolve(ref) do
    case Ecto.UUID.cast(ref) do
      {:ok, _uuid} ->
        try do
          {:ok, Storage.get_project!(ref)}
        rescue
          Ecto.NoResultsError ->
            case Storage.get_project_by_slug(ref) do
              nil -> {:error, :not_found}
              project -> {:ok, project}
            end
        end

      :error ->
        case Storage.get_project_by_slug(ref) do
          nil -> {:error, :not_found}
          project -> {:ok, project}
        end
    end
  end
end
