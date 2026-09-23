defmodule SymphonyElixir.Intake.AnalysisResult do
  @moduledoc "Validates the bounded JSON contract returned by the read-only analysis model."

  alias SymphonyElixir.PathSafety

  @max_bytes 32_768
  @result_keys ~w(summary facts hypotheses missing_data next_steps needs_input context_scope)
  @fact_keys ~w(text source)
  @hypothesis_keys ~w(text confidence evidence)
  @confidence_values ~w(low medium high)
  @context_scopes ~w(issue_only issue_and_repository)

  @type validation_context :: %{
          required(:jira_key) => String.t(),
          required(:context_scope) => String.t(),
          required(:snapshot_path) => Path.t()
        }

  @spec validate(binary(), validation_context()) :: {:ok, map()} | {:error, atom()}
  def validate(raw, context) when is_binary(raw) and is_map(context) do
    cond do
      byte_size(raw) > @max_bytes -> {:error, :result_too_large}
      contains_html?(raw) -> {:error, :html_result}
      true -> decode_and_validate(raw, context)
    end
  end

  def validate(_raw, _context), do: {:error, :invalid_result}

  defp decode_and_validate(raw, context) do
    with {:ok, result} <- Jason.decode(raw),
         :ok <- validate_result(result, context) do
      {:ok, result}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :invalid_result}
    end
  end

  defp validate_result(result, context) when is_map(result) do
    with :ok <- exact_keys(result, @result_keys),
         :ok <- valid_text(result["summary"], 2_000),
         :ok <- valid_facts(result["facts"], context),
         :ok <- valid_hypotheses(result["hypotheses"]),
         :ok <- valid_text_list(result["missing_data"], 20),
         :ok <- valid_text_list(result["next_steps"], 20),
         true <- is_boolean(result["needs_input"]),
         true <- result["context_scope"] in @context_scopes,
         true <- result["context_scope"] == Map.get(context, :context_scope) do
      :ok
    else
      false -> {:error, :invalid_result}
      {:error, _reason} = error -> error
    end
  end

  defp validate_result(_result, _context), do: {:error, :invalid_result}

  defp valid_facts(facts, context) when is_list(facts) and length(facts) <= 20 do
    Enum.reduce_while(facts, :ok, fn fact, :ok ->
      case valid_fact(fact, context) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp valid_facts(_facts, _context), do: {:error, :invalid_result}

  defp valid_fact(fact, context) when is_map(fact) do
    with :ok <- exact_keys(fact, @fact_keys),
         :ok <- valid_text(fact["text"], 1_000),
         :ok <- valid_text(fact["source"], 1_000),
         true <- valid_source?(fact["source"], context) do
      :ok
    else
      false -> {:error, :invalid_source}
      {:error, _reason} = error -> error
    end
  end

  defp valid_fact(_fact, _context), do: {:error, :invalid_result}

  defp valid_hypotheses(hypotheses) when is_list(hypotheses) and length(hypotheses) <= 20 do
    Enum.reduce_while(hypotheses, :ok, fn hypothesis, :ok ->
      case valid_hypothesis(hypothesis) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp valid_hypotheses(_hypotheses), do: {:error, :invalid_result}

  defp valid_hypothesis(hypothesis) when is_map(hypothesis) do
    with :ok <- exact_keys(hypothesis, @hypothesis_keys),
         :ok <- valid_text(hypothesis["text"], 1_000),
         true <- hypothesis["confidence"] in @confidence_values,
         :ok <- valid_text_list(hypothesis["evidence"], 20) do
      :ok
    else
      false -> {:error, :invalid_result}
      {:error, _reason} = error -> error
    end
  end

  defp valid_hypothesis(_hypothesis), do: {:error, :invalid_result}

  defp valid_text_list(values, max_items) when is_list(values) and length(values) <= max_items do
    if Enum.all?(values, &(valid_text(&1, 1_000) == :ok)), do: :ok, else: {:error, :invalid_result}
  end

  defp valid_text_list(_values, _max_items), do: {:error, :invalid_result}

  defp valid_text(text, max_length) when is_binary(text) do
    if String.valid?(text) and String.length(text) <= max_length and not contains_html?(text),
      do: :ok,
      else: {:error, :invalid_result}
  end

  defp valid_text(_text, _max_length), do: {:error, :invalid_result}

  defp exact_keys(map, keys) do
    if map |> Map.keys() |> Enum.sort() == Enum.sort(keys), do: :ok, else: {:error, :invalid_result}
  end

  defp valid_source?("jira:" <> jira_key, %{jira_key: expected_jira_key}) do
    jira_key == expected_jira_key and Regex.match?(~r/\A[A-Z][A-Z0-9_]*-\d+\z/, jira_key)
  end

  defp valid_source?(source, %{context_scope: "issue_and_repository", snapshot_path: root}) do
    with {:ok, path, line} <- split_source_line(source),
         true <- safe_relative_path?(path),
         true <- valid_line?(line),
         full_path = Path.join(root, path),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(full_path),
         {:ok, canonical_root} <- PathSafety.canonicalize(root),
         {:ok, canonical_file} <- PathSafety.canonicalize(full_path),
         true <- canonical_file == full_path and within_root?(canonical_file, canonical_root) do
      true
    else
      _other -> false
    end
  end

  defp valid_source?(_source, _context), do: false

  defp split_source_line(source) do
    case Regex.run(~r/\A(.+):(\d+)\z/, source) do
      [_, path, line] -> {:ok, path, line}
      nil -> {:ok, source, nil}
    end
  end

  defp safe_relative_path?(path) when is_binary(path) do
    path != "" and not String.starts_with?(path, "/") and not String.contains?(path, ["\\", <<0>>]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp safe_relative_path?(_path), do: false

  defp valid_line?(nil), do: true

  defp valid_line?(line) when is_binary(line) do
    case Integer.parse(line) do
      {number, ""} -> number > 0
      _other -> false
    end
  end

  defp within_root?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp contains_html?(text) do
    Regex.match?(~r{<(?:/?[a-z][a-z0-9:-]*\b|!--|!doctype\b)}i, text)
  end
end
