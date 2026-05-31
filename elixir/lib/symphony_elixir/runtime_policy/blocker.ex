defmodule SymphonyElixir.RuntimePolicy.Blocker do
  @moduledoc """
  Durable blocker recording helpers.
  """

  alias SymphonyElixir.Storage

  @spec record(map()) :: {:ok, term()} | {:error, term()}
  def record(attrs) when is_map(attrs), do: Storage.upsert_open_blocker(attrs)
end
