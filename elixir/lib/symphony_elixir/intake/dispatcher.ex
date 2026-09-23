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
  def dispatch_one(adapter, opts) do
    case Outbox.claim(opts) do
      :empty ->
        :empty

      {:error, reason} ->
        {:error, reason}

      {:ok, %IntegrationDelivery{} = delivery} ->
        deliver(adapter, delivery, opts)
    end
  end

  @spec dispatch_one(adapter()) :: dispatch_result()
  def dispatch_one(adapter) when is_function(adapter, 1) or is_atom(adapter), do: dispatch_one(adapter, [])

  @spec dispatch_one(keyword()) :: dispatch_result()
  def dispatch_one(opts) when is_list(opts) do
    dispatch_one(fn delivery -> default_adapter(delivery, opts) end, opts)
  end

  defp deliver(adapter, delivery, opts) do
    case call_adapter(adapter, delivery) do
      {:ok, attrs} when is_map(attrs) ->
        Outbox.complete(delivery.id, delivery.lease_token, attrs, opts)

      {:retry, error_code, retry_after} ->
        persist_retry(delivery, error_code, retry_after, opts)

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

  defp persist_retry(delivery, error_code, retry_after, opts) do
    with {:ok, updated} <- Outbox.retry(delivery.id, delivery.lease_token, error_code, retry_after, opts) do
      retry_result(updated)
    end
  end

  defp retry_result(%IntegrationDelivery{status: "retry_wait"} = delivery), do: {:retry_wait, delivery}
  defp retry_result(%IntegrationDelivery{} = delivery), do: {:failed, delivery}

  defp call_adapter(adapter, delivery) when is_function(adapter, 1), do: adapter.(delivery)
  defp call_adapter(adapter, delivery) when is_atom(adapter), do: adapter.perform(delivery)

  defp default_adapter(%IntegrationDelivery{operation: "linear_create"} = delivery, opts) do
    SymphonyElixir.Intake.LinearBridge.perform(delivery, Keyword.get(opts, :linear_bridge_opts, []))
  end

  defp default_adapter(%IntegrationDelivery{operation: "analysis"} = delivery, opts) do
    SymphonyElixir.Intake.AnalysisRunner.perform(delivery, Keyword.get(opts, :analysis_opts, []))
  end

  defp default_adapter(%IntegrationDelivery{operation: "jira_comment"} = delivery, opts) do
    SymphonyElixir.Intake.CommentPublisher.perform(delivery, Keyword.get(opts, :jira_comment_opts, []))
  end

  defp default_adapter(%IntegrationDelivery{} = delivery, opts) do
    case Keyword.get(opts, :io_adapter) do
      fun when is_function(fun, 1) -> fun.(delivery)
      module when is_atom(module) -> module.perform(delivery)
      _missing -> {:error, "unsupported_delivery_operation"}
    end
  end
end
