defmodule SymphonyElixir.Intake.ConnectionCheck do
  @moduledoc """
  Read-only connection test (spec §11.2): Jira reads the current user, SMTP
  opens EHLO/TLS/AUTH and closes the session without DATA, SMSAPI reads the
  account profile. No message is ever sent. The result is stored as the
  connection health.
  """

  alias SymphonyElixir.Intake.{Connections, JiraAccess}
  alias SymphonyElixir.Notifications.{Smsapi, Smtp}
  alias SymphonyElixir.Storage.IntegrationConnection

  @type result :: %{health: String.t(), checked_at: DateTime.t(), error_code: String.t() | nil}

  @spec run(IntegrationConnection.t(), keyword()) :: result()
  def run(%IntegrationConnection{} = connection, opts \\ []) do
    checked_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    updated = Connections.record_check(connection, safe_check(connection, opts), checked_at)
    %{health: updated.health, checked_at: checked_at, error_code: updated.error_code}
  end

  defp safe_check(connection, opts) do
    check(connection, opts)
  rescue
    _exception -> {:error, "connection_check_failed"}
  catch
    _kind, _reason -> {:error, "connection_check_failed"}
  end

  defp check(%IntegrationConnection{kind: "jira_cloud"} = connection, opts) do
    JiraAccess.check(connection, jira_opts(opts))
  end

  defp check(%IntegrationConnection{kind: "smtp"} = connection, opts) do
    Smtp.check_connection(connection, Keyword.get(opts, :smtp_opts, []))
  end

  defp check(%IntegrationConnection{kind: "smsapi"} = connection, opts) do
    Smsapi.check_account(connection, Keyword.get(opts, :smsapi_opts, []))
  end

  defp check(%IntegrationConnection{}, _opts), do: {:error, "unsupported_connection_kind"}

  defp jira_opts(opts) do
    case Keyword.get(opts, :jira_request_fun) do
      nil -> []
      request_fun -> [request_fun: request_fun]
    end
  end
end
