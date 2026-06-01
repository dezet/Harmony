defmodule SymphonyElixir.Github.PullRequest do
  @moduledoc """
  Normalized GitHub pull request data used by Harmony work sources.
  """

  defstruct [
    :number,
    :title,
    :body,
    :url,
    :head_sha,
    :head_ref,
    :head_repo_full_name,
    :base_ref,
    :base_repo_full_name
  ]

  @type t :: %__MODULE__{}

  @spec from_api(map()) :: t()
  def from_api(raw) when is_map(raw) do
    %__MODULE__{
      number: raw["number"],
      title: raw["title"],
      body: raw["body"],
      url: raw["html_url"],
      head_sha: get_in(raw, ["head", "sha"]),
      head_ref: get_in(raw, ["head", "ref"]),
      head_repo_full_name: get_in(raw, ["head", "repo", "full_name"]),
      base_ref: get_in(raw, ["base", "ref"]),
      base_repo_full_name: get_in(raw, ["base", "repo", "full_name"])
    }
  end
end
