defmodule SymphonyElixirWeb.IntegrationController do
  @moduledoc """
  Jira Cloud, SMTP and SMSAPI connections: list, create, versioned edit,
  read-only connection test, confirmed test-send and Jira pickers.

  Secrets are write-only: responses expose `secret_state` only. A test never
  sends a message; test-send queues one case-less outbox delivery per
  `Idempotency-Key` and is refused while intake or its effects are disabled.
  There is no generic proxy to a provider.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Intake.{ConnectionCheck, Connections, JiraAccess, Outbox}
  alias SymphonyElixir.Notifications.Smsapi
  alias SymphonyElixirWeb.{Endpoint, IntakeParams, IntakePresenter}

  @create_fields ~w(kind name settings secret enabled)
  @update_fields ~w(name settings secret clear_secret enabled)
  @address_pattern ~r/\A[A-Za-z0-9._%+'-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+\z/
  @max_query_length 200

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, params) do
    with {:ok, page} <- IntakePresenter.page_params(params, "integrations"),
         {:ok, position} <- IntakePresenter.keyset_after(page.after) do
      connections = Connections.list_page(limit: page.page_size + 1, after: position)
      json(conn, IntakePresenter.page(connections, page.page_size, "integrations", &IntakePresenter.connection/1))
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, _params) do
    body = conn.body_params

    with :ok <- IntakeParams.permit(body, @create_fields),
         :ok <- validate_secret_types(body),
         {:ok, connection} <- Connections.create_input(body) do
      conn |> put_status(:created) |> json(%{connection: IntakePresenter.connection(connection)})
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"id" => id}) do
    case Connections.fetch(id) do
      {:ok, connection} -> json(conn, %{connection: IntakePresenter.connection(connection)})
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec update(Conn.t(), map()) :: Conn.t()
  def update(conn, %{"id" => id}) do
    body = conn.body_params

    with {:ok, version} <- IntakeParams.positive_integer(body, "version"),
         attrs = Map.delete(body, "version"),
         :ok <- reject_kind_change(attrs),
         :ok <- IntakeParams.permit(attrs, @update_fields),
         :ok <- validate_secret_types(attrs),
         {:ok, connection_id} <- IntakeParams.uuid(id),
         {:ok, connection} <- Connections.update_input(connection_id, version, attrs) do
      json(conn, %{connection: IntakePresenter.connection(connection)})
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec test(Conn.t(), map()) :: Conn.t()
  def test(conn, %{"id" => id}) do
    with :ok <- IntakeParams.permit(conn.body_params, []),
         {:ok, connection} <- Connections.fetch(id) do
      json(conn, ConnectionCheck.run(connection, Endpoint.config(:intake_adapters) || []))
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec test_send(Conn.t(), map()) :: Conn.t()
  def test_send(conn, %{"id" => id}) do
    body = conn.body_params

    with {:ok, connection} <- Connections.fetch(id),
         :ok <- test_send_kind(connection.kind),
         {:ok, idempotency_key} <- idempotency_key(conn),
         :ok <- IntakeParams.permit(body, ~w(recipient confirmed)),
         :ok <- IntakeParams.confirmed(body),
         {:ok, recipient} <- recipient(connection.kind, body["recipient"]),
         :ok <- IntakeParams.intake_running(),
         :ok <- if(connection.enabled, do: :ok, else: {:error, :connection_disabled}),
         {:ok, delivery} <- Outbox.enqueue_test_send(connection, recipient, idempotency_key) do
      conn |> put_status(:accepted) |> json(%{test_delivery: IntakePresenter.delivery(delivery)})
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec jira_boards(Conn.t(), map()) :: Conn.t()
  def jira_boards(conn, params), do: picker(conn, params, :boards)

  @spec jira_filters(Conn.t(), map()) :: Conn.t()
  def jira_filters(conn, params), do: picker(conn, params, :filters)

  @spec jira_priorities(Conn.t(), map()) :: Conn.t()
  def jira_priorities(conn, %{"id" => id}) do
    with {:ok, connection} <- Connections.fetch(id),
         {:ok, items} <- JiraAccess.list(connection, :priorities, IntakeParams.jira_opts()) do
      # Jira returns priorities in rank order; the full list is small and never cut.
      json(conn, %{items: items, meta: %{next_cursor: nil}})
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params), do: IntakePresenter.render_error(conn, :method_not_allowed)

  defp picker(conn, %{"id" => id} = params, kind) do
    with {:ok, query} <- search_query(params["q"]),
         scope = "jira:#{kind}:#{id}:#{query}",
         {:ok, page} <- IntakePresenter.page_params(params, scope),
         {:ok, offset} <- IntakePresenter.offset_after(page.after),
         {:ok, connection} <- Connections.fetch(id),
         {:ok, items} <- JiraAccess.list(connection, kind, IntakeParams.jira_opts()) do
      json(conn, items |> filter_items(query) |> IntakePresenter.offset_page(offset, page.page_size, scope))
    else
      {:error, reason} -> IntakePresenter.render_error(conn, reason)
    end
  end

  defp search_query(nil), do: {:ok, ""}

  defp search_query(query) when is_binary(query) and byte_size(query) <= @max_query_length,
    do: {:ok, query |> String.trim() |> String.downcase()}

  defp search_query(_query), do: {:error, :invalid_query}

  defp filter_items(items, ""), do: items
  defp filter_items(items, query), do: Enum.filter(items, &(&1.name |> String.downcase() |> String.contains?(query)))

  defp reject_kind_change(attrs) do
    if Map.has_key?(attrs, "kind"),
      do: {:error, {:validation, %{"kind" => ["cannot change after creation"]}}},
      else: :ok
  end

  defp validate_secret_types(attrs) do
    errors =
      [
        not (is_nil(attrs["secret"]) or is_binary(attrs["secret"])) && {"secret", ["must be a string"]},
        not is_boolean(Map.get(attrs, "clear_secret", false)) && {"clear_secret", ["must be a boolean"]},
        not is_boolean(Map.get(attrs, "enabled", false)) && {"enabled", ["must be a boolean"]},
        not (is_nil(attrs["settings"]) or is_map(attrs["settings"])) && {"settings", ["must be an object"]}
      ]
      |> Enum.filter(&is_tuple/1)

    if errors == [], do: :ok, else: {:error, {:validation, Map.new(errors)}}
  end

  defp test_send_kind(kind) when kind in ["smtp", "smsapi"], do: :ok
  defp test_send_kind(_kind), do: {:error, :test_send_unsupported}

  defp idempotency_key(conn) do
    with [key] <- get_req_header(conn, "idempotency-key"),
         {:ok, uuid} <- Ecto.UUID.cast(String.trim(key)) do
      {:ok, uuid}
    else
      _invalid -> {:error, :invalid_idempotency_key}
    end
  end

  defp recipient("smsapi", recipient) do
    case Smsapi.normalize_phone(recipient) do
      {:ok, e164} -> {:ok, e164}
      {:error, _code} -> {:error, {:validation, %{"recipient" => ["must be an E.164 phone number"]}}}
    end
  end

  defp recipient("smtp", recipient) when is_binary(recipient) do
    with [local, domain] <- recipient |> String.trim() |> String.split("@", parts: 2),
         address = local <> "@" <> String.downcase(domain),
         true <- Regex.match?(@address_pattern, address) do
      {:ok, address}
    else
      _invalid -> {:error, {:validation, %{"recipient" => ["must be an e-mail address"]}}}
    end
  end

  defp recipient(_kind, _recipient), do: {:error, {:validation, %{"recipient" => ["is required"]}}}
end
