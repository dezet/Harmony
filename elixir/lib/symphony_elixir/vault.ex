defmodule SymphonyElixir.Vault do
  @moduledoc """
  Cloak vault for per-project secrets. AES-256-GCM, key from `CLOAK_KEY`
  (Base64-encoded, 32 bytes). The key is read at boot via `System.fetch_env!/1`,
  so a missing key crashes startup in every environment (no silent default).
  Configured as a key list so a future rotation is config-only.
  """
  use Cloak.Vault, otp_app: :symphony_elixir

  @impl GenServer
  def init(config) do
    key =
      "CLOAK_KEY"
      |> System.fetch_env!()
      |> Base.decode64!()

    ciphers = [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: key}
    ]

    {:ok, Keyword.put(config, :ciphers, ciphers)}
  end
end
