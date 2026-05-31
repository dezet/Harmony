defmodule SymphonyElixir.Repo do
  @moduledoc """
  Postgres repository for durable Harmony runtime state.
  """

  use Ecto.Repo,
    otp_app: :symphony_elixir,
    adapter: Ecto.Adapters.Postgres
end
