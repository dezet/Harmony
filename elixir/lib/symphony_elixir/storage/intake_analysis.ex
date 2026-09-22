defmodule SymphonyElixir.Storage.IntakeAnalysis do
  @moduledoc "Versioned read-only analysis input and validated result."

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Storage.IntakeCase
  alias SymphonyElixir.Storage.WorkRun

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "intake_analyses" do
    belongs_to(:case, IntakeCase, foreign_key: :case_id)
    belongs_to(:work_run, WorkRun)
    field(:version, :integer)
    field(:status, :string, default: "queued")
    field(:input_snapshot, :map)
    field(:result, :map)
    field(:model, :string)
    field(:effort, :string)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:token_usage, :map)
    field(:error_code, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(analysis, attrs) do
    analysis
    |> cast(attrs, [
      :case_id,
      :work_run_id,
      :version,
      :status,
      :input_snapshot,
      :result,
      :model,
      :effort,
      :started_at,
      :completed_at,
      :token_usage,
      :error_code
    ])
    |> validate_required([:case_id, :version, :status, :input_snapshot, :model, :effort])
    |> validate_inclusion(:status, ~w(queued running succeeded failed needs_input))
    |> validate_number(:version, greater_than_or_equal_to: 1)
    |> assoc_constraint(:case)
    |> assoc_constraint(:work_run)
    |> unique_constraint(:version, name: :intake_analyses_case_id_version_index)
  end
end
