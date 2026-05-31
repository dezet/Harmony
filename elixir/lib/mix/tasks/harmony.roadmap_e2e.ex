defmodule Mix.Tasks.Harmony.RoadmapE2e do
  use Mix.Task

  alias SymphonyElixir.{HttpServer, RoadmapE2E}

  @moduledoc """
  Seeds deterministic local roadmap E2E proof scenarios.
  """
  @shortdoc "Seeds deterministic roadmap E2E proof scenarios"

  @switches [port: :integer, once: :boolean]
  @aliases [p: :port]
  @default_port 4000

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    scenario =
      case argv do
        [value] -> value
        [] -> Mix.raise("Missing scenario. Expected one of: #{Enum.join(RoadmapE2E.scenarios(), ", ")}")
        _many -> Mix.raise("Expected exactly one scenario. Expected one of: #{Enum.join(RoadmapE2E.scenarios(), ", ")}")
      end

    install_runtime_guards()
    Mix.Task.run("app.start")

    port = Keyword.get(opts, :port, @default_port)
    once? = Keyword.get(opts, :once, false)

    case RoadmapE2E.run(scenario, port: port) do
      {:ok, summary} ->
        Mix.shell().info(RoadmapE2E.format_summary(summary))

        if once? do
          :ok
        else
          serve_forever(port)
        end

      {:error, reason} ->
        Mix.raise("roadmap E2E scenario failed: #{inspect(reason)}")
    end
  end

  defp serve_forever(port) do
    case HttpServer.start_link(port: port, host: "127.0.0.1") do
      {:ok, _pid} ->
        Mix.shell().info("serving=true")
        Process.sleep(:infinity)

      {:error, {:already_started, _pid}} ->
        Mix.shell().info("serving=true")
        Process.sleep(:infinity)

      {:error, reason} ->
        Mix.raise("failed to start roadmap E2E HTTP server: #{inspect(reason)}")
    end
  end

  defp install_runtime_guards do
    Application.put_env(:symphony_elixir, :work_source_fetchers, [])
  end
end
