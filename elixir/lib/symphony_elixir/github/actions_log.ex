defmodule SymphonyElixir.Github.ActionsLog do
  @moduledoc """
  Helpers for preparing GitHub Actions log excerpts for agent prompts.
  """

  @default_max_bytes 12_000

  @spec excerpt(String.t() | nil) :: String.t()
  def excerpt(log_text), do: excerpt(log_text, [])

  @spec excerpt(String.t() | nil, keyword()) :: String.t()
  def excerpt(log_text, opts) when is_binary(log_text) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    if byte_size(log_text) <= max_bytes do
      log_text
    else
      "...\n" <> binary_part(log_text, byte_size(log_text), -max_bytes)
    end
  end

  def excerpt(_log_text, _opts), do: "No log excerpt captured."
end
