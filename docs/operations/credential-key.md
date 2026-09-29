# Credential Encryption Key (`CLOAK_KEY`)

Per-project forge and tracker secrets and the secrets of the intake connections (Jira API token, SMTP
password, SMSAPI token) are encrypted at rest with AES-256-GCM (`SymphonyElixir.Vault`). The key is read
from the `CLOAK_KEY` environment variable at boot in **every** environment — a missing key or a value
that is not Base64 crashes startup (fail-fast, by design). There is no unencrypted mode.

## Generating a key

`CLOAK_KEY` is exactly 32 bytes, Base64-encoded:

```bash
openssl rand -base64 32
```

Store it in your secret manager / process env. It must NOT live in the repo. A string that is not the
Base64 form of 32 bytes is not a key: for example 64 characters `k` decode to 48 bytes, and encryption
with them fails.

## Tests / CI

CI and local test runs must export a key. A fresh per-run key is fine — the test DB is sandboxed and
nothing encrypted persists between runs:

```bash
export CLOAK_KEY="$(openssl rand -base64 32)"
```

A fixed, clearly synthetic test key also works, as long as it encodes 32 bytes:

```bash
export CLOAK_KEY="$(python3 -c 'import base64; print(base64.b64encode(b"k" * 32).decode())')"
```

Never use a test key outside tests, and never print a real key in logs or reports.

## Backup

Back up `CLOAK_KEY` in the secret manager, separately from the database dumps. A dump contains only
ciphertext, and it can be restored only together with the key that encrypted it.

## Rotation

The vault currently loads one cipher (`default`, tag `AES.GCM.V1`) from `CLOAK_KEY`. Rotation is not a
configuration-only change yet: replacing the value in the environment makes every stored secret
unreadable. A rotation needs a release that also loads the old key as a second, retired cipher. Then:

1. Back up the database and the old key.
2. Deploy with the new key as `default` and the old key as the retired cipher.
3. Re-save each project's secrets and each intake connection's secret (decrypts with the old key,
   re-encrypts with the new one), or re-enter them.
4. Confirm that the connection tests pass, then remove the old key.

Rotating a provider credential (Jira, SMTP, SMSAPI, forge or tracker token) is independent of
`CLOAK_KEY`; see [Secret Rotation](../harmony-operations.md#secret-rotation).

## Loss

If `CLOAK_KEY` is lost, stored secrets are unrecoverable. Projects fall back to the global env tokens
(`GITHUB_TOKEN` / `GITLAB_TOKEN` / `LINEAR_API_KEY`) until re-entered. Intake connections have no
fallback: enter their secrets again and rerun the connection tests.
