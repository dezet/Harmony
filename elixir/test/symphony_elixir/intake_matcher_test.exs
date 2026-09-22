defmodule SymphonyElixir.IntakeMatcherTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Intake.Matcher
  alias SymphonyElixir.Jira.Issue
  alias SymphonyElixir.Storage.AutomationRule

  test "only configured priorities outside Done match the rule" do
    rule = %AutomationRule{priority_ids: ["1", "2"]}

    assert Matcher.matches?(rule, %Issue{priority_id: "1", status_category: "new"})
    refute Matcher.matches?(rule, %Issue{priority_id: "3", status_category: "new"})
    refute Matcher.matches?(rule, %Issue{priority_id: "1", status_category: "done"})
    refute Matcher.matches?(rule, %Issue{priority_id: "1", status_category: nil})
  end
end
