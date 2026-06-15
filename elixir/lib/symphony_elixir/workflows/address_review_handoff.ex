defmodule SymphonyElixir.Workflows.AddressReviewHandoff do
  @moduledoc """
  Consumes an `address_review` run's structured output and applies it to the
  forge: reply to each thread, resolve the ones the agent marked resolved.
  """

  alias SymphonyElixir.{Storage, WorkRun}
  alias SymphonyElixir.Forge.ProjectCreds

  @spec publish(WorkRun.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def publish(%WorkRun{} = run, body, opts \\ []) when is_binary(body) do
    creds = ProjectCreds.creds(run, opts)
    ref = %{owner: run.forge_owner, repo: run.forge_repo, base_url: creds.base_url}

    reply =
      Keyword.get(opts, :reply, fn r, change_id, thread_id, text ->
        SymphonyElixir.Forge.adapter(run).reply_to_review_thread(creds, r, change_id, thread_id, text)
      end)

    resolve =
      Keyword.get(opts, :resolve, fn r, change_id, thread_id ->
        SymphonyElixir.Forge.adapter(run).resolve_review_thread(creds, r, change_id, thread_id)
      end)

    with {:ok, decisions, files_changed} <- parse_decisions(body),
         paths = thread_paths(run),
         :ok <-
           apply_decisions(decisions, paths, files_changed, ref, run.forge_pr_number, reply, resolve) do
      _ = append_work_event(run, opts)
      _ = mark_processed(run, opts)
      :ok
    end
  end

  defp apply_decisions(decisions, paths, files_changed, ref, change_id, reply, resolve) do
    Enum.reduce_while(decisions, :ok, fn d, :ok ->
      with :ok <- reply.(ref, change_id, d.thread_id, d.reply),
           :ok <- maybe_resolve(d, paths, files_changed, ref, change_id, resolve) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_resolve(%{resolved: true, thread_id: id}, paths, files_changed, ref, change_id, resolve) do
    path = Map.get(paths, id)

    if path && path in files_changed,
      do: resolve.(ref, change_id, id),
      else: :ok
  end

  defp maybe_resolve(_decision, _paths, _files_changed, _ref, _change_id, _resolve), do: :ok

  # Map each run thread's id → anchored path (entries may have string or atom keys).
  defp thread_paths(%WorkRun{payload: payload}) do
    case pv(payload, "threads") do
      threads when is_list(threads) ->
        Map.new(threads, fn t -> {pv(t, :id), pv(t, :path)} end)

      _ ->
        %{}
    end
  end

  # Parse the last JSON object in the body matching {"threads":[...]}.
  defp parse_decisions(body) do
    with [_ | _] = matches <- Regex.scan(~r/\{.*"threads".*\}/s, body),
         json <- matches |> List.last() |> List.first(),
         {:ok, %{"threads" => threads} = decoded} when is_list(threads) <- Jason.decode(json) do
      files = Map.get(decoded, "files_changed", [])
      {:ok, Enum.map(threads, &normalize_decision/1), (is_list(files) && files) || []}
    else
      _ -> {:error, :no_structured_output}
    end
  end

  defp normalize_decision(t) do
    %{thread_id: t["thread_id"], reply: t["reply"] || "", resolved: t["resolved"] == true}
  end

  defp append_work_event(%WorkRun{id: id, payload: payload} = run, opts) when is_binary(id) do
    append = Keyword.get(opts, :append_event, &Storage.append_event/1)

    case pv(payload, "project_id") do
      pid when is_binary(pid) ->
        append.(%{
          project_id: pid,
          work_run_id: run.id,
          type: "review_response_applied",
          payload: %{"forge_pr_number" => run.forge_pr_number}
        })

      _ ->
        :ok
    end
  end

  defp append_work_event(_run, _opts), do: :ok

  defp mark_processed(%WorkRun{dedupe_key: key, payload: payload} = run, opts) when is_binary(key) do
    mark = Keyword.get(opts, :mark_dedupe_processed, &Storage.mark_dedupe_processed/1)

    case pv(payload, "project_id") do
      pid when is_binary(pid) ->
        mark.(%{
          project_id: pid,
          key: key,
          scope: "review_response",
          status: "processed",
          metadata: %{"forge_pr_number" => run.forge_pr_number}
        })

      _ ->
        :ok
    end
  end

  defp mark_processed(_run, _opts), do: :ok

  defp pv(%{} = m, k), do: Map.get(m, k) || Map.get(m, to_string(k))
  defp pv(_m, _k), do: nil
end
