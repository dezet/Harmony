defmodule SymphonyElixir.EvidenceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Evidence.Policy

  test "requires browser evidence for frontend paths" do
    changed = ["assets/js/app.js", "lib/my_app_web/live/page_live.ex"]

    assert Policy.requires_browser_evidence?(changed,
             frontend_paths: ["assets/", "lib/my_app_web/"]
           )
  end

  test "does not require browser evidence for backend-only paths" do
    changed = ["lib/my_app/accounts.ex", "test/my_app/accounts_test.exs"]

    refute Policy.requires_browser_evidence?(changed,
             frontend_paths: ["assets/", "lib/my_app_web/"]
           )
  end
end
