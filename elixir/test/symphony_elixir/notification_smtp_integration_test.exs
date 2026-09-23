defmodule SymphonyElixir.NotificationsSmtpIntegrationTest do
  # G-SMTP (plan §10.5): excluded by default in test_helper.exs; run explicitly with
  # `mix test test/symphony_elixir/notification_smtp_integration_test.exs --include smtp_integration`.
  use ExUnit.Case, async: false

  alias SymphonyElixir.Notifications.{Smtp, Templates}
  alias SymphonyElixir.Storage.IntegrationConnection

  @moduletag :smtp_integration
  @moduletag timeout: 120_000

  @mailpit_image "docker.io/axllent/mailpit:v1.20.0"
  @recipient "synthetic-recipient@harmony.test"
  @domain "harmony.test"

  setup do
    engine = container_engine!()
    smtp_port = free_loopback_port!()
    api_port = free_loopback_port!()
    name = "harmony-smtp-it-#{System.unique_integer([:positive])}-#{System.os_time(:millisecond)}"

    {output, status} =
      System.cmd(
        engine,
        [
          "run",
          "--detach",
          "--name",
          name,
          "--publish",
          "127.0.0.1:#{smtp_port}:1025",
          "--publish",
          "127.0.0.1:#{api_port}:8025",
          "--env",
          "MP_SMTP_AUTH_ACCEPT_ANY=true",
          "--env",
          "MP_SMTP_AUTH_ALLOW_INSECURE=true",
          @mailpit_image
        ],
        stderr_to_stdout: true
      )

    on_exit(fn -> System.cmd(engine, ["rm", "--force", name], stderr_to_stdout: true) end)
    assert status == 0, "could not start Mailpit fixture: #{output}"

    api = "http://127.0.0.1:#{api_port}/api/v1"
    wait_for_mailpit!(api, System.monotonic_time(:millisecond) + 30_000)

    %{api: api, smtp_port: smtp_port}
  end

  test "the production adapter delivers one escaped message with a stable Message-ID", %{api: api, smtp_port: smtp_port} do
    delivery_id = Ecto.UUID.generate()
    message_id = "<harmony.#{delivery_id}@#{@domain}>"

    connection = %IntegrationConnection{
      kind: "smtp",
      enabled: true,
      secret: "synthetic-smtp-password",
      settings: %{
        "host" => "127.0.0.1",
        "port" => smtp_port,
        "tls_mode" => "none",
        "username" => "synthetic-user",
        "from_email" => "alerts@#{@domain}",
        "from_name" => "Harmony",
        "message_id_domain" => @domain
      }
    }

    assert {:ok, email} =
             Templates.render_email(%{
               delivery_id: delivery_id,
               message_id_domain: @domain,
               recipient: @recipient,
               from_email: "alerts@#{@domain}",
               from_name: "Harmony",
               priority_name: "High",
               jira_key: "OPS-142",
               project_name: "Finanse",
               title: "<script>alert('x')</script>",
               jira_url: "https://jira.example.test/browse/OPS-142",
               harmony_url: "https://harmony.example.test/cases/jira_#{delivery_id}",
               detected_at: DateTime.utc_now()
             })

    assert {:ok, %{provider_id: ^message_id}} =
             Smtp.deliver_email(email, connection,
               smtp_allowed_hosts: ["127.0.0.1"],
               allow_plaintext_loopback: true
             )

    assert %{"messages" => [summary]} = get_json!("#{api}/messages")
    assert [%{"Address" => @recipient}] = summary["To"]
    assert summary["Cc"] in [nil, []]
    assert summary["Bcc"] in [nil, []]
    assert summary["Subject"] == "[Harmony] High · OPS-142 · Finanse"
    assert summary["MessageID"] in [message_id, String.slice(message_id, 1..-2//1)]

    message = get_json!("#{api}/message/#{summary["ID"]}")
    assert message["HTML"] =~ "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"
    refute message["HTML"] =~ "<script>"
    assert message["Text"] =~ "Naprawa nie została uruchomiona."
  end

  defp container_engine! do
    System.find_executable("podman") || System.find_executable("docker") ||
      flunk("G-SMTP requires Podman or Docker; no container engine found")
  end

  defp free_loopback_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp wait_for_mailpit!(api, deadline) do
    case Req.get("#{api}/messages", retry: false, receive_timeout: 1_000) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      _not_ready ->
        if System.monotonic_time(:millisecond) > deadline, do: flunk("Mailpit fixture did not become ready")
        Process.sleep(250)
        wait_for_mailpit!(api, deadline)
    end
  end

  defp get_json!(url) do
    assert {:ok, %Req.Response{status: 200, body: body}} = Req.get(url, retry: false, receive_timeout: 5_000)
    body
  end
end
