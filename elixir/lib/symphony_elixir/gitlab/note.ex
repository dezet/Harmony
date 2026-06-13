defmodule SymphonyElixir.Gitlab.Note do
  @moduledoc "Normalized GitLab MR note (comment) data."

  defstruct [:id, :body, :author]

  @type t :: %__MODULE__{}

  @spec from_api(map()) :: t()
  def from_api(raw) when is_map(raw) do
    %__MODULE__{id: raw["id"], body: raw["body"], author: get_in(raw, ["author", "username"])}
  end
end
