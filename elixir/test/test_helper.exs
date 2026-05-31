ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)

Ecto.Adapters.SQL.Sandbox.mode(SymphonyElixir.Repo, :manual)
