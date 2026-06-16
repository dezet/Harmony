defmodule SymphonyElixir.ReviewIdentityTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Review.Identity

  setup do
    Identity.reset_cache()
    :ok
  end

  test "config bot_identity wins without any whoami call" do
    project = %{forge_type: "github", config: %{"review" => %{"bot_identity" => "cfg-bot"}}}
    whoami = fn _ -> raise "should not be called" end
    assert "cfg-bot" = Identity.resolve(project, %{token: "t"}, current_user: whoami)
  end

  test "falls back to whoami when no config, and caches by token" do
    project = %{forge_type: "github", config: %{}}
    pid = self()
    whoami = fn _ -> send(pid, :called); {:ok, "api-bot"} end

    assert "api-bot" = Identity.resolve(project, %{token: "tok"}, current_user: whoami)
    assert "api-bot" = Identity.resolve(project, %{token: "tok"}, current_user: whoami)
    assert_received :called
    refute_received :called  # second call served from cache
  end

  test "whoami error falls back to default harmony" do
    project = %{forge_type: "github", config: %{}}
    whoami = fn _ -> {:error, :boom} end
    assert "harmony" = Identity.resolve(project, %{token: "t2"}, current_user: whoami)
  end
end
