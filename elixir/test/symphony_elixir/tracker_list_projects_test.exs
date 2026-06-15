defmodule SymphonyElixir.TrackerListProjectsTest do
  use SymphonyElixir.TestSupport

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    prev = Application.get_env(:symphony_elixir, :memory_tracker_projects)
    on_exit(fn -> Application.put_env(:symphony_elixir, :memory_tracker_projects, prev) end)
    :ok
  end

  test "list_projects/1 returns the memory adapter's seeded projects" do
    Application.put_env(:symphony_elixir, :memory_tracker_projects, [
      %{id: "p1", name: "Portal", slug: "portal", team_key: "COD"}
    ])

    assert {:ok, [%{id: "p1", name: "Portal", slug: "portal", team_key: "COD"}]} =
             Tracker.list_projects(%{token: "ignored-by-memory"})
  end
end
