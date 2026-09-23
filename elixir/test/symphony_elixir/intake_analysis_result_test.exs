defmodule SymphonyElixir.IntakeAnalysisResultTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Intake.AnalysisResult

  test "accepts only the exact bounded result contract for the prepared context" do
    result = valid_result("issue_and_repository", "src/worker.ex:12")
    snapshot = snapshot!()

    assert {:ok, decoded} =
             AnalysisResult.validate(Jason.encode!(result), context("issue_and_repository", snapshot))

    assert decoded["facts"] == [%{"text" => "Observed behavior", "source" => "src/worker.ex:12"}]
  end

  test "rejects malformed, oversized, HTML, extra-field, and over-limit JSON" do
    context = context("issue_only", System.tmp_dir!())
    valid = valid_result("issue_only", "jira:OPS-42")

    assert {:error, :html_result} = AnalysisResult.validate("<html>not JSON</html>", context)
    assert {:error, :result_too_large} = AnalysisResult.validate(String.duplicate(" ", 32_769), context)

    assert {:error, :invalid_result} =
             AnalysisResult.validate(Jason.encode!(Map.put(valid, :extra, "no")), context)

    assert {:error, :invalid_result} =
             AnalysisResult.validate(Jason.encode!(Map.put(valid, :summary, String.duplicate("a", 2_001))), context)

    assert {:error, :html_result} =
             AnalysisResult.validate(Jason.encode!(Map.put(valid, :summary, "<div>unsafe</div>")), context)

    assert {:error, :html_result} =
             AnalysisResult.validate(Jason.encode!(Map.put(valid, :summary, "<iframe src='x'>unsafe</iframe>")), context)
  end

  test "rejects false, missing, or mismatched sources and context scopes" do
    snapshot = snapshot!()
    base_context = context("issue_and_repository", snapshot)
    valid = valid_result("issue_and_repository", "src/worker.ex")

    assert {:error, :invalid_source} =
             AnalysisResult.validate(
               Jason.encode!(put_in(valid, [:facts, Access.at(0), :source], "../outside.ex")),
               base_context
             )

    assert {:error, :invalid_source} =
             AnalysisResult.validate(
               Jason.encode!(put_in(valid, [:facts, Access.at(0), :source], "missing.ex")),
               base_context
             )

    assert {:error, :invalid_result} =
             AnalysisResult.validate(
               Jason.encode!(Map.put(valid, :context_scope, "issue_only")),
               base_context
             )

    issue_only_context = context("issue_only", snapshot)

    assert {:error, :invalid_source} =
             AnalysisResult.validate(Jason.encode!(valid), issue_only_context)

    assert {:error, :invalid_source} =
             AnalysisResult.validate(
               Jason.encode!(put_in(valid, [:facts, Access.at(0), :source], "jira:OPS-99")),
               base_context
             )
  end

  defp valid_result(context_scope, source) do
    %{
      summary: "A concise finding",
      facts: [%{text: "Observed behavior", source: source}],
      hypotheses: [%{text: "A possible cause", confidence: "medium", evidence: ["jira:OPS-42"]}],
      missing_data: ["A request timestamp"],
      next_steps: ["Collect a request trace"],
      needs_input: true,
      context_scope: context_scope
    }
  end

  defp context(scope, snapshot_path) do
    %{jira_key: "OPS-42", context_scope: scope, snapshot_path: snapshot_path}
  end

  defp snapshot! do
    root = snapshot_root()
    File.mkdir_p!(Path.join(root, "src"))
    File.write!(Path.join(root, "src/worker.ex"), "defmodule Worker do end\n")
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp snapshot_root do
    Path.join(
      System.tmp_dir!(),
      "analysis-result-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"
    )
  end
end
