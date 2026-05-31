defmodule SymphonyElixir.Storage.WorkEvent do
  @moduledoc """
  Append-only event emitted by Harmony runtime work sources and handoffs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Storage.{Project, WorkRun}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "work_events" do
    belongs_to(:project, Project)
    belongs_to(:work_run, WorkRun)
    field(:type, :string)
    field(:payload, :map, default: %{})
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(work_event, attrs) do
    work_event
    |> cast(attrs, [:project_id, :work_run_id, :type, :payload])
    |> validate_required([:project_id, :type, :payload])
    |> assoc_constraint(:project)
    |> assoc_constraint(:work_run)
  end
end
