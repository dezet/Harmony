defmodule SymphonyElixir.IntakeAnalysisPolicyGisoTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Intake.AnalysisPolicy

  @permission_profile "analysis_ro"
  @line_bytes 1_048_576

  @tag :giso
  test "installed Codex profile confines command exec without starting a model turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-analysis-giso-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(test_root, "workspace")
    project_codex_home = Path.join(workspace, ".codex")
    source_codex_home = Path.join(test_root, "source-codex-home")
    canary = Path.join(workspace, "read-canary.txt")
    created_canary = Path.join(workspace, "write-canary.txt")
    auth_canary = "AUTH-CANARY-SYNTHETIC-73"
    secret_canary = "SECRET-CANARY-SYNTHETIC-74"
    operator_config_canary = "OPERATOR-CONFIG-CANARY-SYNTHETIC-80"

    env_names = [
      "CODEX_HOME",
      "CLOAK_KEY",
      "JIRA_API_TOKEN",
      "LINEAR_API_KEY",
      "SMTP_PASSWORD",
      "OPENAI_API_KEY",
      "CODEX_API_KEY"
    ]

    previous_env = Map.new(env_names, &{&1, System.get_env(&1)})
    codex = System.find_executable("codex")

    try do
      assert is_binary(codex), "Codex CLI is required for this real G-ISO test"

      File.mkdir_p!(workspace)
      File.mkdir_p!(source_codex_home)
      File.mkdir_p!(project_codex_home)
      File.write!(canary, "workspace-readable-canary\n")

      File.write!(
        Path.join(project_codex_home, "config.toml"),
        """
        sandbox_mode = "danger-full-access"

        [permissions.analysis_ro.filesystem]
        ":root" = "write"

        [permissions.analysis_ro.network]
        enabled = true
        """
      )

      File.write!(Path.join(source_codex_home, "auth.json"), ~s({"synthetic_secret":"#{auth_canary}"}))
      File.write!(Path.join(source_codex_home, "config.toml"), "operator_secret = \"#{operator_config_canary}\"\n")

      {version, version_status} = System.cmd(codex, ["--version"])
      assert version_status == 0, "Codex CLI version command failed: #{version}"
      assert String.starts_with?(String.trim(version), "codex-cli ")
      IO.puts("G-ISO CLI: #{String.trim(version)}")

      System.put_env("CODEX_HOME", source_codex_home)
      System.put_env("CLOAK_KEY", secret_canary)
      System.put_env("JIRA_API_TOKEN", "JIRA-SECRET-CANARY-75")
      System.put_env("LINEAR_API_KEY", "LINEAR-SECRET-CANARY-76")
      System.put_env("SMTP_PASSWORD", "SMTP-SECRET-CANARY-77")
      System.put_env("OPENAI_API_KEY", "OPENAI-SECRET-CANARY-78")
      System.put_env("CODEX_API_KEY", "CODEX-SECRET-CANARY-79")

      assert {:ok, runtime} = AnalysisPolicy.prepare_runtime()
      assert File.read!(Path.join(runtime.codex_home, "auth.json")) =~ auth_canary

      server_environment =
        Map.new(runtime.port_environment, fn {key, value} ->
          normalized_value = if value == false, do: false, else: List.to_string(value)
          {List.to_string(key), normalized_value}
        end)

      assert server_environment["CODEX_HOME"] == runtime.codex_home
      assert server_environment["OPENAI_API_KEY"] == "OPENAI-SECRET-CANARY-78"
      assert server_environment["CODEX_API_KEY"] == "CODEX-SECRET-CANARY-79"

      for key <- ["CLOAK_KEY", "JIRA_API_TOKEN", "LINEAR_API_KEY", "SMTP_PASSWORD"] do
        assert server_environment[key] == false
      end

      IO.puts("G-ISO process env: private CODEX_HOME, API key canaries present, integration secrets cleared")

      port = start_app_server(codex, workspace, runtime.port_environment)

      try do
        assert %{"result" => _} =
                 rpc(port, 1, "initialize", %{
                   "capabilities" => %{"experimentalApi" => true},
                   "clientInfo" => %{"name" => "symphony-giso", "title" => "G-ISO", "version" => "1"}
                 })

        assert :ok = send_notification(port, "initialized", %{})

        profile_response = rpc(port, 2, "permissionProfile/list", %{})
        profile_ids = get_in(profile_response, ["result", "data"]) |> Enum.map(& &1["id"])
        assert @permission_profile in profile_ids
        IO.puts("G-ISO permissionProfile/list: #{Enum.join(profile_ids, ",")}")

        thread_response =
          rpc(port, 3, "thread/start", %{
            "approvalPolicy" => "on-request",
            "cwd" => workspace,
            "dynamicTools" => [],
            "ephemeral" => true,
            "permissions" => @permission_profile,
            "runtimeWorkspaceRoots" => [workspace]
          })

        assert %{"result" => %{"thread" => thread}} = thread_response
        assert is_binary(thread["id"])
        IO.puts("G-ISO thread/start: profile=#{@permission_profile}, dynamicTools=[]")

        read_result = command_exec(port, 4, workspace, ["/bin/cat", canary])
        assert read_result["exitCode"] == 0
        assert read_result["stdout"] == "workspace-readable-canary\n"
        IO.puts("G-ISO workspace read: exitCode=0 stdout=workspace-readable-canary")

        auth_result = command_exec(port, 5, workspace, ["/bin/cat", Path.join(runtime.codex_home, "auth.json")])
        refute auth_result["exitCode"] == 0
        assert auth_result["stderr"] =~ "No such file or directory"
        refute String.contains?(auth_result["stdout"] || "", auth_canary)
        refute String.contains?(auth_result["stderr"] || "", auth_canary)
        IO.puts("G-ISO synthetic auth read: exitCode=#{auth_result["exitCode"]}, canary_present=false")

        operator_config_result =
          command_exec(port, 6, workspace, ["/bin/cat", Path.join(source_codex_home, "config.toml")])

        refute operator_config_result["exitCode"] == 0
        refute String.contains?(operator_config_result["stdout"] || "", operator_config_canary)
        IO.puts("G-ISO operator config read: exitCode=#{operator_config_result["exitCode"]}, canary_present=false")

        env_result = command_exec(port, 7, workspace, ["/usr/bin/env"])
        refute String.contains?(env_result["stdout"], secret_canary)
        refute String.contains?(env_result["stdout"], "JIRA-SECRET-CANARY-75")
        refute String.contains?(env_result["stdout"], "LINEAR-SECRET-CANARY-76")
        refute String.contains?(env_result["stdout"], "SMTP-SECRET-CANARY-77")
        refute String.contains?(env_result["stdout"], "OPENAI-SECRET-CANARY-78")
        refute String.contains?(env_result["stdout"], "CODEX-SECRET-CANARY-79")

        refute env_result["stdout"] =~
                 ~r/(CLOAK_KEY|JIRA_API_TOKEN|LINEAR_API_KEY|SMTP_PASSWORD|OPENAI_API_KEY|CODEX_API_KEY)=/

        IO.puts("G-ISO command env: exitCode=#{env_result["exitCode"]}, API and integration canaries absent")

        python = System.find_executable("python3")
        assert is_binary(python)

        proc_audit_source = """
        import json, os, sys

        auth_path = os.path.abspath(sys.argv[1])
        auth_canary = os.fsencode(sys.argv[2])
        env_markers = [
            b'CLOAK_KEY=', b'JIRA_API_TOKEN=', b'LINEAR_API_KEY=', b'SMTP_PASSWORD=',
            b'OPENAI_API_KEY=', b'CODEX_API_KEY=',
            b'OPENAI-SECRET-CANARY-78', b'CODEX-SECRET-CANARY-79'
        ]
        env_hits = []
        root_auth_hits = []
        fd_auth_hits = []
        readable_env_count = 0
        process_ids = [pid for pid in os.listdir('/proc') if pid.isdigit()]

        for pid in process_ids:
            try:
                env = open('/proc/{}/environ'.format(pid), 'rb').read()
                readable_env_count += 1
                if any(marker in env for marker in env_markers):
                    env_hits.append(pid)
            except (OSError, PermissionError):
                pass

            try:
                root_auth = open('/proc/{}/root{}'.format(pid, auth_path), 'rb').read()
                if auth_canary in root_auth:
                    root_auth_hits.append(pid)
            except (OSError, PermissionError):
                pass

            try:
                fd_names = os.listdir('/proc/{}/fd'.format(pid))
            except (OSError, PermissionError):
                continue

            for fd in fd_names:
                fd_path = '/proc/{}/fd/{}'.format(pid, fd)
                try:
                    target = os.readlink(fd_path).removesuffix(' (deleted)')
                    if os.path.abspath(target) != auth_path:
                        continue
                    fd_contents = open(fd_path, 'rb').read()
                    if auth_canary in fd_contents:
                        fd_auth_hits.append(pid)
                        break
                except (OSError, PermissionError):
                    pass

        print(json.dumps({
            'env_hits': env_hits,
            'root_auth_hits': root_auth_hits,
            'fd_auth_hits': fd_auth_hits,
            'readable_env_count': readable_env_count,
            'process_count': len(process_ids)
        }, sort_keys=True))
        """

        proc_audit_result =
          command_exec(port, 8, workspace, [
            python,
            "-c",
            proc_audit_source,
            Path.join(runtime.codex_home, "auth.json"),
            auth_canary
          ])

        assert proc_audit_result["exitCode"] == 0
        proc_audit = Jason.decode!(proc_audit_result["stdout"])
        assert proc_audit["process_count"] > 0
        assert proc_audit["readable_env_count"] > 0
        assert proc_audit["env_hits"] == []
        assert proc_audit["root_auth_hits"] == []
        assert proc_audit["fd_auth_hits"] == []

        IO.puts(
          "G-ISO /proc canaries: process_env=absent (readable=#{proc_audit["readable_env_count"]}), " <>
            "auth_root=absent, auth_fd=absent"
        )

        original_hash = canary |> File.read!() |> then(&:crypto.hash(:sha256, &1))
        write_result = command_exec(port, 9, workspace, ["/usr/bin/touch", created_canary])
        edit_result = command_exec(port, 10, workspace, ["/usr/bin/sed", "-i", "s/readable/changed/", canary])
        delete_result = command_exec(port, 11, workspace, ["/bin/rm", canary])
        final_hash = canary |> File.read!() |> then(&:crypto.hash(:sha256, &1))

        refute write_result["exitCode"] == 0
        refute edit_result["exitCode"] == 0
        refute delete_result["exitCode"] == 0
        assert write_result["stderr"] =~ "Read-only file system"
        assert edit_result["stderr"] =~ "Read-only file system"
        assert delete_result["stderr"] =~ "Read-only file system"
        refute File.exists?(created_canary)
        assert final_hash == original_hash

        IO.puts(
          "G-ISO workspace writes: create=#{write_result["exitCode"]}, edit=#{edit_result["exitCode"]}, " <>
            "delete=#{delete_result["exitCode"]}, hash_unchanged=true"
        )

        IO.puts(
          "G-ISO project config override: sandbox_mode=danger-full-access, " <>
            "analysis_ro :root=write/network=true, workspace writes remain denied"
        )

        assert {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
        assert {:ok, {{127, 0, 0, 1}, network_port}} = :inet.sockname(listener)

        python_source =
          "import socket; s=socket.socket(); s.settimeout(1); s.connect(('127.0.0.1', #{network_port}))"

        network_result = command_exec(port, 12, workspace, [python, "-c", python_source])
        refute network_result["exitCode"] == 0
        assert network_result["stderr"] =~ "Operation not permitted"
        assert {:error, :timeout} = :gen_tcp.accept(listener, 100)
        :gen_tcp.close(listener)
        IO.puts("G-ISO loopback network: exitCode=#{network_result["exitCode"]}, listener_received=false")

        override_response =
          rpc(port, 13, "command/exec", %{
            "command" => ["/bin/echo", "must-not-run"],
            "cwd" => workspace,
            "permissionProfile" => @permission_profile,
            "sandboxPolicy" => %{"type" => "dangerFullAccess"}
          })

        assert Map.has_key?(override_response, "error")
        refute get_in(override_response, ["result", "stdout"]) == "must-not-run\n"
        IO.puts("G-ISO sandbox override: rejected=#{inspect(override_response["error"]["message"])}")
      after
        close_port(port)
        AnalysisPolicy.cleanup_runtime(runtime)
      end
    after
      Enum.each(previous_env, fn {name, value} -> restore_env(name, value) end)
      File.rm_rf(test_root)
    end
  end

  defp start_app_server(codex, workspace, environment) do
    Port.open(
      {:spawn_executable, String.to_charlist(codex)},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["app-server", "--strict-config"],
        cd: String.to_charlist(workspace),
        env: environment,
        line: @line_bytes
      ]
    )
  end

  defp send_notification(port, method, params) do
    Port.command(port, Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params}) <> "\n")
    :ok
  end

  defp rpc(port, id, method, params) do
    Port.command(
      port,
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}) <> "\n"
    )

    await_response(port, id)
  end

  defp command_exec(port, id, workspace, command) do
    %{"result" => result} =
      rpc(port, id, "command/exec", %{
        "command" => command,
        "cwd" => workspace,
        "permissionProfile" => @permission_profile
      })

    result
  end

  defp await_response(port, id) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(to_string(line)) do
          {:ok, %{"id" => ^id} = response} -> response
          _other -> await_response(port, id)
        end

      {^port, {:data, {:noeol, _line}}} ->
        await_response(port, id)

      {^port, {:exit_status, status}} ->
        flunk("Codex app-server exited before JSON-RPC response, status=#{status}")
    after
      30_000 ->
        flunk("Codex app-server timed out waiting for JSON-RPC id=#{id}")
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
