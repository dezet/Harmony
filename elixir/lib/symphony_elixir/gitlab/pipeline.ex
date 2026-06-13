defmodule SymphonyElixir.Gitlab.Pipeline do
  @moduledoc "Normalized GitLab pipeline data."

  defstruct [:id, :status, :ref, :sha, :url]

  @type t :: %__MODULE__{}

  @spec from_api(map()) :: t()
  def from_api(raw) when is_map(raw) do
    %__MODULE__{
      id: raw["id"],
      status: raw["status"],
      ref: raw["ref"],
      sha: raw["sha"],
      url: raw["web_url"]
    }
  end
end
