defmodule SymphonyElixir.Evidence.Capability do
  @moduledoc """
  Checks whether browser evidence tooling is available to the runtime.
  """

  @required_tools [playwright_mcp: "playwright-mcp"]

  @spec check(keyword()) :: {:ok, map()} | {:error, term()}
  def check(opts \\ []) when is_list(opts) do
    probe_command = Keyword.get(opts, :probe_command, &default_probe_command/1)

    results =
      Enum.map(@required_tools, fn {key, command} ->
        {key, probe_command.(command)}
      end)

    missing =
      results
      |> Enum.reject(fn {_key, result} -> available?(result) end)
      |> Enum.map(fn {key, _result} -> key end)

    if missing == [] do
      {:ok, Map.new(results, fn {key, _result} -> {key, true} end)}
    else
      {:error, {:browser_evidence_unavailable, missing}}
    end
  end

  defp default_probe_command(command) do
    case System.find_executable(command) do
      nil -> {:error, :enoent}
      path -> {:ok, path}
    end
  end

  defp available?({:ok, _value}), do: true
  defp available?(_result), do: false
end
