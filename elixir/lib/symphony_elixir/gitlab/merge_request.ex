defmodule SymphonyElixir.Gitlab.MergeRequest do
  @moduledoc "Normalized GitLab merge request data used by Harmony work sources."

  defstruct [
    :number, :title, :body, :url, :head_sha, :head_ref, :base_ref,
    :head_repo_full_name, :base_repo_full_name, :project_id
  ]

  @type t :: %__MODULE__{}

  @spec from_api(map()) :: t()
  def from_api(raw) when is_map(raw) do
    %__MODULE__{
      number: raw["iid"],
      title: raw["title"],
      body: raw["description"],
      url: raw["web_url"],
      head_sha: raw["sha"] || get_in(raw, ["diff_refs", "head_sha"]),
      head_ref: raw["source_branch"],
      base_ref: raw["target_branch"],
      head_repo_full_name: to_string_or_nil(raw["source_project_id"]),
      base_repo_full_name: to_string_or_nil(raw["target_project_id"]),
      project_id: raw["project_id"] || raw["target_project_id"]
    }
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v), do: to_string(v)
end
