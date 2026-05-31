defmodule SymphonyElixir.VideoEvidenceTest do
  use SymphonyElixir.TestSupport

  test "collector persists video artifacts declared in evidence manifest" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "harmony-video-evidence-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"
      )

    parent = self()

    persist_artifact = fn attrs ->
      send(parent, {:artifact_attrs, attrs})
      {:ok, struct(SymphonyElixir.Storage.Artifact, attrs)}
    end

    try do
      File.mkdir_p!(Path.join(workspace, ".harmony/artifacts"))
      video_path = Path.join(workspace, ".harmony/artifacts/walkthrough.webm")
      File.write!(video_path, "webm")

      File.write!(
        Path.join(workspace, ".harmony/evidence.json"),
        ~s({"frontend_changed":true,"artifacts":[{"kind":"video","path":".harmony/artifacts/walkthrough.webm","description":"Feature walkthrough"}]})
      )

      assert {:ok, [%SymphonyElixir.Storage.Artifact{kind: "video"}]} =
               SymphonyElixir.Evidence.Collector.collect("project-1", "run-1", workspace, persist_artifact: persist_artifact)

      assert_received {:artifact_attrs,
                       %{
                         project_id: "project-1",
                         work_run_id: "run-1",
                         kind: "video",
                         path: ^video_path,
                         metadata: %{"description" => "Feature walkthrough"}
                       }}
    after
      File.rm_rf(workspace)
    end
  end

  test "manifest rejects video artifacts without descriptions" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "harmony-video-evidence-description-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"
      )

    try do
      File.mkdir_p!(Path.join(workspace, ".harmony/artifacts"))
      File.write!(Path.join(workspace, ".harmony/artifacts/walkthrough.webm"), "webm")

      File.write!(
        Path.join(workspace, ".harmony/evidence.json"),
        ~s({"frontend_changed":true,"artifacts":[{"kind":"video","path":".harmony/artifacts/walkthrough.webm"}]})
      )

      assert {:error, {:missing_video_evidence_description, ".harmony/artifacts/walkthrough.webm"}} =
               SymphonyElixir.Evidence.Manifest.read(workspace)
    after
      File.rm_rf(workspace)
    end
  end
end
