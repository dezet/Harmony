defmodule SymphonyElixir.Review.Identity do
  @moduledoc """
  Resolves the Harmony bot login used to skip the bot's own review replies:
  project config `review.bot_identity` → forge whoami (cached per token) → "harmony".
  """

  @default "harmony"
  @table :review_identity_cache

  @spec resolve(map(), map(), keyword()) :: String.t()
  def resolve(project, creds, opts \\ []) do
    case config_identity(project) do
      identity when is_binary(identity) and identity != "" -> identity
      _ -> whoami_or_default(creds, opts)
    end
  end

  @spec reset_cache() :: :ok
  def reset_cache do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp config_identity(project) do
    project
    |> mget(:config)
    |> case do
      %{} = cfg -> cfg |> mget("review") |> mget("bot_identity")
      _ -> nil
    end
  end

  defp whoami_or_default(creds, opts) do
    token = Map.get(creds, :token)
    ensure_table()

    case token && :ets.lookup(@table, token) do
      [{^token, login}] ->
        login

      _ ->
        current_user = Keyword.get(opts, :current_user, fn c -> default_current_user(c) end)

        case current_user.(creds) do
          {:ok, login} when is_binary(login) and login != "" ->
            if token, do: :ets.insert(@table, {token, login})
            login

          _ ->
            @default
        end
    end
  end

  defp default_current_user(_creds), do: {:error, :not_wired}

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _ -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp mget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp mget(_map, _key), do: nil
end
