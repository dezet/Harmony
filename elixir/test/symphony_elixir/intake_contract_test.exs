defmodule SymphonyElixir.IntakeContractTest do
  use ExUnit.Case, async: true

  @fixture_root Path.expand("../../assets/src/test/fixtures", __DIR__)

  @case_item_keys ~w(
    attention column detected_at execution_mode kind linear priority project ref
    status_label title updated_at jira
  )

  @legacy_status_cases [
    %{status: "queued", error: nil, column: "detected"},
    %{status: "retrying", error: nil, column: "detected"},
    %{status: "running", error: nil, column: "analyzing"},
    %{status: "blocked", error: "operator review", column: "decision"},
    %{status: "failed", error: "worker failed", column: "decision"},
    %{status: "retrying", error: "retry exhausted", column: "decision"},
    %{status: "stopped", error: "stopped by operator", column: "decision"},
    %{status: "human_review", error: "awaiting operator", column: "decision"},
    %{status: "completed", error: nil, column: "handed_off"},
    %{status: "succeeded", error: nil, column: "handed_off"},
    %{status: "handed_off", error: nil, column: "handed_off"},
    %{status: "cancelled", error: nil, column: "handed_off"},
    %{status: "awaiting_owner", error: nil, column: "decision"}
  ]

  test "FE and BE consume the same synthetic cases fixture" do
    page = fixture!("cases_page.fixture.json")

    assert Map.keys(page) |> Enum.sort() == ~w(counts items meta project_counts)
    assert length(page["items"]) == 9

    assert page["items"] |> Enum.take(5) |> Enum.map(&get_in(&1, ["jira", "key"])) == [
             "OPS-142",
             "OPS-139",
             "FIN-87",
             "OPS-145",
             "HR-63"
           ]

    assert Enum.all?(page["items"], fn item -> Map.keys(item) |> Enum.sort() == Enum.sort(@case_item_keys) end)

    intake_cases = Enum.take(page["items"], 5)
    assert Enum.all?(intake_cases, &(get_in(&1, ["execution_mode"]) == "analysis_only"))
    assert Enum.all?(intake_cases, &(get_in(&1, ["jira"]) != nil and get_in(&1, ["linear"]) != nil))

    assert page["counts"] == %{
             "all" => 9,
             "decision" => 4,
             "analysis" => 2,
             "done" => 2,
             "detected" => 1
           }

    assert page["meta"] == %{"next_cursor" => nil, "total" => 9, "page_size" => 25}
  end

  test "case detail exposes nullable links, actions, analysis-only result, and publication status" do
    detail = fixture!("case_detail.fixture.json")

    assert Map.keys(detail) |> Enum.sort() ==
             ~w(actions analysis case deliveries links publication version)

    assert get_in(detail, ["case", "execution_mode"]) == "analysis_only"
    assert get_in(detail, ["case", "acknowledged_at"]) == nil
    assert get_in(detail, ["case", "repair_approved_at"]) == nil
    assert get_in(detail, ["case", "jira", "url"]) =~ "https://example.atlassian.net/"
    assert get_in(detail, ["case", "linear", "url"]) =~ "https://linear.example/"
    assert get_in(detail, ["analysis", "status"]) == "succeeded"
    assert get_in(detail, ["analysis", "result", "context_scope"]) == "issue_only"
    assert get_in(detail, ["analysis", "result", "needs_input"]) == false
    assert get_in(detail, ["publication", "status"]) == "published"
    assert is_binary(get_in(detail, ["publication", "comment_id"]))

    assert Map.keys(detail["actions"]) |> Enum.sort() == ~w(acknowledge approve_repair reanalyze)

    assert Enum.all?(detail["actions"], fn {_action, value} ->
             Map.keys(value) |> Enum.sort() == ~w(allowed reason)
           end)

    assert Enum.find(detail["deliveries"], &(&1["operation"] == "jira_comment"))["status"] ==
             "succeeded"
  end

  test "automation and integration fixtures never expose credentials or live recipients" do
    rule = fixture!("automation_rule.fixture.json")
    connection = fixture!("integration_connection.fixture.json")

    assert rule["enabled"] == false
    assert rule["initial_policy"] == "new_matches_only"
    assert rule["email_recipients"] == ["oncall@example.test"]
    assert rule["sms_recipients"] == ["+19995550123"]
    assert connection["settings"]["site_url"] == "https://example.atlassian.net"
    assert connection["secret_state"] == "set"
    refute Jason.encode!(rule) =~ "token"
    refute Jason.encode!(rule) =~ "password"
    refute Map.has_key?(connection, "secret")
    refute Map.has_key?(connection["settings"], "secret")
  end

  test "legacy storage and orchestrator statuses map to visible columns" do
    assert Enum.all?(@legacy_status_cases, fn %{status: status, error: error, column: expected} ->
             legacy_column(status, error) == expected
           end)

    assert legacy_attention("awaiting_owner") == %{
             "code" => "unknown_status",
             "message" => "Nieznany status przebiegu: awaiting_owner"
           }

    page = fixture!("cases_page.fixture.json")

    assert Enum.find(page["items"], &(&1["status_label"] == "awaiting_owner"))["attention"] ==
             legacy_attention("awaiting_owner")
  end

  defp fixture!(name) do
    @fixture_root
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end

  defp legacy_column("retrying", nil), do: "detected"
  defp legacy_column("queued", nil), do: "detected"
  defp legacy_column("running", nil), do: "analyzing"
  defp legacy_column(status, nil) when status in ["completed", "succeeded", "handed_off", "cancelled"], do: "handed_off"
  defp legacy_column(_status, _error), do: "decision"

  defp legacy_attention(status) do
    %{"code" => "unknown_status", "message" => "Nieznany status przebiegu: #{status}"}
  end
end
