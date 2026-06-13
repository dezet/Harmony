defmodule SymphonyElixir.ProjectSecretsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Storage
  alias SymphonyElixir.Encrypted.Binary, as: EncryptedBinary

  describe "vault round-trip" do
    test "encrypts and decrypts through the Ecto type" do
      {:ok, ciphertext} = EncryptedBinary.dump("ghp_secret_value")
      assert is_binary(ciphertext)
      refute ciphertext == "ghp_secret_value"
      assert {:ok, "ghp_secret_value"} = EncryptedBinary.load(ciphertext)
    end
  end
end
