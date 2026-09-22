defmodule SymphonyElixir.Storage.IntakeEvent do
  @moduledoc "Append-only audit event for intake cases and automation rules."

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Storage.AutomationRule
  alias SymphonyElixir.Storage.IntakeCase

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "intake_events" do
    belongs_to(:case, IntakeCase, foreign_key: :case_id)
    belongs_to(:rule, AutomationRule)
    field(:type, :string)
    field(:payload, :map, default: %{})
    field(:actor, :string, default: "system")
    field(:occurred_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:case_id, :rule_id, :type, :payload, :actor, :occurred_at])
    |> validate_required([:type, :payload, :actor, :occurred_at])
    |> validate_inclusion(:actor, ~w(system operator))
    |> assoc_constraint(:case)
    |> assoc_constraint(:rule)
  end
end
