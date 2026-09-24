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
    field(:forge_secret, SymphonyElixir.Encrypted.Binary, redact: true)
    field(:tracker_secret, SymphonyElixir.Encrypted.Binary, redact: true)
    field(:display_name, :string)
    field(:ui_color, :string, default: "purple")
    field(:config_version, :integer, default: 1)
    field(:config, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  @ui_colors ~w(purple gold teal)
  @required [:slug, :forge_owner, :forge_repo, :forge_base_branch, :forge_type, :ui_color, :config_version, :config]

  @type t :: %__MODULE__{}

  @doc "Sidebar colors a project may use; the color never encodes project health."
  @spec ui_colors() :: [String.t()]
  def ui_colors, do: @ui_colors

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
      :display_name,
      :ui_color,
      :config_version,
      :config
    ])
    |> validate_required(@required)
    |> update_change(:display_name, &trim/1)
    |> validate_length(:display_name, min: 1, max: 100)
    |> validate_inclusion(:ui_color, @ui_colors)
    |> check_constraint(:display_name, name: :projects_display_name_length_check)
    |> check_constraint(:ui_color, name: :projects_ui_color_check)
    |> unique_constraint(:slug)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  @spec secret_changeset(t(), map()) :: Ecto.Changeset.t()
  def secret_changeset(project, attrs) do
    cast(project, attrs, [:forge_secret, :tracker_secret], empty_values: [])
  end
end
