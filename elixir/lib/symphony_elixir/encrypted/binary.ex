defmodule SymphonyElixir.Encrypted.Binary do
  @moduledoc "Ecto type for binary values encrypted at rest via the project vault."
  use Cloak.Ecto.Binary, vault: SymphonyElixir.Vault
end
