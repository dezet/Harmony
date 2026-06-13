defmodule SymphonyElixirWeb.FallbackController do
  @moduledoc """
  Translates action `{:error, _}` returns into the JSON error envelope
  `%{error: %{code, message, fields?}}`.
  """

  use Phoenix.Controller, formats: [:json]

  @spec call(Plug.Conn.t(), {:error, Ecto.Changeset.t() | :not_found | :run_not_found | :already_terminal | :not_retrying | :artifact_not_found | :artifact_path_unsafe | {:artifact_too_large, String.t(), non_neg_integer()} | {:config_unavailable, term()}}) :: Plug.Conn.t()
  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "validation_failed",
        message: "Validation failed",
        fields: changeset_errors(changeset)
      }
    })
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: "Resource not found"}})
  end

  def call(conn, {:error, :run_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "run_not_found", message: "Run not found"}})
  end

  def call(conn, {:error, :already_terminal}) do
    conn
    |> put_status(409)
    |> json(%{error: %{code: "already_terminal", message: "Run is already in a terminal state"}})
  end

  def call(conn, {:error, :not_retrying}) do
    conn
    |> put_status(409)
    |> json(%{error: %{code: "not_retrying", message: "Run is not currently in a retrying state"}})
  end

  def call(conn, {:error, :artifact_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "artifact_not_found", message: "Artifact not found"}})
  end

  def call(conn, {:error, :artifact_path_unsafe}) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: %{code: "artifact_path_unsafe", message: "Artifact path is outside the workspace root"}})
  end

  def call(conn, {:error, {:artifact_too_large, _path, _size}}) do
    conn
    |> put_status(413)
    |> json(%{error: %{code: "artifact_too_large", message: "Artifact exceeds the maximum allowed size"}})
  end

  def call(conn, {:error, {:config_unavailable, _reason}}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{error: %{code: "config_unavailable", message: "Service configuration is unavailable"}})
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
