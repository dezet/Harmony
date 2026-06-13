defmodule SymphonyElixir.Gitlab.StructsTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Gitlab.{MergeRequest, Pipeline, Job, Note}

  test "MergeRequest.from_api maps iid, branches, sha, fork project ids" do
    raw = %{
      "iid" => 5,
      "title" => "Fix",
      "description" => "ABC-1",
      "web_url" => "u",
      "sha" => "deadbeef",
      "source_branch" => "feature",
      "target_branch" => "main",
      "source_project_id" => 42,
      "target_project_id" => 7,
      "project_id" => 7
    }

    mr = MergeRequest.from_api(raw)
    assert mr.number == 5
    assert mr.head_sha == "deadbeef"
    assert mr.head_ref == "feature"
    assert mr.base_ref == "main"
    assert mr.body == "ABC-1"
    assert mr.head_repo_full_name == "42"
    assert mr.base_repo_full_name == "7"
    assert mr.project_id == 7
  end

  test "Pipeline.from_api maps id/status/sha" do
    p = Pipeline.from_api(%{"id" => 99, "status" => "failed", "ref" => "feature", "sha" => "abc", "web_url" => "u"})
    assert p.id == 99 and p.status == "failed" and p.sha == "abc"
  end

  test "Job.from_api maps id/name/status" do
    j = Job.from_api(%{"id" => 3, "name" => "test", "status" => "failed"})
    assert j.id == 3 and j.name == "test" and j.status == "failed"
  end

  test "Note.from_api maps id/body/author" do
    n = Note.from_api(%{"id" => 8, "body" => "@hreview", "author" => %{"username" => "dev"}})
    assert n.id == 8 and n.body == "@hreview" and n.author == "dev"
  end
end
