defmodule SymphonyElixir.Diagnostics.Sandbox do
  @moduledoc """
  Reports local sandbox capability and configured sandbox posture.
  """

  @apparmor_userns_path "/proc/sys/kernel/apparmor_restrict_unprivileged_userns"

  defstruct [
    :bubblewrap_available,
    :apparmor_restrict_unprivileged_userns,
    :thread_sandbox,
    :turn_sandbox_type,
    :posture,
    warnings: []
  ]

  @type t :: %__MODULE__{
          bubblewrap_available: boolean(),
          apparmor_restrict_unprivileged_userns: integer() | nil,
          thread_sandbox: String.t() | nil,
          turn_sandbox_type: String.t() | nil,
          posture: String.t(),
          warnings: [String.t()]
        }

  @spec report(keyword()) :: t()
  def report(opts \\ []) when is_list(opts) do
    executable = Keyword.get(opts, :executable, &System.find_executable/1)
    read_file = Keyword.get(opts, :read_file, &File.read/1)
    thread_sandbox = Keyword.get(opts, :thread_sandbox)
    turn_sandbox_policy = Keyword.get(opts, :turn_sandbox_policy, %{})

    bubblewrap_available = not is_nil(executable.("bwrap"))
    apparmor_restrict_unprivileged_userns = read_apparmor_restrict_unprivileged_userns(read_file)
    turn_sandbox_type = sandbox_policy_type(turn_sandbox_policy)
    posture = posture(thread_sandbox, turn_sandbox_type)

    %__MODULE__{
      bubblewrap_available: bubblewrap_available,
      apparmor_restrict_unprivileged_userns: apparmor_restrict_unprivileged_userns,
      thread_sandbox: thread_sandbox,
      turn_sandbox_type: turn_sandbox_type,
      posture: posture,
      warnings: warnings(bubblewrap_available, apparmor_restrict_unprivileged_userns, posture)
    }
  end

  defp read_apparmor_restrict_unprivileged_userns(read_file) when is_function(read_file, 1) do
    case read_file.(@apparmor_userns_path) do
      {:ok, value} -> parse_integer(value)
      {:error, _reason} -> nil
    end
  end

  defp sandbox_policy_type(%{} = policy), do: Map.get(policy, :type) || Map.get(policy, "type")
  defp sandbox_policy_type(_policy), do: nil

  defp posture(thread_sandbox, turn_sandbox_type) do
    cond do
      thread_sandbox in ["danger-full-access", "dangerFullAccess"] ->
        "danger_full_access"

      turn_sandbox_type in ["dangerFullAccess", "danger-full-access"] ->
        "danger_full_access"

      true ->
        "workspace_sandbox_requested"
    end
  end

  defp warnings(bubblewrap_available, apparmor_restrict_unprivileged_userns, posture) do
    []
    |> maybe_warn(not bubblewrap_available, "bubblewrap executable is not available")
    |> maybe_warn(
      apparmor_restrict_unprivileged_userns == 1,
      "unprivileged user namespaces are restricted by AppArmor"
    )
    |> maybe_warn(posture == "danger_full_access", "Codex sandbox posture is danger full access")
    |> Enum.reverse()
  end

  defp maybe_warn(warnings, true, warning), do: [warning | warnings]
  defp maybe_warn(warnings, false, _warning), do: warnings

  defp parse_integer(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp parse_integer(_value), do: nil
end
