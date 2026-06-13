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

  describe "Project.secret_changeset/2" do
    alias SymphonyElixir.Storage.Project

    test "casts only the secret fields" do
      cs = Project.secret_changeset(%Project{}, %{forge_secret: "tok", tracker_secret: "key", slug: "ignored"})
      assert Ecto.Changeset.get_change(cs, :forge_secret) == "tok"
      assert Ecto.Changeset.get_change(cs, :tracker_secret) == "key"
      assert Ecto.Changeset.get_change(cs, :slug) == nil
    end

    test "casts an explicit nil to clear a secret" do
      cs = Project.secret_changeset(%Project{forge_secret: "old"}, %{forge_secret: nil})
      assert Ecto.Changeset.get_field(cs, :forge_secret) == nil
    end
  end
end
