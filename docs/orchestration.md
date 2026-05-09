# Orchestration

Drives provisioning across the fleet defined in `terraform-cloudflare-infra`
state — read the canonical site list from there, render per-site user-data,
ship the seed.

## Reading state

`terraform-cloudflare-infra` exposes the per-site bag at
`output.site_inventory`:

```hcl
output "site_inventory" {
  value = {
    for name, site in module.site : name => {
      tunnel_id        = site.tunnel_id
      tunnel_token     = site.tunnel_token       # the secret we need
      cidr             = site.site_cidr
      connector_ip     = site.connector_ip
      private_hostname = site.private_hostname
      environment      = terraform.workspace
    }
  }
  sensitive = true
}
```

`scripts/lib/tf-state.sh` wraps `terraform output -json site_inventory` and
provides:

| function | returns |
|---|---|
| `tf_site_inventory_json [tf-dir]` | full inventory as JSON |
| `tf_site_names`                   | list of site names |
| `tf_site_token <site>`            | tunnel_token for one site |
| `tf_site_field <site> <field>`    | arbitrary field |

These helpers shell out to `terraform` so they always reflect the latest
state. Pass the terraform repo path explicitly or let it default to
`../../terraform-cloudflare-infra` relative to this repo.

## Driver: `orchestration/fleet-provision.sh`

Two modes:

```bash
# A) Build per-site seed ISOs (no host contact needed)
ANSIBLE_SSH_PUBKEY=~/.ssh/ansible.pub \
  ./orchestration/fleet-provision.sh --mode seed-iso

# B) Apply post-install over SSH to running hosts (idempotent)
ANSIBLE_SSH_PUBKEY=~/.ssh/ansible.pub \
  ./orchestration/fleet-provision.sh --mode post-install \
    --ssh-key ~/.ssh/ansible
```

## Idempotency contract

A host is considered already provisioned IFF both:

1. `/var/lib/cf-cloud-init/warp.registered` marker file exists, AND
2. `warp-cli --accept-tos status` succeeds.

When both hold:

- **post-install mode** skips the host entirely. No state is touched.
- **seed-iso mode** still rebuilds the ISO (it's offline; whether the ISO
  is consumed is up to whoever boots the host).

Override the skip with `--force <site>` (repeatable).

## Why not let cloud-init handle idempotency?

cloud-init keys idempotency on `instance-id`. If you keep the same
`instance-id` across reboots, cloud-init won't re-run modules — but that's
brittle (any `cloud-init clean` re-arms it, and post-install bumps it
deliberately). The marker + `warp-cli status` check is independent of
cloud-init's bookkeeping, which is what makes it safe to run the
orchestrator repeatedly without worrying about replays.

## Future: ansible inventory hand-off

`terraform-cloudflare-infra` already publishes `ansible_host` resources
into state for the `cloud.terraform.terraform_provider` inventory plugin.
Once a host is past cloud-init, the same inventory drives
[`ansible-cloudflare-infra`](../../ansible-cloudflare-infra) for day-2
config. Provisioning order:

```
terraform apply  →  this repo (cloud-init: WARP + ssh)  →  ansible (day-2)
```

The hand-off point is the `ansible` user with the authorized public key
this repo's user-data installs.

## Secret backends in fleet mode

`fleet-provision.sh` currently renders with `SECRETS_MODE=baked`,
fetching the token from terraform state and embedding it. For a tighter
contract, set `SECRETS_MODE=vault` upstream of the driver and reshape the
loop to populate `VAULT_*` instead — the renderer doesn't care which mode
the driver picks per-site.
