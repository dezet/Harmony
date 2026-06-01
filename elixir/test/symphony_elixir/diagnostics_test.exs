defmodule SymphonyElixir.DiagnosticsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Diagnostics.Sandbox

  test "reports bubblewrap missing" do
    executable = fn "bwrap" -> nil end
    read_file = fn _path -> {:error, :enoent} end

    report =
      Sandbox.report(
        executable: executable,
        read_file: read_file,
        thread_sandbox: "danger-full-access"
      )

    refute report.bubblewrap_available
    assert report.thread_sandbox == "danger-full-access"
    assert report.posture == "danger_full_access"
  end

  test "reports restricted unprivileged user namespaces" do
    executable = fn "bwrap" -> "/usr/bin/bwrap" end
    read_file = fn "/proc/sys/kernel/apparmor_restrict_unprivileged_userns" -> {:ok, "1\n"} end

    report =
      Sandbox.report(
        executable: executable,
        read_file: read_file,
        thread_sandbox: "workspace-write"
      )

    assert report.bubblewrap_available
    assert report.apparmor_restrict_unprivileged_userns == 1
  end
end
