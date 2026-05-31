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

  test "reads evidence manifest and resolves artifact paths under workspace" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "harmony-evidence-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"
      )

    try do
      File.mkdir_p!(Path.join(workspace, ".harmony/artifacts"))
      File.write!(Path.join(workspace, ".harmony/artifacts/frontend-check.png"), "png")

      File.write!(Path.join(workspace, ".harmony/evidence.json"), ~s({
        "frontend_changed": true,
        "scenario": "Open changed screen",
        "artifacts": [{"kind": "screenshot", "path": ".harmony/artifacts/frontend-check.png", "description": "screen"}]
      }))

      assert {:ok, manifest} = SymphonyElixir.Evidence.Manifest.read(workspace)
      assert manifest.frontend_changed == true
      assert [%{kind: "screenshot", path: path, description: "screen"}] = manifest.artifacts
      assert path == Path.join(workspace, ".harmony/artifacts/frontend-check.png")
    after
      File.rm_rf(workspace)
    end
  end
end
