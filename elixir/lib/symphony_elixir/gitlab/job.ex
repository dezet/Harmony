defmodule SymphonyElixir.Gitlab.Job do
  @moduledoc "Normalized GitLab pipeline job data."

  defstruct [:id, :name, :status]

  @type t :: %__MODULE__{}

  @spec from_api(map()) :: t()
  def from_api(raw) when is_map(raw) do
    %__MODULE__{id: raw["id"], name: raw["name"], status: raw["status"]}
  end
end
