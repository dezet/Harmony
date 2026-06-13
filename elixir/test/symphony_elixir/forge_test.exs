defmodule SymphonyElixir.ForgeTest do
  # async: false — Forge.Memory is a single named Agent; concurrent tests would race its shared state.
  use ExUnit.Case, async: false
  alias SymphonyElixir.Forge

  test "adapter/1 dispatches on the project's forge_type" do
    assert Forge.adapter(%{forge_type: "github"}) == SymphonyElixir.Forge.Github
    assert Forge.adapter(%{forge_type: "gitlab"}) == SymphonyElixir.Forge.Gitlab
    assert Forge.adapter(%{forge_type: nil}) == SymphonyElixir.Forge.Github
  end

  test "Memory adapter records calls and returns seeded results" do
    Forge.Memory.reset()
    Forge.Memory.seed_repositories([%{owner: "o", name: "r", default_branch: "main", url: "u"}])
    assert {:ok, [%{name: "r"}]} = Forge.Memory.list_repositories(%{}, [])
  end

  test "Memory records write-side calls in order" do
    Forge.Memory.reset()
    ref = %{owner: "o", repo: "r", base_url: nil}
    :ok = Forge.Memory.create_comment(%{}, ref, 7, "hi")
    :ok = Forge.Memory.create_review(%{}, ref, 7, "lgtm", [])
    calls = Forge.Memory.recorded_calls()
    assert [{:create_comment, _}, {:create_review, _}] = calls
  end
end
