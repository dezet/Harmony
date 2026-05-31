defmodule SymphonyElixir.Storage.PullRequestLink do
  @moduledoc """
  Durable association between a GitHub pull request and an optional Linear issue.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Storage.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pull_request_links" do
    belongs_to(:project, Project)
    field(:github_owner, :string)
    field(:github_repo, :string)
    field(:github_pr_number, :integer)
    field(:github_head_sha, :string)
    field(:linear_issue_id, :string)
    field(:linear_identifier, :string)
    field(:linear_url, :string)
    field(:metadata, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(pull_request_link, attrs) do
    pull_request_link
    |> cast(attrs, [
      :project_id,
      :github_owner,
      :github_repo,
      :github_pr_number,
      :github_head_sha,
      :linear_issue_id,
      :linear_identifier,
      :linear_url,
      :metadata
    ])
    |> validate_required([:project_id, :github_owner, :github_repo, :github_pr_number, :metadata])
    |> assoc_constraint(:project)
    |> unique_constraint(:github_pr_number, name: :pull_request_links_project_id_github_owner_github_repo_github_pr_number_index)
  end
end
