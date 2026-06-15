defmodule SymphonyElixir.Workflows.AddressReviewHandoff do
  @moduledoc """
  Consumes an `address_review` run's structured output and applies it to the
  forge: reply to each thread, resolve the ones the agent marked resolved.
  """

  alias SymphonyElixir.{Storage, WorkRun}
  alias SymphonyElixir.Forge.ProjectCreds

  @max_attempts 3

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
         threads = thread_index(run),
         :ok <-
           apply_decisions(decisions, threads, files_changed, ref, run.forge_pr_number, reply, resolve) do
      _ = append_work_event(run, opts)
      _ = finalize_threads(decisions, threads, files_changed, run, ref, reply, opts)
      :ok
    end
  end

  defp apply_decisions(decisions, threads, files_changed, ref, change_id, reply, resolve) do
    Enum.reduce_while(decisions, :ok, fn d, :ok ->
      with :ok <- reply.(ref, change_id, d.thread_id, d.reply),
           :ok <- maybe_resolve(d, threads, files_changed, ref, change_id, resolve) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_resolve(%{resolved: true} = d, threads, files_changed, ref, change_id, resolve) do
    if addressed?(d, threads, files_changed),
      do: resolve.(ref, change_id, d.thread_id),
      else: :ok
  end

  defp maybe_resolve(_decision, _threads, _files_changed, _ref, _change_id, _resolve), do: :ok

  # Per-thread finalization (retry cap of #{@max_attempts}):
  #   addressed (resolved ∧ file changed) → mark that thread's key processed
  #   unaddressed → increment that thread's key attempt count; on the Nth attempt
  #     post a "needs human review" note and mark the key processed (terminal)
  defp finalize_threads(decisions, threads, files_changed, run, ref, reply, opts) do
    project_id = pv(run.payload, "project_id")

    Enum.each(decisions, fn d ->
      finalize_thread(d, threads, files_changed, run, ref, reply, opts, project_id)
    end)
  end

  defp finalize_thread(d, threads, files_changed, run, ref, reply, opts, project_id)
       when is_binary(project_id) do
    key = thread_key(d.thread_id, threads, run)

    if addressed?(d, threads, files_changed) do
      mark_processed(project_id, key, run, opts)
    else
      {:ok, n} = increment_attempt(project_id, key, opts)

      if n >= @max_attempts do
        _ =
          reply.(
            ref,
            run.forge_pr_number,
            d.thread_id,
            "Harmony could not resolve this after #{@max_attempts} attempts — needs human review."
          )

        mark_processed(project_id, key, run, opts)
      else
        :ok
      end
    end
  end

  defp finalize_thread(_d, _threads, _files_changed, _run, _ref, _reply, _opts, _project_id), do: :ok

  # A thread is addressed when the agent marked it resolved AND actually edited the
  # file it is anchored to (path from the run payload, resolved from the decision).
  defp addressed?(%{resolved: true, thread_id: id}, threads, files_changed) do
    path = Map.get(threads, id, %{})[:path]
    is_binary(path) and path in files_changed
  end

  defp addressed?(_decision, _threads, _files_changed), do: false

  # Resolve the per-thread dedupe key: prefer the per-thread key carried in the
  # payload entry, falling back to the run-level dedupe_key (single-thread runs).
  defp thread_key(thread_id, threads, %WorkRun{dedupe_key: run_key}) do
    case Map.get(threads, thread_id) do
      %{dedupe_key: key} when is_binary(key) -> key
      _ -> run_key
    end
  end

  defp increment_attempt(project_id, key, opts) do
    inc = Keyword.get(opts, :increment_review_attempt, &Storage.increment_review_attempt/2)
    inc.(project_id, key)
  end

  # Index each run thread by id → anchored path + per-thread dedupe key.
  defp thread_index(%WorkRun{payload: payload}) do
    case pv(payload, "threads") do
      threads when is_list(threads) ->
        Map.new(threads, fn t -> {pv(t, :id), %{path: pv(t, :path), dedupe_key: pv(t, :dedupe_key)}} end)

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

  defp mark_processed(project_id, key, %WorkRun{} = run, opts)
       when is_binary(project_id) and is_binary(key) do
    mark = Keyword.get(opts, :mark_dedupe_processed, &Storage.mark_dedupe_processed/1)

    mark.(%{
      project_id: project_id,
      key: key,
      scope: "review_response",
      status: "processed",
      metadata: %{"forge_pr_number" => run.forge_pr_number}
    })
  end

  defp mark_processed(_project_id, _key, _run, _opts), do: :ok

  defp pv(%{} = m, k), do: Map.get(m, k) || Map.get(m, to_string(k))
  defp pv(_m, _k), do: nil
end
