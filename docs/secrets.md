# Secrets

The only secret each host needs at provisioning time is its WARP
`tunnel_token`. This repo supports three delivery modes — pick by setting
`SECRETS_MODE` when rendering.

## `baked` — embed the token in user-data

The token is rendered into `/etc/cf-cloud-init/baked-token` inside the
user-data. After registration the file is `shred`-deleted by `runcmd`.

Pros: zero runtime dependencies.
Cons: token sits in user-data on disk (and on the seed ISO) until shredded.
Use for: dev VMs you control end-to-end, throwaway VirtualBox setups.

```bash
HOSTNAME=site-a \
ANSIBLE_SSH_PUBKEY="$(cat ~/.ssh/ansible.pub)" \
SECRETS_MODE=baked \
WARP_TUNNEL_TOKEN="$(./scripts/fetch-warp-token.sh site-a)" \
  ./scripts/render-userdata.sh > /tmp/user-data
```

## `http` — fetch from a one-shot URL at first boot

The user-data carries only a fetch URL (and optional bearer header). At
boot the host calls the URL, expects a JSON response of the form
`{"tunnel_token": "..."}`, and feeds that to `warp-cli`.

Pros: token never lives on the seed media.
Cons: requires a network endpoint that authenticates the host.
Use for: PXE bare metal where the seed is served over HTTP anyway.

Suggested patterns:

- **Per-host nonce** in the URL path; endpoint marks it consumed on first
  successful read.
- **Short-lived enrollment token** as a `Bearer` header, signed with a key
  you trust (e.g. signed cookie, JWT with 10-minute TTL).

```bash
HOSTNAME=site-a \
ANSIBLE_SSH_PUBKEY="$(cat ~/.ssh/ansible.pub)" \
SECRETS_MODE=http \
SECRET_FETCH_URL="https://secrets.internal/warp/site-a?nonce=$(uuidgen)" \
SECRET_FETCH_AUTH_HEADER="Authorization: Bearer $(cat enrollment.token)" \
  ./scripts/render-userdata.sh > /srv/seed/site-a/user-data
```

## `vault` — read from HashiCorp Vault KV v2

The host authenticates to Vault and reads the token from a KV v2 path. Two
auth methods are supported in the embedded `cf-fetch-secret`:

| Auth | Required vars | When |
|---|---|---|
| AppRole | `VAULT_ROLE_ID`, `VAULT_SECRET_ID` | Generic; rotate the secret_id externally |
| JWT     | `VAULT_JWT_ROLE`, `VAULT_JWT_PATH` (path to file with the JWT) | Cloud-init can ship a one-time JWT on the seed |

Pros: integrates with your existing secret store; auditable; token rotation
through Vault, not the seed pipeline.
Cons: requires Vault reachable from the booting host's network.
Use for: production fleets, repeatable provisioning.

Expected KV v2 layout (v2 → `data.data.tunnel_token`):

```bash
vault kv put kv/warp/site-a tunnel_token="eyJ..."
```

```bash
HOSTNAME=site-a \
ANSIBLE_SSH_PUBKEY="$(cat ~/.ssh/ansible.pub)" \
SECRETS_MODE=vault \
VAULT_ADDR="https://vault.internal:8200" \
VAULT_KV_PATH="kv/data/warp/site-a" \
VAULT_ROLE_ID="$(cat ~/.vault/site-a.role_id)" \
VAULT_SECRET_ID="$(cat ~/.vault/site-a.secret_id)" \
  ./scripts/render-userdata.sh > /tmp/user-data
```

### Vault Agent (alternative)

If you prefer not to embed Vault auth credentials in user-data at all, run
[Vault Agent][va] on a sidecar / bastion that templates the token onto a
filesystem the host can read at first boot (NFS, HTTP). Then use
`SECRETS_MODE=http` pointing at the templated URL — the host stays naive.

[va]: https://developer.hashicorp.com/vault/docs/agent

## What about cloud-init `vault://` URLs?

cloud-init does not natively resolve Vault URLs in user-data. Anything that
looks like first-class Vault support in cloud-init is actually a custom
script you wire in — exactly the role `cf-fetch-secret` plays here. Keeping
the resolver as a single bash script (rather than a Python plugin) keeps the
attack surface visible and the dependencies trivial.

## Hygiene

- `secrets.env` and `baked-token` are deleted via `shred -u` in `runcmd`
  after registration succeeds.
- `cloud-init clean --logs` is recommended before turning a provisioned VM
  into a template — it strips `/var/lib/cloud/instances/<id>/user-data.txt`
  which would otherwise retain the rendered (possibly token-bearing)
  user-data.
- Never commit rendered user-data to the repo. `.gitignore` excludes
  `rendered/`, `secrets/`, `*.iso`.
