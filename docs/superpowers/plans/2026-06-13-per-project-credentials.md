# Per-Project Credentials (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Store per-project forge and tracker credentials encrypted at rest with Cloak, resolve the forge token per-project at call time with global-env fallback, and expose a write-only secret API/form — without touching the global tracker poll path.

**Architecture:** A `Cloak.Vault` (AES-256-GCM, key from `CLOAK_KEY`, fail-fast at boot in every env) supervises secret encryption. Two `Cloak.Ecto.Binary` columns (`forge_secret`, `tracker_secret`) are added to `projects`. `ProjectCreds` resolves the forge token from the project secret (or, given a `WorkRun`, by looking the project up via `forge_owner`+`forge_repo`), falling back to env. The controller accepts secret params + explicit `clear_*` flags and never echoes a value. YAML sync is left untouched and verified not to clobber secrets.

**Tech Stack:** Elixir, Phoenix, Ecto/Postgres, Cloak + cloak_ecto, ExUnit.

**Spec:** `docs/superpowers/specs/2026-06-13-per-project-credentials-design.md`

**Test DB / key:** Tests need Postgres (podman container `harmony-postgres` on 5432) and a `CLOAK_KEY`. Because the Vault is fail-fast in every environment, **every** `mix` command that boots the app must export a key. Use a fresh per-run key — the sandbox rolls back, so nothing encrypted persists between runs:

```
export CLOAK_KEY="$(openssl rand -base64 32)"
```

All test commands below assume `CLOAK_KEY` is exported in the shell. Run from `elixir/`.

---

## File Structure

- Create `elixir/lib/symphony_elixir/vault.ex` — the Cloak vault (key from env, fail-fast).
- Create `elixir/lib/symphony_elixir/encrypted/binary.ex` — the `Cloak.Ecto.Binary` field type bound to the vault.
- Create `elixir/priv/repo/migrations/<ts>_add_project_secrets.exs` — adds two nullable `:binary` columns.
- Modify `elixir/mix.exs` — add `:cloak`, `:cloak_ecto` deps.
- Modify `elixir/lib/symphony_elixir.ex` — supervise the vault (before `Repo`).
- Modify `elixir/lib/symphony_elixir/storage/project.ex` — encrypted fields + `secret_changeset/2`.
- Modify `elixir/lib/symphony_elixir/storage.ex` — `update_project_secrets/2`; keep secrets out of the upsert `on_conflict` replace list.
- Modify `elixir/lib/symphony_elixir/forge/project_creds.ex` — forge-secret resolution + env fallback.
- Modify `elixir/lib/symphony_elixir_web/controllers/project_controller.ex` — accept secret params + clear flags; emit `set|unset`.
- Modify `elixir/lib/symphony_elixir_web/presenter.ex` — emit `set|unset` in the project summary (never the value).
- Create `elixir/test/symphony_elixir/project_secrets_test.exs` — vault round-trip + resolution + write-only + clear + sync-preserve tests.
- Modify `elixir/test/symphony_elixir/project_creds_test.exs` — secret-takes-precedence + fallback tests.
- Create `docs/operations/credential-key.md` — `CLOAK_KEY` management + rotation ops note.

---

## Task 1: Cloak vault + encrypted field type

**Files:**
- Modify: `elixir/mix.exs`
- Create: `elixir/lib/symphony_elixir/vault.ex`
- Create: `elixir/lib/symphony_elixir/encrypted/binary.ex`
- Modify: `elixir/lib/symphony_elixir.ex:28-37` (children list)

- [ ] **Step 1: Add deps**

In `elixir/mix.exs`, inside `defp deps do [...]`, add after the `{:postgrex, ">= 0.0.0"},` line:

```elixir
      {:cloak, "~> 1.1"},
      {:cloak_ecto, "~> 1.3"},
```

- [ ] **Step 2: Fetch deps**

Run: `mix deps.get`
Expected: resolves and downloads `cloak` and `cloak_ecto` (and `cloak`'s deps). No error.

- [ ] **Step 3: Create the vault (fail-fast key)**

Create `elixir/lib/symphony_elixir/vault.ex`:

```elixir
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
```

- [ ] **Step 4: Create the encrypted field type**

Create `elixir/lib/symphony_elixir/encrypted/binary.ex`:

```elixir
defmodule SymphonyElixir.Encrypted.Binary do
  @moduledoc "Ecto type for binary values encrypted at rest via the project vault."
  use Cloak.Ecto.Binary, vault: SymphonyElixir.Vault
end
```

- [ ] **Step 5: Supervise the vault before Repo**

In `elixir/lib/symphony_elixir.ex`, change the `children` list (currently starting at line 28) so `SymphonyElixir.Vault` is the first child:

```elixir
    children = [
      SymphonyElixir.Vault,
      SymphonyElixir.Repo,
      {Task, fn -> sync_project_configs() end},
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
      SymphonyElixir.WorkflowStore,
      SymphonyElixir.Orchestrator,
      SymphonyElixir.HttpServer,
      SymphonyElixir.StatusDashboard
    ]
```

- [ ] **Step 6: Verify fail-fast and round-trip**

Create `elixir/test/symphony_elixir/project_secrets_test.exs`:

```elixir
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
```

- [ ] **Step 7: Run it**

Run: `mix test test/symphony_elixir/project_secrets_test.exs:1`
Expected: PASS. (If `CLOAK_KEY` is unset the app fails to boot — that is the intended fail-fast; export the key per the header.)

- [ ] **Step 8: Commit**

```bash
git add mix.exs mix.lock lib/symphony_elixir/vault.ex lib/symphony_elixir/encrypted/binary.ex lib/symphony_elixir.ex test/symphony_elixir/project_secrets_test.exs
git commit -m "feat(creds): add Cloak vault and encrypted binary type"
```

---

## Task 2: Migration — secret columns

**Files:**
- Create: `elixir/priv/repo/migrations/<ts>_add_project_secrets.exs`

- [ ] **Step 1: Generate the migration**

Run: `mix ecto.gen.migration add_project_secrets`
Expected: prints the created file path under `priv/repo/migrations/`.

- [ ] **Step 2: Write the migration body**

Replace the generated file's contents with:

```elixir
defmodule SymphonyElixir.Repo.Migrations.AddProjectSecrets do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :forge_secret, :binary
      add :tracker_secret, :binary
    end
  end
end
```

- [ ] **Step 3: Migrate**

Run: `mix ecto.migrate`
Expected: applies `add_project_secrets`, no error. (Re-runnable: `mix ecto.rollback` then `mix ecto.migrate` both succeed — the columns are nullable with no backfill.)

- [ ] **Step 4: Commit**

```bash
git add priv/repo/migrations/*_add_project_secrets.exs
git commit -m "feat(creds): add nullable forge_secret/tracker_secret columns"
```

---

## Task 3: Schema — encrypted fields + secret changeset

**Files:**
- Modify: `elixir/lib/symphony_elixir/storage/project.ex`

- [ ] **Step 1: Write the failing test**

Append to `elixir/test/symphony_elixir/project_secrets_test.exs`, inside the module:

```elixir
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
```

- [ ] **Step 2: Run it (fails)**

Run: `mix test test/symphony_elixir/project_secrets_test.exs -k "secret_changeset"`
Expected: FAIL — `function SymphonyElixir.Storage.Project.secret_changeset/2 is undefined`.

- [ ] **Step 3: Add fields and changeset**

In `elixir/lib/symphony_elixir/storage/project.ex`, add the two fields inside `schema "projects" do`, after the `field(:forge_base_url, :string)` line:

```elixir
    field(:forge_secret, SymphonyElixir.Encrypted.Binary, redact: true)
    field(:tracker_secret, SymphonyElixir.Encrypted.Binary, redact: true)
```

Then add a dedicated changeset after the existing `changeset/2` function:

```elixir
  @spec secret_changeset(t(), map()) :: Ecto.Changeset.t()
  def secret_changeset(project, attrs) do
    cast(project, attrs, [:forge_secret, :tracker_secret], empty_values: [])
  end
```

(`empty_values: []` lets an explicit `nil` cast through as a clear, instead of being treated as "missing".)

- [ ] **Step 4: Run it (passes)**

Run: `mix test test/symphony_elixir/project_secrets_test.exs -k "secret_changeset"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/symphony_elixir/storage/project.ex test/symphony_elixir/project_secrets_test.exs
git commit -m "feat(creds): encrypted secret fields + secret changeset on Project"
```

---

## Task 4: Storage — write/clear secrets, preserve on sync

**Files:**
- Modify: `elixir/lib/symphony_elixir/storage.ex`

`upsert_project/1`'s `on_conflict: {:replace, [...]}` list does **not** include the secret columns, so a YAML re-sync never touches them. We add `update_project_secrets/2` for the explicit write/clear path.

- [ ] **Step 1: Write the failing tests**

Append to `elixir/test/symphony_elixir/project_secrets_test.exs`, inside the module:

```elixir
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
```

- [ ] **Step 2: Run them (fail)**

Run: `mix test test/symphony_elixir/project_secrets_test.exs -k "update_project_secrets"`
Expected: FAIL — `function SymphonyElixir.Storage.update_project_secrets/2 is undefined`.

- [ ] **Step 3: Implement**

In `elixir/lib/symphony_elixir/storage.ex`, add (near `get_project_by_slug/1`):

```elixir
  @spec update_project_secrets(Project.t(), map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def update_project_secrets(%Project{} = project, params) do
    changes =
      %{}
      |> put_secret_change(params, :forge_secret, "forge_secret", "clear_forge_secret")
      |> put_secret_change(params, :tracker_secret, "tracker_secret", "clear_tracker_secret")

    project
    |> Project.secret_changeset(changes)
    |> Repo.update()
  end

  defp put_secret_change(changes, params, field, value_key, clear_key) do
    cond do
      truthy_param(params, clear_key) -> Map.put(changes, field, nil)
      present_value(params, value_key) -> Map.put(changes, field, fetch_param(params, value_key))
      true -> changes
    end
  end

  defp truthy_param(params, key), do: fetch_param(params, key) in [true, "true"]

  defp present_value(params, key) do
    case fetch_param(params, key) do
      v when is_binary(v) -> String.trim(v) != ""
      _ -> false
    end
  end

  defp fetch_param(params, key), do: Map.get(params, key) || Map.get(params, String.to_atom(key))
```

- [ ] **Step 4: Run them (pass)**

Run: `mix test test/symphony_elixir/project_secrets_test.exs -k "update_project_secrets"`
Expected: PASS (all 5).

- [ ] **Step 5: Commit**

```bash
git add lib/symphony_elixir/storage.ex test/symphony_elixir/project_secrets_test.exs
git commit -m "feat(creds): Storage.update_project_secrets with set/clear/preserve"
```

---

## Task 5: ProjectCreds — forge-secret resolution

**Files:**
- Modify: `elixir/lib/symphony_elixir/forge/project_creds.ex`
- Modify: `elixir/test/symphony_elixir/project_creds_test.exs`

- [ ] **Step 1: Write the failing tests**

Append to `elixir/test/symphony_elixir/project_creds_test.exs`, inside the module:

```elixir
  test "creds/2 prefers a project's forge_secret over env" do
    System.put_env("GITHUB_TOKEN", "env-tok")
    on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

    creds = ProjectCreds.creds(%SymphonyElixir.Storage.Project{forge_type: "github", forge_secret: "proj-tok"})
    assert creds.token == "proj-tok"
  end

  test "creds/2 falls back to env when a project has no secret" do
    System.put_env("GITHUB_TOKEN", "env-tok")
    on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

    creds = ProjectCreds.creds(%SymphonyElixir.Storage.Project{forge_type: "github", forge_secret: nil})
    assert creds.token == "env-tok"
  end
```

And add a DB-backed test for the run-based lookup. Change the test module's first line if needed so a repo checkout is available; this test sets its own tag:

```elixir
  @tag :db
  test "creds/2 resolves a WorkRun's token by forge owner+repo" do
    :ok = SymphonyElixir.TestSupport.checkout_repo(%{})

    {:ok, project} =
      SymphonyElixir.Storage.upsert_project(%{
        slug: "portal", linear_project_slug: "p", linear_team_key: "COD",
        linear_human_review_state: "Human Review", forge_type: "github",
        forge_owner: "dezet", forge_repo: "portal", forge_base_branch: "main",
        config_version: 1, config: %{}
      })

    {:ok, _} = SymphonyElixir.Storage.update_project_secrets(project, %{"forge_secret" => "run-tok"})

    run = %SymphonyElixir.Storage.WorkRun{forge_type: "github", forge_owner: "dezet", forge_repo: "portal"}
    assert ProjectCreds.creds(run).token == "run-tok"
  end
```

> Note: `project_creds_test.exs` uses `use ExUnit.Case, async: false`. The `@tag :db` test needs the sandbox; `SymphonyElixir.TestSupport.checkout_repo/1` performs the checkout explicitly, so no case change is required. If the checkout helper is unavailable in `ExUnit.Case`, change the module's `use` line to `use SymphonyElixir.TestSupport` (which wraps `ExUnit.Case`).

- [ ] **Step 2: Run them (fail)**

Run: `mix test test/symphony_elixir/project_creds_test.exs`
Expected: FAIL — the new assertions fail because `creds/2` still reads only env.

- [ ] **Step 3: Implement resolution**

In `elixir/lib/symphony_elixir/forge/project_creds.ex`, replace `forge_token/1`:

```elixir
  defp forge_token(project_or_run) do
    secret = map_get(project_or_run, :forge_secret) || lookup_secret(project_or_run)

    if is_binary(secret) and secret != "" do
      secret
    else
      env_token(map_get(project_or_run, :forge_type))
    end
  end

  # A full Project already had its chance via :forge_secret; only run/maps look up.
  defp lookup_secret(%SymphonyElixir.Storage.Project{}), do: nil

  defp lookup_secret(run) do
    with owner when is_binary(owner) <- map_get(run, :forge_owner),
         repo when is_binary(repo) <- map_get(run, :forge_repo),
         %{forge_secret: secret} <- SymphonyElixir.Storage.get_project_by_github(owner, repo) do
      secret
    else
      _ -> nil
    end
  end

  defp env_token("gitlab"), do: System.get_env("GITLAB_TOKEN")
  defp env_token(_), do: System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")
```

- [ ] **Step 4: Run them (pass)**

Run: `mix test test/symphony_elixir/project_creds_test.exs`
Expected: PASS (existing 2 + new 3). The existing gitlab test (plain map, no owner/repo → `lookup_secret` returns nil → env) still passes.

- [ ] **Step 5: Commit**

```bash
git add lib/symphony_elixir/forge/project_creds.ex test/symphony_elixir/project_creds_test.exs
git commit -m "feat(creds): resolve forge token from project secret with env fallback"
```

---

## Task 6: Controller — accept secrets, write-only output

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/controllers/project_controller.ex`

- [ ] **Step 1: Write the failing tests**

Append to `elixir/test/symphony_elixir/project_api_test.exs`, inside the module (it already has `@valid`, `json_post/2`, `json_put/2`):

```elixir
  @tag :db
  test "create accepts a forge_secret but never echoes it" do
    :ok = checkout_repo(%{})

    conn = json_post("/api/v1/projects", Map.put(@valid, "forge_secret", "ghp_tok"))
    body = json_response(conn, 201)
    refute Map.has_key?(body["project"], "forge_secret_value")
    assert body["project"]["forge_secret"] == "set"
    assert body["project"]["tracker_secret"] == "unset"
    refute body["project"] |> Map.values() |> Enum.member?("ghp_tok")
  end

  @tag :db
  test "clear flag removes a stored secret" do
    :ok = checkout_repo(%{})
    %{"project" => %{"id" => id}} = json_response(json_post("/api/v1/projects", Map.put(@valid, "forge_secret", "ghp_tok")), 201)

    body = json_response(json_put("/api/v1/projects/#{id}", Map.put(@valid, "clear_forge_secret", true)), 200)
    assert body["project"]["forge_secret"] == "unset"
  end
```

- [ ] **Step 2: Run them (fail)**

Run: `mix test test/symphony_elixir/project_api_test.exs -k "secret or clear flag"`
Expected: FAIL — `forge_secret` is `nil`/missing in the response and the secret is never persisted.

- [ ] **Step 3: Implement**

In `elixir/lib/symphony_elixir_web/controllers/project_controller.ex`:

Add the secret keys to `@permitted` so they are not dropped (they are handled separately, not passed to `project_attrs`):

```elixir
  @secret_params ~w(forge_secret tracker_secret clear_forge_secret clear_tracker_secret)
```

Change `create/2` and `update/2` to apply secrets after the upsert:

```elixir
  def create(conn, params) do
    with {:ok, project} <- Storage.upsert_project(project_attrs(params)),
         {:ok, project} <- apply_secrets(project, params) do
      conn |> put_status(:created) |> json(%{project: project_json(project)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, _existing} <- fetch_project(id),
         {:ok, project} <- Storage.upsert_project(project_attrs(params)),
         {:ok, project} <- apply_secrets(project, params) do
      json(conn, %{project: project_json(project)})
    end
  end

  defp apply_secrets(project, params) do
    if Enum.any?(@secret_params, &Map.has_key?(params, &1)) do
      Storage.update_project_secrets(project, Map.take(params, @secret_params))
    else
      {:ok, project}
    end
  end
```

Add the write-only indicators to `project_json/1` (append inside the map):

```elixir
      forge_secret: secret_state(p.forge_secret),
      tracker_secret: secret_state(p.tracker_secret),
```

And a private helper:

```elixir
  defp secret_state(nil), do: "unset"
  defp secret_state(_), do: "set"
```

- [ ] **Step 4: Run them (pass)**

Run: `mix test test/symphony_elixir/project_api_test.exs`
Expected: PASS (existing project API tests + 2 new).

- [ ] **Step 5: Commit**

```bash
git add lib/symphony_elixir_web/controllers/project_controller.ex test/symphony_elixir/project_api_test.exs
git commit -m "feat(creds): write-only secret params + set|unset in project API"
```

---

## Task 7: Presenter — set|unset in project summary

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex:20-31`

- [ ] **Step 1: Write the failing test**

Append to `elixir/test/symphony_elixir/project_secrets_test.exs`, inside the module:

```elixir
  describe "presenter never leaks a secret value" do
    alias SymphonyElixir.Storage.Project
    alias SymphonyElixirWeb.Presenter

    test "summary exposes set|unset, not the value" do
      project = %Project{slug: "p", forge_owner: "o", forge_repo: "r", forge_base_branch: "main", forge_secret: "ghp_tok", tracker_secret: nil}
      payload = Presenter.project_summary_payload(project, nil, [])
      refute payload |> inspect() |> String.contains?("ghp_tok")
      assert get_in(payload, [:project, :forge_secret]) == "set"
      assert get_in(payload, [:project, :tracker_secret]) == "unset"
    end
  end
```

> If `project_summary_payload/3` requires a non-nil snapshot, pass the minimal snapshot the other presenter tests in `presenter_projections_test.exs` use; check that file for the exact shape and mirror it.

- [ ] **Step 2: Run it (fail)**

Run: `mix test test/symphony_elixir/project_secrets_test.exs -k "presenter"`
Expected: FAIL — `forge_secret` key absent from the payload.

- [ ] **Step 3: Implement**

In `elixir/lib/symphony_elixir_web/presenter.ex`, inside the `project:` map built by `project_summary_payload/3` (the block at lines 29-31 with `github_owner: project.forge_owner` etc.), add:

```elixir
        forge_secret: secret_state(project.forge_secret),
        tracker_secret: secret_state(project.tracker_secret),
```

And add a private helper at the bottom of the module:

```elixir
  defp secret_state(nil), do: "unset"
  defp secret_state(_), do: "set"
```

- [ ] **Step 4: Run it (pass)**

Run: `mix test test/symphony_elixir/project_secrets_test.exs -k "presenter"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/symphony_elixir_web/presenter.ex test/symphony_elixir/project_secrets_test.exs
git commit -m "feat(creds): expose set|unset in project summary presenter"
```

---

## Task 8: Frontend — secret field in Configuration form

**Files:**
- Modify: the project form component under `elixir/assets/src/` (locate with `grep -rl "github_repo\|github_base_branch" elixir/assets/src`).

> The SPA already round-trips `github_owner`/`github_repo`/etc. through the project form. Mirror that wiring for two password inputs.

- [ ] **Step 1: Locate the form and read it**

Run: `grep -rln "github_base_branch\|github_repo" elixir/assets/src`
Read the matched component to learn its field-binding pattern (state keys, the submit payload assembly, how the API response populates the form).

- [ ] **Step 2: Add the secret inputs**

For each of forge and tracker, add to the form (matching the component's existing input style):
- A `<input type="password">` bound to a local state key (`forgeSecret`, `trackerSecret`), placeholder shows the server `set|unset` value (e.g. label "Forge token — currently: set").
- A "Clear" checkbox/button bound to `clearForgeSecret` / `clearTrackerSecret`.

On submit, include in the POST/PUT body only when non-empty:
- `forge_secret` when `forgeSecret` is non-empty,
- `clear_forge_secret: true` when the clear control is checked,
- same for tracker.

Never read a secret value back from the API (the server returns only `set|unset`); show that indicator as the field's current-state label.

- [ ] **Step 3: Build the assets**

Run (from `elixir/assets`): `npm install` then `npm run build` (or the project's configured build — check `elixir/assets/package.json` scripts).
Expected: build succeeds.

- [ ] **Step 4: Run the SPA tests**

Run (from `elixir/`): `mix test -k "spa or SPA"` (or the project's SPA e2e tag).
Expected: the 4 SPA tests that need a built frontend now pass (they fail without a build).

- [ ] **Step 5: Commit**

```bash
git add elixir/assets
git commit -m "feat(creds): secret token fields in project configuration form"
```

---

## Task 9: Ops doc + full-suite green

**Files:**
- Create: `docs/operations/credential-key.md`

- [ ] **Step 1: Write the ops note**

Create `docs/operations/credential-key.md`:

```markdown
# Credential Encryption Key (`CLOAK_KEY`)

Per-project forge and tracker secrets are encrypted at rest with AES-256-GCM
(`SymphonyElixir.Vault`). The key is read from the `CLOAK_KEY` environment
variable at boot in **every** environment — a missing key crashes startup
(fail-fast, by design). There is no unencrypted mode.

## Generating a key

    openssl rand -base64 32   # 32 bytes, Base64-encoded

Store it in your secret manager / process env. It must NOT live in the repo.

## Tests / CI

CI and local test runs must export a key. A fresh per-run key is fine — the
test DB is sandboxed and nothing encrypted persists between runs:

    export CLOAK_KEY="$(openssl rand -base64 32)"

## Rotation

The vault is configured as a cipher list, so rotation is additive:
1. Add the new key as `default` and keep the old key under a second tag.
2. Re-save each project's secrets (decrypts with old, re-encrypts with new).
3. Remove the old key.

## Loss

If `CLOAK_KEY` is lost, stored secrets are unrecoverable. Projects fall back to
the global env tokens (`GITHUB_TOKEN` / `GITLAB_TOKEN` / `LINEAR_API_KEY`)
until re-entered.
```

- [ ] **Step 2: Run the full suite**

Run (from `elixir/`, with `CLOAK_KEY` exported and the `harmony-postgres` podman container up): `mix test`
Expected: PASS — entire suite green, including the new credential tests.

- [ ] **Step 3: Sanity — no secret leaks in JSON**

Run: `mix test -k "echo or leak or set|unset"`
Expected: PASS — the write-only assertions confirm no secret value is ever serialized.

- [ ] **Step 4: Commit**

```bash
git add docs/operations/credential-key.md
git commit -m "docs(creds): CLOAK_KEY management and rotation ops note"
```

---

## Self-Review notes (for the executor)

- **Spec coverage:** Vault+fail-fast (T1, spec §1), columns/migration (T2, §2), encrypted fields (T3, §2), set/clear/preserve + sync-safe (T4, §4/§5), forge resolution + run lookup (T5, §3), write-only API (T6, §4), presenter no-leak (T7, §4), form field (T8, §4), key ops + rotation (T9, spec §Security/Risks). Tracker resolution is intentionally **not** wired (spec Decision #2 / Out of scope).
- **Type consistency:** `secret_changeset/2`, `update_project_secrets/2`, `secret_state/1`, `lookup_secret/1`, `env_token/1` are the only new names and are used exactly as defined.
- **Fail-fast caveat:** every `mix` command that boots the app needs `CLOAK_KEY`; this is stated in the header and Task 9.
```
