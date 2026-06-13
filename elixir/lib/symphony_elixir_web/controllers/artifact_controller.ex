defmodule SymphonyElixirWeb.ArtifactController do
  @moduledoc """
  Serves raw artifact file content with a strict workspace-root containment
  security posture.

  Route:
    GET /api/v1/artifacts/:id — returns the file at artifact.path

  Security posture (Locked decision 2):
  1. Only the artifact UUID is untrusted input — the DB row is the allowlist.
  2. At serve time we re-expand the stored path and require it to be within the
     configured workspace.root. 403 on escape (catches symlink drift and
     config changes since write time). 404 on miss.
  3. File size is capped at 100 MB; exceeding it returns 413.
  4. Content-type is derived from a static kind→mime map (no sniffing).
  5. `path` is never returned in any JSON response.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Config, Storage}

  action_fallback(SymphonyElixirWeb.FallbackController)

  @max_size_bytes 100_000_000

  # Static kind → {content_type, disposition} map.
  # screenshot disposition is inline; extension determines MIME.
  # All others are attachments.
  @kind_mime %{
    "report" => {"application/octet-stream", :attachment},
    "video" => {"video/mp4", :attachment},
    "trace" => {"application/zip", :attachment}
  }

  @screenshot_ext_mime %{
    "png" => "image/png",
    "jpg" => "image/jpeg",
    "jpeg" => "image/jpeg",
    "gif" => "image/gif"
  }

  # ---------------------------------------------------------------------------
  # show — GET /api/v1/artifacts/:id
  # ---------------------------------------------------------------------------

  @spec show(Conn.t(), map()) :: Conn.t() | {:error, atom()}
  def show(conn, %{"id" => id}) do
    with artifact when not is_nil(artifact) <- Storage.get_artifact(id),
         {:ok, root} <- workspace_root(),
         :ok <- check_path_within_root(artifact.path, root),
         expanded = Path.expand(artifact.path),
         {:ok, stat} <- stat_or_not_found(expanded),
         :ok <- check_size(expanded, stat) do
      {content_type, disposition} = resolve_content(artifact.kind, expanded)

      conn
      |> apply_disposition(disposition, expanded)
      |> put_resp_content_type(content_type)
      |> send_file(200, expanded)
    else
      nil -> {:error, :artifact_not_found}
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # method_not_allowed
  # ---------------------------------------------------------------------------

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> put_status(405)
    |> json(%{error: %{code: "method_not_allowed", message: "Method not allowed"}})
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Resolve workspace root from Config. Returns {:ok, root} | {:error, reason}.
  defp workspace_root do
    case Config.settings() do
      {:ok, settings} -> {:ok, settings.workspace.root}
      {:error, reason} -> {:error, {:config_unavailable, reason}}
    end
  end

  @doc false
  # path_within?/2 — true iff path is exactly root or directly under root/.
  # Defends against the prefix-bypass attack: a root of "/workspaces" must NOT
  # match a path like "/workspaces-evil/file.txt".
  @spec path_within?(String.t(), String.t()) :: boolean()
  def path_within?(path, root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)
    expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/")
  end

  defp check_path_within_root(path, root) do
    if path_within?(path, root) do
      :ok
    else
      {:error, :artifact_path_unsafe}
    end
  end

  defp stat_or_not_found(expanded_path) do
    case File.stat(expanded_path) do
      {:ok, stat} -> {:ok, stat}
      {:error, _reason} -> {:error, :artifact_not_found}
    end
  end

  defp check_size(expanded_path, %File.Stat{size: size}) when size > @max_size_bytes do
    {:error, {:artifact_too_large, expanded_path, size}}
  end

  defp check_size(_expanded_path, _stat), do: :ok

  defp resolve_content("screenshot", path) do
    ext = path |> Path.extname() |> String.trim_leading(".") |> String.downcase()
    mime = Map.get(@screenshot_ext_mime, ext, "application/octet-stream")

    if mime == "application/octet-stream" do
      {mime, :attachment}
    else
      {mime, :inline}
    end
  end

  defp resolve_content(kind, _path) do
    {mime, disposition} = Map.get(@kind_mime, kind, {"application/octet-stream", :attachment})
    {mime, disposition}
  end

  defp apply_disposition(conn, :inline, _path) do
    put_resp_header(conn, "content-disposition", "inline")
  end

  defp apply_disposition(conn, :attachment, path) do
    filename = Path.basename(path)
    put_resp_header(conn, "content-disposition", "attachment; filename=\"#{filename}\"")
  end
end
