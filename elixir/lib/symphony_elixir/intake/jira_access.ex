defmodule SymphonyElixir.Intake.JiraAccess do
  @moduledoc """
  Read-only Jira Cloud access through a stored `jira_cloud` connection:
  identity check, board/filter/priority pickers and client options for
  previews. Nothing here writes to Jira, and provider bodies never leave this
  module; failures become stable error codes.
  """

  alias SymphonyElixir.Jira.CloudClient
  alias SymphonyElixir.Storage.IntegrationConnection

  @type picker :: :boards | :filters | :priorities
  @type item :: %{id: String.t(), name: String.t()}

  @spec client_opts(IntegrationConnection.t(), keyword()) ::
          {:ok, keyword()} | {:error, :connection_kind_mismatch | :credentials_missing}
  def client_opts(%IntegrationConnection{kind: "jira_cloud", secret: secret, settings: settings}, opts) do
    if is_binary(secret) and String.trim(secret) != "" do
      settings = settings || %{}

      client_opts =
        [
          token: secret,
          auth_mode: Map.get(settings, "auth_mode"),
          site_url: Map.get(settings, "site_url"),
          account_email: Map.get(settings, "account_email"),
          cloud_id: Map.get(settings, "cloud_id")
        ] ++ Keyword.take(opts, [:request_fun, :timeout_ms])

      {:ok, Enum.reject(client_opts, fn {_key, value} -> is_nil(value) end)}
    else
      {:error, :credentials_missing}
    end
  end

  def client_opts(%IntegrationConnection{}, _opts), do: {:error, :connection_kind_mismatch}

  @spec check(IntegrationConnection.t(), keyword()) :: :ok | {:error, String.t()}
  def check(%IntegrationConnection{} = connection, opts) do
    with {:ok, client_opts} <- client_opts(connection, opts),
         :ok <- CloudClient.current_user(client_opts) do
      :ok
    else
      {:error, :credentials_missing} -> {:error, "jira_credentials_missing"}
      {:error, reason} -> {:error, error_code(reason)}
    end
  end

  @spec list(IntegrationConnection.t(), picker(), keyword()) :: {:ok, [item()]} | {:error, term()}
  def list(%IntegrationConnection{} = connection, picker, opts) do
    with {:ok, client_opts} <- client_opts(connection, opts),
         {:ok, values} <- fetch(picker, client_opts) do
      {:ok, Enum.flat_map(values, &item/1)}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, reason} -> {:error, {:dependency, error_code(reason)}}
    end
  end

  @spec error_code(term()) :: String.t()
  def error_code(%{kind: :http_status, status: status}) when status in [401, 403], do: "jira_auth_failed"
  def error_code(%{kind: :http_status, status: 404}), do: "jira_source_not_found"
  def error_code(%{kind: :http_status, status: 429}), do: "jira_rate_limited"
  def error_code(%{kind: :invalid_configuration}), do: "jira_invalid_configuration"
  def error_code(_reason), do: "jira_unavailable"

  defp fetch(:boards, client_opts), do: CloudClient.list_boards(client_opts)
  defp fetch(:filters, client_opts), do: CloudClient.list_filters(client_opts)
  defp fetch(:priorities, client_opts), do: CloudClient.list_priorities(client_opts)

  defp item(%{"id" => id, "name" => name}) when (is_binary(id) or is_integer(id)) and is_binary(name),
    do: [%{id: to_string(id), name: name}]

  defp item(_value), do: []
end
