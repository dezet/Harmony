defmodule SymphonyElixir.Storage.DedupeKey do
  @moduledoc """
  Persisted idempotency key for repeatable Harmony triggers.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Storage.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "dedupe_keys" do
    belongs_to(:project, Project)
    field(:key, :string)
    field(:scope, :string)
    field(:status, :string, default: "processed")
    field(:metadata, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(dedupe_key, attrs) do
    dedupe_key
    |> cast(attrs, [:project_id, :key, :scope, :status, :metadata])
    |> validate_required([:project_id, :key, :scope, :status, :metadata])
    |> assoc_constraint(:project)
    |> unique_constraint(:key, name: :dedupe_keys_project_id_key_index)
  end
end
