defmodule SymphonyElixir.Storage.Artifact do
  @moduledoc """
  Browser or runtime evidence artifact associated with a work run.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Storage.{Project, WorkRun}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "artifacts" do
    belongs_to(:project, Project)
    belongs_to(:work_run, WorkRun)
    field(:kind, :string)
    field(:path, :string)
    field(:metadata, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [:project_id, :work_run_id, :kind, :path, :metadata])
    |> validate_required([:project_id, :kind, :path, :metadata])
    |> assoc_constraint(:project)
    |> assoc_constraint(:work_run)
  end
end
