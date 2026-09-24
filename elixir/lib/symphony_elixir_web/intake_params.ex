defmodule SymphonyElixirWeb.IntakeParams do
  @moduledoc """
  Input checks shared by the intake API controllers: field whitelists,
  versions, explicit confirmations, runtime switches and injected adapters.
  Every failure is an error reason understood by `IntakePresenter.error/1`.
  """

  alias SymphonyElixir.Intake
  alias SymphonyElixirWeb.Endpoint

  @doc "Rejects any body field outside the whitelist instead of ignoring it."
  @spec permit(map(), [String.t()]) :: :ok | {:error, {:validation, map()}}
  def permit(body, allowed) when is_map(body) do
    case body |> Map.keys() |> Enum.reject(&(&1 in allowed)) do
      [] -> :ok
      unknown -> {:error, {:validation, Map.new(unknown, &{&1, ["is not permitted"]})}}
    end
  end

  @spec positive_integer(map(), String.t()) :: {:ok, pos_integer()} | {:error, {:validation, map()}}
  def positive_integer(body, field) do
    case Map.get(body, field) do
      value when is_integer(value) and value >= 1 -> {:ok, value}
      _invalid -> {:error, {:validation, %{field => ["must be an integer greater than or equal to 1"]}}}
    end
  end

  @doc "Only the JSON boolean `true` counts as a confirmation."
  @spec confirmed(map(), String.t()) :: :ok | {:error, :confirmation_required}
  def confirmed(body, field \\ "confirmed") do
    if Map.get(body, field) === true, do: :ok, else: {:error, :confirmation_required}
  end

  @spec optional_boolean(map(), String.t()) :: {:ok, boolean()} | {:error, {:validation, map()}}
  def optional_boolean(body, field) do
    case Map.get(body, field, false) do
      value when is_boolean(value) -> {:ok, value}
      _invalid -> {:error, {:validation, %{field => ["must be a boolean"]}}}
    end
  end

  @spec uuid(term()) :: {:ok, binary()} | {:error, :not_found}
  def uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  @spec optional_uuid(term(), String.t()) :: {:ok, binary() | nil} | {:error, {:validation, map()}}
  def optional_uuid(nil, _field), do: {:ok, nil}

  def optional_uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:validation, %{field => ["must be a UUID"]}}}
    end
  end

  @doc "Manual external mutations are refused while `intake.effects_enabled` is false (spec §13)."
  @spec effects_enabled() :: :ok | {:error, :effects_disabled}
  def effects_enabled do
    if Intake.effects_enabled?(), do: :ok, else: {:error, :effects_disabled}
  end

  @doc """
  A test message must not wait in the outbox for intake to be switched on
  later, so test-send also requires `intake.enabled`.
  """
  @spec intake_running() :: :ok | {:error, :intake_disabled | :effects_disabled}
  def intake_running do
    cond do
      not Intake.enabled?() -> {:error, :intake_disabled}
      not Intake.effects_enabled?() -> {:error, :effects_disabled}
      true -> :ok
    end
  end

  @doc "Adapters injected through the endpoint configuration (tests use stubs)."
  @spec adapter(atom(), term()) :: term()
  def adapter(key, default \\ nil) do
    Keyword.get(Endpoint.config(:intake_adapters) || [], key, default)
  end

  @spec jira_opts() :: keyword()
  def jira_opts do
    case adapter(:jira_request_fun) do
      nil -> []
      request_fun -> [request_fun: request_fun]
    end
  end
end
