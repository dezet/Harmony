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

  describe "presenter never leaks a secret value" do
    alias SymphonyElixir.Storage.Project
    alias SymphonyElixirWeb.Presenter

    test "summary exposes set|unset, not the value" do
      project = %Project{id: "p1", slug: "p", forge_owner: "o", forge_repo: "r", forge_base_branch: "main", forge_secret: "ghp_tok", tracker_secret: nil}
      snapshot = %{running: [], retrying: [], blocked: []}
      payload = Presenter.project_summary_payload(project, snapshot, [])
      refute payload |> inspect() |> String.contains?("ghp_tok")
      assert get_in(payload, [:project, :forge_secret]) == "set"
      assert get_in(payload, [:project, :tracker_secret]) == "unset"
    end
  end

  describe "Storage.update_project_secrets/2" do
    @base %{
      slug: "portal",
      linear_project_slug: "p",
      linear_team_key: "COD",
      linear_human_review_state: "Human Review",
      forge_type: "github",
      forge_owner: "dezet",
      forge_repo: "portal",
      forge_base_branch: "main",
      config_version: 1,
      config: %{}
    }

    setup do
      :ok = checkout_repo(%{})
      {:ok, project} = Storage.upsert_project(@base)
      %{project: project}
    end

    @tag :db
    test "sets a secret when present", %{project: project} do
      {:ok, updated} = Storage.update_project_secrets(project, %{"forge_secret" => "ghp_tok"})
      assert Storage.get_project!(updated.id).forge_secret == "ghp_tok"
    end

    @tag :db
    test "leaves a secret unchanged when absent", %{project: project} do
      {:ok, _} = Storage.update_project_secrets(project, %{"forge_secret" => "ghp_tok"})
      reloaded = Storage.get_project!(project.id)
      {:ok, _} = Storage.update_project_secrets(reloaded, %{"tracker_secret" => "lin_key"})
      final = Storage.get_project!(project.id)
      assert final.forge_secret == "ghp_tok"
      assert final.tracker_secret == "lin_key"
    end

    @tag :db
    test "clears a secret via the clear flag", %{project: project} do
      {:ok, set} = Storage.update_project_secrets(project, %{"forge_secret" => "ghp_tok"})
      {:ok, _} = Storage.update_project_secrets(set, %{"clear_forge_secret" => true})
      assert Storage.get_project!(project.id).forge_secret == nil
    end

    @tag :db
    test "empty string is treated as absent (no change)", %{project: project} do
      {:ok, set} = Storage.update_project_secrets(project, %{"forge_secret" => "ghp_tok"})
      {:ok, _} = Storage.update_project_secrets(set, %{"forge_secret" => ""})
      assert Storage.get_project!(project.id).forge_secret == "ghp_tok"
    end

    @tag :db
    test "YAML-style re-upsert does not clobber a UI-set secret", %{project: project} do
      {:ok, _} = Storage.update_project_secrets(project, %{"forge_secret" => "ghp_tok"})
      {:ok, _} = Storage.upsert_project(%{@base | forge_base_branch: "develop"})
      reloaded = Storage.get_project!(project.id)
      assert reloaded.forge_base_branch == "develop"
      assert reloaded.forge_secret == "ghp_tok"
    end
  end
end
