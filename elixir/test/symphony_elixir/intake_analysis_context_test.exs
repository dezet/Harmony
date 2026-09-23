defmodule SymphonyElixir.IntakeAnalysisContextTest.RaisingRepositorySnapshotAdapter do
  @moduledoc false

  @spec get_repository_snapshot(term(), term()) :: no_return()
  def get_repository_snapshot(_creds, _repo_ref), do: raise("synthetic adapter failure")
end

defmodule SymphonyElixir.IntakeAnalysisContextTest.InvalidRepositorySnapshotAdapter do
  @moduledoc false

  @spec get_repository_snapshot(term(), term()) :: {:ok, map()}
  def get_repository_snapshot(_creds, _repo_ref) do
    {:ok, %{default_branch: "", sha: "synthetic-sha", archive: "synthetic-archive"}}
  end
end

defmodule SymphonyElixir.IntakeAnalysisContextTest.UnexpectedRepositorySnapshotAdapter do
  @moduledoc false

  @spec get_repository_snapshot(term(), term()) :: atom()
  def get_repository_snapshot(_creds, _repo_ref), do: :unexpected_response
end

defmodule SymphonyElixir.IntakeAnalysisContextTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Forge.Memory
  alias SymphonyElixir.Intake.AnalysisContext
  alias SymphonyElixir.IntakeAnalysisContextTest.InvalidRepositorySnapshotAdapter
  alias SymphonyElixir.IntakeAnalysisContextTest.RaisingRepositorySnapshotAdapter
  alias SymphonyElixir.IntakeAnalysisContextTest.UnexpectedRepositorySnapshotAdapter

  setup do
    Memory.reset()
    test_root = Path.join(System.tmp_dir!(), "analysis-context-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}")
    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)

    on_exit(fn -> File.rm_rf(test_root) end)

    %{test_root: test_root, workspace_root: workspace_root}
  end

  test "rejects traversal archive entries before writing outside the workspace", context do
    archive = archive([{"repo/../../../../outside-canary", {:content, "synthetic payload"}}], context.test_root)
    seed_archive(archive)
    outside_canary = Path.join(context.test_root, "outside-canary")

    assert {:error, {:unsafe_archive, _reason}} =
             AnalysisContext.prepare(context.workspace_root, "case-traversal", 1, project())

    refute File.exists?(outside_canary)
    refute File.exists?(Path.join(context.workspace_root, "intake/case-traversal/1"))
  end

  test "rejects symlinks before an archived child can write through one", context do
    outside_dir = Path.join(context.test_root, "outside")
    File.mkdir_p!(outside_dir)
    link_source = Path.join(context.test_root, "link")
    File.ln_s!(outside_dir, link_source)

    archive =
      archive(
        [
          {"repo/escape", {:file, link_source}},
          {"repo/escape/outside-canary", {:content, "synthetic payload"}}
        ],
        context.test_root
      )

    seed_archive(archive)

    assert {:error, {:unsafe_archive, _reason}} =
             AnalysisContext.prepare(context.workspace_root, "case-symlink", 1, project())

    refute File.exists?(Path.join(outside_dir, "outside-canary"))
    refute File.exists?(Path.join(context.workspace_root, "intake/case-symlink/1"))
  end

  test "records the selected repository SHA and excludes git metadata without executing repository hooks", context do
    marker = Path.join(context.test_root, "hook-ran")
    token_canary = "SYNTHETIC-FORGE-TOKEN-CANARY"

    archive =
      archive(
        [
          {"repo-abc123/README.md", {:content, "safe source"}},
          {"repo-abc123/.git/config", {:content, "credential=#{token_canary}"}},
          {"repo-abc123/.git/credentials", {:content, token_canary}},
          {"repo-abc123/AGENTS.md", {:content, "touch #{marker}"}}
        ],
        context.test_root
      )

    seed_archive(archive)

    assert {:ok, %{path: snapshot_path, input_snapshot: input_snapshot} = result} =
             AnalysisContext.prepare(
               context.workspace_root,
               "case-success",
               3,
               project(%{forge_secret: token_canary})
             )

    assert input_snapshot["context_scope"] == "issue_and_repository"
    assert input_snapshot["repository_sha"] == "synthetic-sha"
    assert input_snapshot["repository_default_branch"] == "main"

    assert input_snapshot["repository"] == %{
             "forge_type" => "memory",
             "owner" => "synthetic-owner",
             "name" => "synthetic-repo"
           }

    assert File.read!(Path.join(snapshot_path, "README.md")) == "safe source"
    refute File.exists?(Path.join(snapshot_path, ".git"))
    refute File.exists?(marker)
    refute inspect(result) =~ token_canary

    sibling_archive =
      archive([{"repo/README.md", {:content, "sibling"}}], context.test_root)

    seed_archive(sibling_archive)

    assert {:ok, %{path: sibling_path}} =
             AnalysisContext.prepare(context.workspace_root, "case-sibling", 1, project())

    assert :ok = AnalysisContext.cleanup(context.workspace_root, "case-success", 3)
    refute File.exists?(snapshot_path)
    assert File.read!(Path.join(sibling_path, "README.md")) == "sibling"
    assert {:error, :invalid_case_id} = AnalysisContext.cleanup(context.workspace_root, "../outside", 3)
  end

  test "filters git metadata when the archive root itself is .git", context do
    token_canary = "SYNTHETIC-GIT-METADATA-CANARY"

    archive =
      archive(
        [
          {".git/config", {:content, "credential=#{token_canary}"}},
          {".git/credentials", {:content, token_canary}}
        ],
        context.test_root
      )

    seed_archive(archive)

    assert {:ok, %{path: snapshot_path}} =
             AnalysisContext.prepare(context.workspace_root, "case-git-root", 1, project())

    assert File.ls!(snapshot_path) == []
    refute inspect(snapshot_path) =~ token_canary
  end

  test "rejects duplicate archive paths", context do
    archive =
      archive(
        [
          {"repo/README.md", {:content, "first"}},
          {"repo/README.md", {:content, "second"}}
        ],
        context.test_root
      )

    seed_archive(archive)

    assert {:error, {:unsafe_archive, :duplicate_archive_path}} =
             AnalysisContext.prepare(context.workspace_root, "case-duplicate", 1, project())

    refute File.exists?(Path.join(context.workspace_root, "intake/case-duplicate/1"))
  end

  test "rejects hardlink entries before any link target can be materialized", context do
    archive = hardlink_archive(context.test_root)
    seed_archive(archive)
    outside_canary = Path.join(context.test_root, "outside-canary")

    assert {:error, {:unsafe_archive, {:link_entry, "repo/linked"}}} =
             AnalysisContext.prepare(context.workspace_root, "case-hardlink", 1, project())

    refute File.exists?(outside_canary)
    refute File.exists?(Path.join(context.workspace_root, "intake/case-hardlink/1"))
  end

  test "uses issue_only with a recorded reason when a repository is not configured", context do
    assert {:ok, %{path: snapshot_path, input_snapshot: input_snapshot}} =
             AnalysisContext.prepare(
               context.workspace_root,
               "case-issue-only",
               1,
               %{forge_type: "memory"}
             )

    assert input_snapshot == %{
             "context_scope" => "issue_only",
             "context_reason" => "repository_not_configured"
           }

    assert File.dir?(snapshot_path)
    assert File.ls!(snapshot_path) == []
  end

  test "validates prepare and cleanup arguments and distinguishes missing or invalid snapshots", context do
    assert {:error, :invalid_analysis_context} =
             AnalysisContext.prepare(context.workspace_root, "case-invalid", 0, project())

    assert {:error, :invalid_analysis_context} =
             AnalysisContext.cleanup(context.workspace_root, "case-invalid", 0)

    assert :ok = AnalysisContext.cleanup(context.workspace_root, "case-missing", 1)

    snapshot_path = Path.join([context.workspace_root, "intake", "case-file", "1"])
    File.mkdir_p!(Path.dirname(snapshot_path))
    File.write!(snapshot_path, "not a directory")

    assert {:error, :invalid_snapshot_directory} =
             AnalysisContext.cleanup(context.workspace_root, "case-file", 1)
  end

  test "uses issue_only when the configured repository snapshot is unavailable", context do
    assert {:ok, %{path: snapshot_path, input_snapshot: input_snapshot}} =
             AnalysisContext.prepare(context.workspace_root, "case-missing-repo", 1, project())

    assert input_snapshot == %{
             "context_scope" => "issue_only",
             "context_reason" => "repository_unavailable"
           }

    assert File.ls!(snapshot_path) == []
  end

  test "uses issue_only when the forge adapter raises while loading a repository snapshot", context do
    assert {:ok, %{path: snapshot_path, input_snapshot: input_snapshot}} =
             AnalysisContext.prepare(
               context.workspace_root,
               "case-adapter-error",
               1,
               project(),
               forge_adapter: RaisingRepositorySnapshotAdapter
             )

    assert input_snapshot["context_scope"] == "issue_only"
    assert input_snapshot["context_reason"] == "repository_unavailable"
    assert File.ls!(snapshot_path) == []
  end

  test "fails closed on malformed and unexpected repository snapshot responses", context do
    adapters = [
      {"case-invalid-snapshot", InvalidRepositorySnapshotAdapter},
      {"case-unexpected-snapshot", UnexpectedRepositorySnapshotAdapter}
    ]

    for {case_id, adapter} <- adapters do
      assert {:ok, %{path: snapshot_path, input_snapshot: input_snapshot}} =
               AnalysisContext.prepare(context.workspace_root, case_id, 1, project(), forge_adapter: adapter)

      assert input_snapshot["context_scope"] == "issue_only"
      assert input_snapshot["context_reason"] == "repository_unavailable"
      assert File.ls!(snapshot_path) == []
    end
  end

  test "uses issue_only when a repository archive is malformed", context do
    seed_archive(<<>>)

    assert {:ok, %{path: snapshot_path, input_snapshot: input_snapshot}} =
             AnalysisContext.prepare(context.workspace_root, "case-malformed-archive", 1, project())

    assert input_snapshot["context_scope"] == "issue_only"
    assert input_snapshot["context_reason"] == "repository_archive_unavailable"
    assert File.ls!(snapshot_path) == []
  end

  test "uses issue_only when a TAR header has a truncated file payload", context do
    archive = archive([{"repo/source.ex", {:content, "payload that is missing"}}], context.test_root)
    <<header::binary-size(512), _remainder::binary>> = :zlib.gunzip(archive)
    seed_archive(:zlib.gzip(header))

    assert {:ok, %{path: snapshot_path, input_snapshot: input_snapshot}} =
             AnalysisContext.prepare(context.workspace_root, "case-truncated-payload", 1, project())

    assert input_snapshot["context_scope"] == "issue_only"
    assert input_snapshot["context_reason"] == "repository_archive_unavailable"
    assert File.ls!(snapshot_path) == []
  end

  test "refuses a regular file as the workspace root before loading a repository", context do
    workspace_root = Path.join(context.test_root, "workspace-file")
    File.write!(workspace_root, "not a directory")

    assert {:error, _reason} = AnalysisContext.prepare(workspace_root, "case-file-root", 1, project())
    assert Memory.recorded_calls() == []
  end

  test "does not overwrite an existing snapshot and writes archives without a common root", context do
    archive =
      archive(
        [
          {"README.md", {:content, "root-level source"}},
          {"docs/guide.md", {:content, "nested source"}}
        ],
        context.test_root
      )

    seed_archive(archive)

    assert {:ok, %{path: snapshot_path, input_snapshot: input_snapshot}} =
             AnalysisContext.prepare(context.workspace_root, "case-rootless", 1, project())

    assert input_snapshot["context_scope"] == "issue_and_repository"
    assert File.read!(Path.join(snapshot_path, "README.md")) == "root-level source"
    assert File.read!(Path.join(snapshot_path, "docs/guide.md")) == "nested source"

    assert {:error, :snapshot_already_exists} =
             AnalysisContext.prepare(context.workspace_root, "case-rootless", 1, project())

    assert File.read!(Path.join(snapshot_path, "README.md")) == "root-level source"
  end

  test "rejects a regular archive root that also contains children", context do
    archive =
      archive(
        [
          {"repo", {:content, "root file"}},
          {"repo/child.txt", {:content, "nested file"}}
        ],
        context.test_root
      )

    seed_archive(archive)

    assert {:error, {:unsafe_archive, :invalid_archive_root}} =
             AnalysisContext.prepare(context.workspace_root, "case-file-root", 1, project())

    refute File.exists?(Path.join(context.workspace_root, "intake/case-file-root/1"))
  end

  test "rejects archive files used as parent directories", context do
    archive =
      archive(
        [
          {"repo/docs", {:content, "file cannot be a directory"}},
          {"repo/docs/guide.md", {:content, "nested file"}}
        ],
        context.test_root
      )

    seed_archive(archive)

    assert {:error, {:unsafe_archive, :file_used_as_directory}} =
             AnalysisContext.prepare(context.workspace_root, "case-file-ancestor", 1, project())

    refute File.exists?(Path.join(context.workspace_root, "intake/case-file-ancestor/1"))
  end

  test "preserves empty archive directories in the repository snapshot", context do
    archive = archive_with_typeflag(context.test_root, "repo/empty-dir", "5")
    seed_archive(archive)

    assert {:ok, %{path: snapshot_path}} =
             AnalysisContext.prepare(context.workspace_root, "case-empty-directory", 1, project())

    empty_directory = Path.join(snapshot_path, "empty-dir")
    assert File.dir?(empty_directory)
    assert File.ls!(empty_directory) == []
  end

  test "rejects unsupported archive entry types", context do
    archive = archive_with_typeflag(context.test_root, "repo/fifo", "6")
    seed_archive(archive)

    assert {:error, {:unsafe_archive, {:unsupported_entry_type, "repo/fifo"}}} =
             AnalysisContext.prepare(context.workspace_root, "case-special-entry", 1, project())

    refute File.exists?(Path.join(context.workspace_root, "intake/case-special-entry/1"))
  end

  test "rejects a linked intake directory before requesting a repository archive", context do
    outside = Path.join(context.test_root, "outside-intake")
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(context.workspace_root, "intake"))

    assert {:error, :snapshot_path_outside_workspace} =
             AnalysisContext.prepare(context.workspace_root, "case-linked-intake", 1, project())

    assert Memory.recorded_calls() == []
    assert File.ls!(outside) == []
  end

  test "cleanup removes only the validated snapshot version and refuses a linked snapshot", context do
    snapshots = Path.join([context.workspace_root, "intake", "case-cleanup"])
    snapshot_v1 = Path.join(snapshots, "1")
    snapshot_v2 = Path.join(snapshots, "2")
    outside = Path.join(context.test_root, "outside-snapshot")

    File.mkdir_p!(snapshot_v1)
    File.write!(Path.join(snapshot_v1, "source.ex"), "synthetic source")
    File.mkdir_p!(snapshot_v2)
    File.write!(Path.join(snapshot_v2, "source.ex"), "sibling version")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "outside-canary"), "preserve")
    File.ln_s!(outside, Path.join(snapshots, "3"))

    assert :ok = AnalysisContext.cleanup(context.workspace_root, "case-cleanup", 1)
    refute File.exists?(snapshot_v1)
    assert File.read!(Path.join(snapshot_v2, "source.ex")) == "sibling version"
    assert {:error, _reason} = AnalysisContext.cleanup(context.workspace_root, "case-cleanup", 3)
    assert File.read!(Path.join(outside, "outside-canary")) == "preserve"
  end

  test "falls back to issue_only when the unpacked file limit is exceeded", context do
    files =
      Enum.map(1..20_001, fn index ->
        {"repo/file-#{index}", {:content, <<>>}}
      end)

    archive = archive(files, context.test_root)
    seed_archive(archive)

    assert {:ok, %{path: snapshot_path, input_snapshot: input_snapshot}} =
             AnalysisContext.prepare(context.workspace_root, "case-many-files", 1, project())

    assert input_snapshot["context_scope"] == "issue_only"
    assert input_snapshot["context_reason"] == "repository_snapshot_file_limit_exceeded"
    assert File.ls!(snapshot_path) == []
  end

  test "falls back to issue_only when unpacked archive size exceeds 100 MiB", context do
    sparse_file = Path.join(context.test_root, "large.bin")
    {:ok, file} = :file.open(String.to_charlist(sparse_file), [:write, :binary])
    {:ok, _position} = :file.position(file, 100 * 1024 * 1024)
    :ok = :file.write(file, <<0>>)
    :ok = :file.close(file)

    archive = archive([{"repo/large.bin", {:file, sparse_file}}], context.test_root)
    seed_archive(archive)

    assert {:ok, %{path: snapshot_path, input_snapshot: input_snapshot}} =
             AnalysisContext.prepare(context.workspace_root, "case-large", 1, project())

    assert input_snapshot["context_scope"] == "issue_only"
    assert input_snapshot["context_reason"] == "repository_snapshot_size_limit_exceeded"
    assert File.ls!(snapshot_path) == []
  end

  defp project(attrs \\ %{}) do
    Map.merge(
      %{
        forge_type: "memory",
        forge_owner: "synthetic-owner",
        forge_repo: "synthetic-repo",
        forge_base_url: nil
      },
      attrs
    )
  end

  defp seed_archive(archive) do
    Memory.seed_repository_snapshot(%{
      owner: "synthetic-owner",
      repo: "synthetic-repo",
      default_branch: "main",
      sha: "synthetic-sha",
      archive: archive
    })
  end

  defp archive(entries, test_root) do
    archive_path = Path.join(test_root, "synthetic-#{System.unique_integer([:positive])}.tar.gz")

    files =
      Enum.map(entries, fn
        {archive_name, {:content, payload}} ->
          {String.to_charlist(archive_name), payload}

        {archive_name, {:file, source_path}} ->
          {String.to_charlist(archive_name), String.to_charlist(source_path)}
      end)

    :ok = :erl_tar.create(String.to_charlist(archive_path), files, [:compressed])
    File.read!(archive_path)
  end

  defp hardlink_archive(test_root) do
    tar_path = Path.join(test_root, "synthetic-hardlink.tar")

    :ok =
      :erl_tar.create(
        String.to_charlist(tar_path),
        [{~c"repo/target", <<>>}, {~c"repo/linked", <<>>}]
      )

    tar = File.read!(tar_path)
    <<first_header::binary-size(512), linked_header::binary-size(512), remainder::binary>> = tar

    linked_header =
      linked_header
      |> replace_tar_field(124, 12, "00000000000" <> <<0>>)
      |> replace_tar_field(156, 1, "1")
      |> replace_tar_field(157, 100, "../../outside-canary")
      |> replace_tar_field(148, 8, "        ")

    checksum = linked_header |> :binary.bin_to_list() |> Enum.sum()
    checksum_field = checksum |> Integer.to_string(8) |> String.pad_leading(6, "0") |> Kernel.<>(<<0, 32>>)
    linked_header = replace_tar_field(linked_header, 148, 8, checksum_field)

    :zlib.gzip(first_header <> linked_header <> remainder)
  end

  defp archive_with_typeflag(test_root, member_name, typeflag) do
    tar_path = Path.join(test_root, "synthetic-type-#{System.unique_integer([:positive])}.tar")

    :ok =
      :erl_tar.create(
        String.to_charlist(tar_path),
        [{String.to_charlist(member_name), <<>>}]
      )

    tar = File.read!(tar_path)
    <<header::binary-size(512), remainder::binary>> = tar

    header =
      header
      |> replace_tar_field(156, 1, typeflag)
      |> replace_tar_field(148, 8, "        ")

    checksum = header |> :binary.bin_to_list() |> Enum.sum()
    checksum_field = checksum |> Integer.to_string(8) |> String.pad_leading(6, "0") |> Kernel.<>(<<0, 32>>)
    header = replace_tar_field(header, 148, 8, checksum_field)

    :zlib.gzip(header <> remainder)
  end

  defp replace_tar_field(binary, offset, size, value) do
    padded = value <> :binary.copy(<<0>>, size - byte_size(value))
    <<prefix::binary-size(offset), _field::binary-size(size), suffix::binary>> = binary
    prefix <> padded <> suffix
  end
end
