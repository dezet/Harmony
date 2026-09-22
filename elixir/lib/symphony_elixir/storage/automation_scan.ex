defmodule SymphonyElixir.Storage.AutomationScan do
  @moduledoc "Durable baseline and poll attempts for an automation rule."

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Storage.AutomationRule

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "automation_scans" do
    belongs_to(:rule, AutomationRule)
    field(:rule_config_version, :integer)
    field(:mode, :string)
    field(:status, :string, default: "pending")
    field(:generation, :binary_id)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:match_count, :integer, default: 0)
    field(:accepted_count, :integer, default: 0)
    field(:error_code, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(scan, attrs) do
    scan
    |> cast(attrs, [
      :rule_id,
      :rule_config_version,
      :mode,
      :status,
      :generation,
      :started_at,
      :finished_at,
      :match_count,
      :accepted_count,
      :error_code
    ])
    |> put_uuid_default(:generation)
    |> validate_required([:rule_id, :rule_config_version, :mode, :status, :generation, :match_count, :accepted_count])
    |> validate_inclusion(:mode, ~w(baseline poll preview))
    |> validate_inclusion(:status, ~w(pending running succeeded failed cancelled))
    |> validate_number(:rule_config_version, greater_than_or_equal_to: 1)
    |> validate_number(:match_count, greater_than_or_equal_to: 0)
    |> validate_number(:accepted_count, greater_than_or_equal_to: 0)
    |> assoc_constraint(:rule)
    |> unique_constraint(:generation, name: :automation_scans_rule_id_generation_index)
  end

  defp put_uuid_default(changeset, field) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, Ecto.UUID.generate())
      _value -> changeset
    end
  end
end
