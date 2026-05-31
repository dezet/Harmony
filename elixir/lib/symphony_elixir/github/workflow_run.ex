defmodule SymphonyElixir.Github.WorkflowRun do
  @moduledoc """
  Normalized GitHub Actions workflow run data.
  """

  defstruct [:id, :name, :head_sha, :status, :conclusion, :url]

  @type t :: %__MODULE__{}

  @spec from_api(map()) :: t()
  def from_api(raw) when is_map(raw) do
    %__MODULE__{
      id: raw["id"],
      name: raw["name"],
      head_sha: raw["head_sha"],
      status: raw["status"],
      conclusion: raw["conclusion"],
      url: raw["html_url"]
    }
  end
end
