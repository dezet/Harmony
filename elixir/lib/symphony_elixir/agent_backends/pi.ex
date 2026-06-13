defmodule SymphonyElixir.AgentBackends.Pi do
  @moduledoc """
  Pi backend using the CLI JSON event stream mode.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.AgentBackends.CliCommand

  @impl true
  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, _issue, opts) do
    case CliCommand.run("pi", ["--mode", "json", prompt], workspace, opts) do
      {:ok, {output, 0}} -> parse_success(output, opts)
      {:ok, {output, exit_status}} -> {:error, {:pi_failed, exit_status, String.trim(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec capability_check(keyword()) :: :ok | {:error, :pi_not_found}
  def capability_check(opts) do
    find_executable = Keyword.get(opts, :find_executable, &System.find_executable/1)

    case find_executable.("pi") do
      path when is_binary(path) and path != "" -> :ok
      _missing -> {:error, :pi_not_found}
    end
  end

  defp parse_success(output, opts) do
    with {:ok, events} <- decode_events(output) do
      session_id = find_session_id(events)
      result = find_last_assistant_text(events) || output

      CliCommand.emit(opts, %{type: :agent_output, backend: :pi, output: result})

      {:ok,
       %{
         session_id: session_id,
         result: result,
         events: events
       }}
    end
  end

  defp decode_events(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, events} ->
      case Jason.decode(line) do
        {:ok, event} -> {:cont, {:ok, [event | events]}}
        {:error, reason} -> {:halt, {:error, {:invalid_pi_json_event, reason, line}}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_session_id(events) do
    events
    |> Enum.find_value(fn
      %{"type" => "session", "id" => id} when is_binary(id) -> id
      _event -> nil
    end)
    |> case do
      nil -> "pi-session"
      id -> id
    end
  end

  defp find_last_assistant_text(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"type" => "message_end", "message" => %{"role" => "assistant", "content" => content}} ->
        content_text(content)

      %{"type" => "turn_end", "message" => %{"role" => "assistant", "content" => content}} ->
        content_text(content)

      _event ->
        nil
    end)
  end

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _part -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp content_text(_content), do: nil
end
