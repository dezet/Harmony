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
