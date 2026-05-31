defmodule SymphonyElixir.Github.Comment do
  @moduledoc """
  Normalized GitHub issue comment data for PR comment polling.
  """

  defstruct [:id, :body, :author]

  @type t :: %__MODULE__{}

  @spec from_api(map()) :: t()
  def from_api(raw) when is_map(raw) do
    %__MODULE__{
      id: raw["id"],
      body: raw["body"],
      author: get_in(raw, ["user", "login"])
    }
  end
end
