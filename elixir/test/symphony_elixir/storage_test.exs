defmodule SymphonyElixir.StorageTest do
  use SymphonyElixir.TestSupport

  test "repo module is configured for ecto" do
    assert SymphonyElixir.Repo.config()[:otp_app] == :symphony_elixir
  end
end
