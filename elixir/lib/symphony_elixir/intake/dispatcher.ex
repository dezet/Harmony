defmodule SymphonyElixir.Intake.Dispatcher do
  @moduledoc """
  Claims one outbox effect, performs its adapter call after the claim transaction
  commits, then persists the result through the delivery's lease token.
  """

  alias SymphonyElixir.Intake.Outbox
  alias SymphonyElixir.Storage.IntegrationDelivery

  @type adapter :: (IntegrationDelivery.t() -> term()) | module()
  @type dispatch_result ::
          :empty
          | {:ok, IntegrationDelivery.t()}
          | {:retry_wait, IntegrationDelivery.t()}
          | {:failed, IntegrationDelivery.t()}
          | {:unknown, IntegrationDelivery.t()}
          | {:error, term()}

  @spec dispatch_one(adapter(), keyword()) :: dispatch_result()
  def dispatch_one(adapter, opts \\ []) do
    case Outbox.claim(opts) do
      :empty ->
        :empty

      {:error, reason} ->
        {:error, reason}

      {:ok, %IntegrationDelivery{} = delivery} ->
        deliver(adapter, delivery, opts)
    end
  end

  defp deliver(adapter, delivery, opts) do
    case call_adapter(adapter, delivery) do
      {:ok, attrs} when is_map(attrs) ->
        Outbox.complete(delivery.id, delivery.lease_token, attrs, opts)

      {:retry, error_code, retry_after} ->
        with {:ok, updated} <- Outbox.retry(delivery.id, delivery.lease_token, error_code, retry_after, opts) do
          if updated.status == "retry_wait" do
            {:retry_wait, updated}
          else
            {:failed, updated}
          end
        end

      {:error, error_code} ->
        with {:ok, updated} <- Outbox.fail(delivery.id, delivery.lease_token, error_code, opts) do
          {:failed, updated}
        end

      {:unknown, error_code} ->
        with {:ok, updated} <- Outbox.mark_unknown(delivery.id, delivery.lease_token, error_code, opts) do
          {:unknown, updated}
        end

      result ->
        {:error, {:invalid_adapter_result, result}}
    end
  end

  defp call_adapter(adapter, delivery) when is_function(adapter, 1), do: adapter.(delivery)
  defp call_adapter(adapter, delivery) when is_atom(adapter), do: adapter.perform(delivery)
end
