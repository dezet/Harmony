defmodule SymphonyElixir.AgentBackends.CliCommand do
  @moduledoc false

  @type run_result :: {:ok, {String.t(), non_neg_integer()}} | {:error, term()}

  @spec run(String.t(), [String.t()], Path.t(), keyword()) :: run_result()
  def run(command, args, workspace, opts) do
    runner = Keyword.get(opts, :run_command, &default_run_command/3)
    runner.(command, args, cd: workspace, stderr_to_stdout: true)
  end

  @spec emit(keyword(), map()) :: :ok
  def emit(opts, message) when is_map(message) do
    on_message = Keyword.get(opts, :on_message, fn _message -> :ok end)
    on_message.(message)
    :ok
  end

  @spec default_run_command(String.t(), [String.t()], keyword()) :: run_result()
  def default_run_command(command, args, opts) do
    case System.find_executable(command) do
      nil -> {:error, {:executable_not_found, command}}
      executable -> {:ok, System.cmd(executable, args, opts)}
    end
  end
end
