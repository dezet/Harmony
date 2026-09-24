# G-SMTP starts a Mailpit container; run it only with `--include smtp_integration`.
ExUnit.start(exclude: [:smtp_integration])
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
Code.require_file("support/cases_fixtures.exs", __DIR__)

Ecto.Adapters.SQL.Sandbox.mode(SymphonyElixir.Repo, :manual)
