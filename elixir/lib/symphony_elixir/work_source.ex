defmodule SymphonyElixir.WorkSource do
  @moduledoc """
  Behavior for polling work candidates from external systems.
  """

  @callback fetch_candidates(keyword()) :: {:ok, [SymphonyElixir.WorkRun.t()]} | {:error, term()}
end
