defmodule SymphonyElixir.Storage.Blocker do
  @moduledoc """
  Durable blocker that suppresses retry loops for a target and reason.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Storage.{Project, WorkRun}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "blockers" do
    belongs_to(:project, Project)
    belongs_to(:work_run, WorkRun)
    field(:target_type, :string)
    field(:target_id, :string)
    field(:reason, :string)
    field(:status, :string, default: "open")
    field(:metadata, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(blocker, attrs) do
    blocker
    |> cast(attrs, [:project_id, :work_run_id, :target_type, :target_id, :reason, :status, :metadata])
    |> validate_required([:project_id, :target_type, :target_id, :reason, :status, :metadata])
    |> assoc_constraint(:project)
    |> assoc_constraint(:work_run)
  end
end
