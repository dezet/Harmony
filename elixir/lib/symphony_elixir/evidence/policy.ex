defmodule SymphonyElixir.Evidence.Policy do
  @moduledoc """
  Determines whether a work run requires browser evidence.
  """

  @default_frontend_paths ["assets/", "priv/static/", "lib/", "web/", "src/"]

  @spec requires_browser_evidence?([String.t()], keyword()) :: boolean()
  def requires_browser_evidence?(changed_paths, opts \\ []) when is_list(changed_paths) do
    prefixes = Keyword.get(opts, :frontend_paths, @default_frontend_paths)

    Enum.any?(changed_paths, fn path ->
      is_binary(path) and Enum.any?(prefixes, &String.starts_with?(path, &1))
    end)
  end
end
