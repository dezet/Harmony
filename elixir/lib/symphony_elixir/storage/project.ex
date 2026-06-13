defmodule SymphonyElixir.Storage.Project do
  @moduledoc """
  Durable project configuration synchronized from projects/*.yaml.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field(:slug, :string)
    field(:linear_project_slug, :string)
    field(:linear_team_key, :string)
    field(:linear_human_review_state, :string)
    field(:forge_type, :string, default: "github")
    field(:forge_owner, :string)
    field(:forge_repo, :string)
    field(:forge_base_branch, :string)
    field(:forge_base_url, :string)
    field(:config_version, :integer, default: 1)
    field(:config, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :slug,
      :linear_project_slug,
      :linear_team_key,
      :linear_human_review_state,
      :forge_type,
      :forge_owner,
      :forge_repo,
      :forge_base_branch,
      :forge_base_url,
      :config_version,
      :config
    ])
    |> validate_required([:slug, :forge_owner, :forge_repo, :forge_base_branch, :forge_type, :config_version, :config])
    |> unique_constraint(:slug)
  end
end
