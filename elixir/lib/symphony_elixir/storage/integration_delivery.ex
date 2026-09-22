defmodule SymphonyElixir.Storage.IntegrationDelivery do
  @moduledoc "Durable outbox effect and its provider-facing retry state."

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Storage.IntegrationConnection
  alias SymphonyElixir.Storage.IntakeCase

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "integration_deliveries" do
    belongs_to(:case, IntakeCase, foreign_key: :case_id)
    belongs_to(:connection, IntegrationConnection, foreign_key: :connection_id)
    field(:operation, :string)
    field(:dedupe_key, :string)
    field(:payload, :map, default: %{})
    field(:status, :string, default: "pending")
    field(:attempts, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:lease_token, :string)
    field(:lease_until, :utc_datetime_usec)
    field(:provider_id, :string)
    field(:first_attempt_at, :utc_datetime_usec)
    field(:sent_at, :utc_datetime_usec)
    field(:last_error_code, :string)
    field(:lock_version, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :case_id,
      :connection_id,
      :operation,
      :dedupe_key,
      :payload,
      :status,
      :attempts,
      :next_attempt_at,
      :lease_token,
      :lease_until,
      :provider_id,
      :first_attempt_at,
      :sent_at,
      :last_error_code,
      :lock_version
    ])
    |> validate_required([:operation, :dedupe_key, :payload, :status, :attempts, :next_attempt_at, :lock_version])
    |> validate_inclusion(:operation, ~w(linear_create email sms analysis jira_comment))
    |> validate_inclusion(:status, ~w(pending running retry_wait succeeded failed unknown paused))
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> validate_number(:lock_version, greater_than_or_equal_to: 1)
    |> assoc_constraint(:case)
    |> assoc_constraint(:connection)
    |> unique_constraint(:dedupe_key, name: :integration_deliveries_dedupe_key_index)
  end
end
