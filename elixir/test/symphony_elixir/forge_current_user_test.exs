defmodule SymphonyElixir.ForgeCurrentUserTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Forge.{Memory, Github, Gitlab}

  setup do
    Memory.reset()
    :ok
  end

  test "memory current_user returns the seeded login" do
    Memory.seed_current_user("harmony[bot]")
    assert {:ok, "harmony[bot]"} = Memory.current_user(%{})
  end

  test "github current_user reads .login from GET /user" do
    request_fun = fn _req -> {:ok, %Req.Response{status: 200, body: %{"login" => "harmony[bot]"}}} end
    assert {:ok, "harmony[bot]"} = Github.current_user(%{token: "t", base_url: nil, request_fun: request_fun})
  end

  test "gitlab current_user reads .username from GET /user" do
    request_fun = fn _req -> {:ok, %Req.Response{status: 200, body: %{"username" => "harmony-bot"}}} end
    assert {:ok, "harmony-bot"} = Gitlab.current_user(%{token: "t", base_url: nil, request_fun: request_fun})
  end
end
