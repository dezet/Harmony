defmodule SymphonyElixir.Intake.AnalysisContext do
  @moduledoc "Builds a bounded, read-only repository snapshot for an intake analysis."

  alias SymphonyElixir.Forge
  alias SymphonyElixir.Forge.ProjectCreds
  alias SymphonyElixir.PathSafety

  @max_unpacked_bytes 100 * 1024 * 1024
  @max_files 20_000

  @type prepared_context :: %{
          path: Path.t(),
          input_snapshot: map()
        }

  @spec prepare(Path.t(), String.t(), pos_integer(), map()) ::
          {:ok, prepared_context()} | {:error, term()}
  def prepare(workspace_root, case_id, version, project) do
    prepare(workspace_root, case_id, version, project, [])
  end

  @spec prepare(Path.t(), String.t(), pos_integer(), map(), keyword()) ::
          {:ok, prepared_context()} | {:error, term()}
  def prepare(workspace_root, case_id, version, project, opts)
      when is_binary(workspace_root) and is_binary(case_id) and is_integer(version) and
             version > 0 and is_map(project) and is_list(opts) do
    with {:ok, snapshot_path} <- snapshot_path(workspace_root, case_id, version) do
      case repository_snapshot(project, opts) do
        {:ok, snapshot} -> prepare_repository_context(snapshot_path, snapshot, project, case_id, version)
        {:error, :repository_not_configured} -> issue_only_context(snapshot_path, "repository_not_configured")
        {:error, _reason} -> issue_only_context(snapshot_path, "repository_unavailable")
      end
    end
  end

  def prepare(_workspace_root, _case_id, _version, _project, _opts), do: {:error, :invalid_analysis_context}

  @spec cleanup(Path.t(), String.t(), pos_integer()) :: :ok | {:error, term()}
  def cleanup(workspace_root, case_id, version)
      when is_binary(workspace_root) and is_binary(case_id) and is_integer(version) and version > 0 do
    with {:ok, path} <- snapshot_path(workspace_root, case_id, version) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> File.rm_rf(path) |> cleanup_result()
        {:ok, _other} -> {:error, :invalid_snapshot_directory}
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, {:snapshot_cleanup_failed, reason}}
      end
    end
  end

  def cleanup(_workspace_root, _case_id, _version), do: {:error, :invalid_analysis_context}

  defp repository_snapshot(project, opts) do
    ref = ProjectCreds.repo_ref(project)

    if valid_repository_ref?(ref) do
      adapter = Keyword.get(opts, :forge_adapter, Forge.adapter(project))
      creds = ProjectCreds.creds(project, Keyword.take(opts, [:request_fun]))

      case adapter.get_repository_snapshot(creds, ref) do
        {:ok, snapshot} -> validate_repository_snapshot(snapshot)
        {:error, reason} -> {:error, reason}
        _other -> {:error, :invalid_repository_snapshot}
      end
    else
      {:error, :repository_not_configured}
    end
  rescue
    _error -> {:error, :repository_unavailable}
  end

  defp valid_repository_ref?(%{owner: owner, repo: repo}) do
    is_binary(owner) and owner != "" and is_binary(repo) and repo != ""
  end

  defp validate_repository_snapshot(%{default_branch: branch, sha: sha, archive: archive} = snapshot)
       when is_binary(branch) and branch != "" and is_binary(sha) and sha != "" and is_binary(archive) do
    {:ok, Map.take(snapshot, [:default_branch, :sha, :archive])}
  end

  defp validate_repository_snapshot(_snapshot), do: {:error, :invalid_repository_snapshot}

  defp prepare_repository_context(snapshot_path, snapshot, project, case_id, version) do
    with {:ok, entries} <- archive_entries(snapshot.archive),
         {:ok, contents} <- archive_contents(snapshot.archive, entries),
         :ok <- create_snapshot_directory(snapshot_path),
         :ok <- write_snapshot(snapshot_path, entries, contents) do
      {:ok,
       %{
         path: snapshot_path,
         input_snapshot: repository_input_snapshot(project, snapshot, case_id, version)
       }}
    else
      {:issue_only, reason} -> issue_only_context(snapshot_path, reason)
      {:error, {:unsafe_archive, _reason}} = error -> error
      {:error, :snapshot_already_exists} = error -> error
      {:error, reason} -> issue_only_context(snapshot_path, issue_reason(reason))
    end
  end

  defp archive_entries(archive) do
    case :erl_tar.table({:binary, archive}, [:compressed, :verbose]) do
      {:ok, entries} -> validate_archive_entries(entries)
      {:error, _reason} -> {:issue_only, "repository_archive_unavailable"}
    end
  rescue
    _error -> {:issue_only, "repository_archive_unavailable"}
  end

  defp validate_archive_entries(entries) when is_list(entries) do
    with {:ok, normalized} <- normalize_archive_entries(entries),
         {:ok, retained_entries} <- reject_unsafe_archive_entries(normalized),
         {:ok, rooted_entries} <- strip_archive_root(retained_entries),
         :ok <- enforce_archive_limits(retained_entries),
         :ok <- reject_duplicate_paths(rooted_entries),
         :ok <- reject_file_ancestors(rooted_entries) do
      {:ok, rooted_entries}
    end
  end

  defp normalize_archive_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case normalize_archive_entry(entry) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, {:unsafe_archive, reason}}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_archive_entry({name, type, size, _mtime, _mode, _uid, _gid}) do
    with {:ok, archive_name} <- archive_name(name),
         {:ok, path} <- safe_archive_path(archive_name) do
      case type do
        :directory ->
          {:ok, %{name: name, path: path, type: :directory, size: 0}}

        :regular when is_integer(size) and size >= 0 ->
          {:ok, %{name: name, path: path, type: :regular, size: size}}

        :symlink ->
          {:error, {:link_entry, archive_name}}

        :hardlink ->
          {:error, {:link_entry, archive_name}}

        :link ->
          {:error, {:link_entry, archive_name}}

        _other ->
          {:error, {:unsupported_entry_type, archive_name}}
      end
    end
  end

  defp normalize_archive_entry(_entry), do: {:error, :invalid_archive_entry}

  defp archive_name(name) when is_list(name) do
    case :unicode.characters_to_binary(name) do
      binary when is_binary(binary) -> {:ok, binary}
      _invalid -> {:error, :invalid_archive_path_encoding}
    end
  end

  defp archive_name(name) when is_binary(name), do: {:ok, name}
  defp archive_name(_name), do: {:error, :invalid_archive_path}

  defp safe_archive_path(name) do
    path = String.trim_trailing(name, "/")
    components = String.split(path, "/")

    cond do
      path == "" -> {:error, :empty_archive_path}
      String.starts_with?(path, "/") -> {:error, {:absolute_path, name}}
      String.contains?(path, ["\\", <<0>>]) -> {:error, {:invalid_path_character, name}}
      Enum.any?(components, &(&1 in ["", ".", ".."])) -> {:error, {:path_traversal, name}}
      true -> {:ok, path}
    end
  end

  defp strip_archive_root(entries) do
    first_components =
      entries
      |> Enum.map(&(&1.path |> String.split("/") |> hd()))
      |> Enum.uniq()

    has_nested_path? = Enum.any?(entries, &String.contains?(&1.path, "/"))

    case first_components do
      [root] when has_nested_path? ->
        if Enum.any?(entries, &(&1.path == root and &1.type != :directory)) do
          {:error, {:unsafe_archive, :invalid_archive_root}}
        else
          stripped =
            Enum.map(entries, fn entry ->
              relative = String.replace_prefix(entry.path, root <> "/", "")
              relative = if relative == entry.path and entry.path == root, do: "", else: relative
              %{entry | path: relative}
            end)

          {:ok, Enum.reject(stripped, &(&1.path == ""))}
        end

      _other ->
        {:ok, entries}
    end
  end

  defp reject_unsafe_archive_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      cond do
        entry.path == "" ->
          {:cont, {:ok, acc}}

        String.split(entry.path, "/") |> Enum.any?(&(&1 in [".", ".."])) ->
          {:halt, {:error, {:unsafe_archive, {:path_traversal, entry.path}}}}

        String.split(entry.path, "/") |> Enum.any?(&(&1 == ".git")) ->
          {:cont, {:ok, acc}}

        true ->
          {:cont, {:ok, [entry | acc]}}
      end
    end)
    |> case do
      {:ok, retained} -> {:ok, Enum.reverse(retained)}
      error -> error
    end
  end

  defp enforce_archive_limits(entries) do
    file_count = Enum.count(entries, &(&1.type == :regular))
    unpacked_bytes = entries |> Enum.filter(&(&1.type == :regular)) |> Enum.reduce(0, &(&1.size + &2))

    cond do
      file_count > @max_files -> {:issue_only, "repository_snapshot_file_limit_exceeded"}
      unpacked_bytes > @max_unpacked_bytes -> {:issue_only, "repository_snapshot_size_limit_exceeded"}
      true -> :ok
    end
  end

  defp reject_duplicate_paths(entries) do
    paths = Enum.map(entries, & &1.path)

    if length(paths) == length(Enum.uniq(paths)) do
      :ok
    else
      {:error, {:unsafe_archive, :duplicate_archive_path}}
    end
  end

  defp reject_file_ancestors(entries) do
    file_paths = entries |> Enum.filter(&(&1.type == :regular)) |> MapSet.new(& &1.path)

    conflict? =
      Enum.any?(entries, fn entry ->
        entry.path
        |> String.split("/")
        |> Enum.scan([], &(&2 ++ [&1]))
        |> Enum.drop(-1)
        |> Enum.any?(fn components -> MapSet.member?(file_paths, Enum.join(components, "/")) end)
      end)

    if conflict?, do: {:error, {:unsafe_archive, :file_used_as_directory}}, else: :ok
  end

  defp archive_contents(archive, entries) do
    files = entries |> Enum.filter(&(&1.type == :regular)) |> Enum.map(& &1.name)

    case :erl_tar.extract({:binary, archive}, [:compressed, :memory, {:files, files}]) do
      {:ok, contents} -> {:ok, contents}
      {:error, _reason} -> {:issue_only, "repository_archive_unavailable"}
    end
  rescue
    _error -> {:issue_only, "repository_archive_unavailable"}
  end

  defp write_snapshot(snapshot_path, entries, contents) do
    with :ok <- create_snapshot_directories(snapshot_path, entries),
         :ok <- write_snapshot_files(snapshot_path, entries, contents) do
      :ok
    else
      {:error, reason} ->
        File.rm_rf(snapshot_path)
        {:error, {:snapshot_write_failed, reason}}
    end
  end

  defp create_snapshot_directories(snapshot_path, entries) do
    entries
    |> Enum.filter(&(&1.type == :directory))
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      path = Path.join(snapshot_path, entry.path)

      case safe_snapshot_path(snapshot_path, path) do
        :ok ->
          case File.mkdir_p(path) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp write_snapshot_files(snapshot_path, entries, contents) do
    expected_files = entries |> Enum.filter(&(&1.type == :regular)) |> MapSet.new(& &1.name)

    with :ok <- validate_extracted_files(contents, expected_files) do
      Enum.reduce_while(contents, :ok, fn {name, binary}, :ok ->
        with entry when is_map(entry) <- Enum.find(entries, &(&1.name == name and &1.type == :regular)),
             path = Path.join(snapshot_path, entry.path),
             :ok <- safe_snapshot_path(snapshot_path, path),
             :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(path, binary) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, reason}}
          nil -> {:halt, {:error, :unexpected_archive_file}}
        end
      end)
    end
  end

  defp validate_extracted_files(contents, expected_files) do
    names = Enum.map(contents, fn {name, _binary} -> name end)

    if length(names) == MapSet.size(expected_files) and MapSet.new(names) == expected_files do
      :ok
    else
      {:error, :unexpected_archive_contents}
    end
  end

  defp safe_snapshot_path(snapshot_path, path) do
    with {:ok, canonical_root} <- PathSafety.canonicalize(snapshot_path),
         {:ok, canonical_path} <- PathSafety.canonicalize(path),
         true <- canonical_path == path and within_root?(canonical_path, canonical_root) do
      :ok
    else
      false -> {:error, :snapshot_path_outside_workspace}
      {:error, reason} -> {:error, reason}
    end
  end

  defp issue_only_context(snapshot_path, reason) do
    with :ok <- create_snapshot_directory(snapshot_path) do
      {:ok,
       %{
         path: snapshot_path,
         input_snapshot: %{
           "context_scope" => "issue_only",
           "context_reason" => reason
         }
       }}
    end
  end

  defp repository_input_snapshot(project, snapshot, case_id, version) do
    ref = ProjectCreds.repo_ref(project)

    %{
      "context_scope" => "issue_and_repository",
      "context_case_id" => case_id,
      "context_version" => version,
      "repository" => %{
        "forge_type" => Map.get(project, :forge_type) || Map.get(project, "forge_type"),
        "owner" => ref.owner,
        "name" => ref.repo
      },
      "repository_default_branch" => snapshot.default_branch,
      "repository_sha" => snapshot.sha
    }
  end

  defp issue_reason(:repository_snapshot_not_seeded), do: "repository_unavailable"
  defp issue_reason(:invalid_repository_snapshot), do: "repository_unavailable"
  defp issue_reason(:repository_archive_unavailable), do: "repository_archive_unavailable"
  defp issue_reason(_reason), do: "repository_archive_unavailable"

  defp create_snapshot_directory(snapshot_path) do
    with {:ok, canonical_root} <- snapshot_root(snapshot_path),
         :ok <- ensure_snapshot_parents(canonical_root, snapshot_path),
         :ok <- ensure_path_is_canonical(snapshot_path, canonical_root),
         :ok <- make_snapshot_directory(snapshot_path),
         :ok <- ensure_path_is_canonical(snapshot_path, canonical_root) do
      :ok
    end
  end

  defp ensure_snapshot_parents(root, snapshot_path) do
    with :ok <- File.mkdir_p(root),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
         :ok <- ensure_path_is_canonical(root, root) do
      [Path.join(root, "intake"), Path.dirname(snapshot_path)]
      |> Enum.reduce_while(:ok, fn path, :ok ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory}} ->
            case ensure_path_is_canonical(path, root) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:ok, _other} ->
            {:halt, {:error, :invalid_snapshot_parent}}

          {:error, :enoent} ->
            with :ok <- ensure_path_is_canonical(Path.dirname(path), root),
                 :ok <- File.mkdir(path),
                 :ok <- ensure_path_is_canonical(path, root) do
              {:cont, :ok}
            else
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:error, reason} ->
            {:halt, {:error, {:snapshot_parent_create_failed, reason}}}
        end
      end)
    else
      {:ok, _other} -> {:error, :invalid_workspace_root}
      {:error, reason} -> {:error, {:workspace_root_create_failed, reason}}
    end
  end

  defp make_snapshot_directory(snapshot_path) do
    case File.mkdir(snapshot_path) do
      :ok -> :ok
      {:error, :eexist} -> {:error, :snapshot_already_exists}
      {:error, reason} -> {:error, {:snapshot_directory_create_failed, reason}}
    end
  end

  defp snapshot_path(workspace_root, case_id, version) do
    if safe_component?(case_id) do
      with {:ok, canonical_root} <- PathSafety.canonicalize(workspace_root),
           path = Path.join([canonical_root, "intake", case_id, Integer.to_string(version)]),
           {:ok, canonical_path} <- PathSafety.canonicalize(path),
           true <- canonical_path == path and within_root?(canonical_path, canonical_root) do
        {:ok, path}
      else
        false -> {:error, :snapshot_path_outside_workspace}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_case_id}
    end
  end

  defp snapshot_root(snapshot_path) do
    snapshot_path
    |> Path.dirname()
    |> Path.dirname()
    |> Path.dirname()
    |> PathSafety.canonicalize()
  end

  defp ensure_path_is_canonical(path, root) do
    with {:ok, canonical_path} <- PathSafety.canonicalize(path),
         true <- canonical_path == path and within_root?(canonical_path, root) do
      :ok
    else
      false -> {:error, :snapshot_path_outside_workspace}
      {:error, reason} -> {:error, reason}
    end
  end

  defp within_root?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp safe_component?(value) do
    Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}\z/, value)
  end

  defp cleanup_result({:ok, _removed}), do: :ok
  defp cleanup_result({:error, reason, _removed}), do: {:error, {:snapshot_cleanup_failed, reason}}
end
