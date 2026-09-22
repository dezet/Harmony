defmodule SymphonyElixir.Storage.IntegrationConnection do
  @moduledoc "Persisted credentials and connection settings for intake providers."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "integration_connections" do
    field(:kind, :string)
    field(:name, :string)
    field(:settings, :map, default: %{})
    field(:secret, SymphonyElixir.Encrypted.Binary, redact: true)
    field(:secret_version, :integer, default: 1)
    field(:enabled, :boolean, default: false)
    field(:last_checked_at, :utc_datetime_usec)
    field(:health, :string, default: "unchecked")
    field(:error_code, :string)
    field(:lock_version, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(connection, attrs) do
    connection
    |> cast(
      attrs,
      [
        :kind,
        :name,
        :settings,
        :secret,
        :secret_version,
        :enabled,
        :last_checked_at,
        :health,
        :error_code,
        :lock_version
      ],
      empty_values: []
    )
    |> validate_required([:kind, :name, :settings, :secret_version, :enabled, :health, :lock_version])
    |> validate_inclusion(:kind, ~w(jira_cloud smtp smsapi))
    |> validate_inclusion(:health, ~w(unchecked ok error))
    |> validate_number(:secret_version, greater_than_or_equal_to: 1)
    |> validate_number(:lock_version, greater_than_or_equal_to: 1)
    |> unique_constraint(:settings, name: :integration_connections_jira_site_url_index)
  end
end
