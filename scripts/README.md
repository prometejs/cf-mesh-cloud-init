# scripts/

Helpers for rendering, packaging, and applying cloud-init user-data, plus
fleet orchestration on top of `terraform-cloudflare-infra` state.

## Per-host scripts (`scripts/`)

| Script | What it does |
|---|---|
| [render-userdata.sh](render-userdata.sh) | Renders `cloud-init/user-data.tpl` to stdout, substituting `{{VAR}}` placeholders from the environment. |
| [make-seed-iso.sh](make-seed-iso.sh) | Packages a rendered user-data file (and an auto-generated meta-data) into a NoCloud `CIDATA` ISO for VirtualBox / hypervisor attach. Uses `xorriso` / `genisoimage` / `mkisofs`, whichever is on `$PATH`. |
| [fetch-warp-token.sh](fetch-warp-token.sh) | Pulls a single site's `tunnel_token` from `terraform-cloudflare-infra` state via `terraform output -json site_inventory`. |
| [post-install-apply.sh](post-install-apply.sh) | Applies a rendered cloud-config to a Linux host that's already installed: drops it under `/etc/cloud/cloud.cfg.d/`, runs `cloud-init clean` + the four cloud-init phases. Run on the target as root. |
| [extract-scripts.py](extract-scripts.py) | Parses a rendered cloud-config and writes each `write_files` entry whose content looks like a shell script to a directory, so lint can `bash -n` them. CI helper. |
| [seed-server.py](seed-server.py) | Sketch (non-production) Flask seed server backing the `runcmd`-driven HTTP secret fetch. Serves `/seed/<MAC>/{user-data,meta-data,secret}`: validates MAC, looks up per-machine inventory, asks Vault to wrap a role-scoped `secret-id` (5 min TTL), renders user-data via Jinja2. |
| [lib/tf-state.sh](lib/tf-state.sh) | Sourceable helpers (`tf_site_inventory_json`, `tf_site_names`, `tf_site_token`, `tf_site_field`) used by `fetch-warp-token.sh` and the orchestration driver. Not invoked directly. |

## Fleet orchestration (`orchestration/`)

Scripts focused on role in CF site to site stack

| Script | What it does |
|---|---|
| [../orchestration/inventory-from-tf.sh](../orchestration/inventory-from-tf.sh) | Prints the site inventory from `terraform-cloudflare-infra` state as TSV (`site<TAB>connector_ip<TAB>private_hostname<TAB>cidr<TAB>environment`). Tokens deliberately omitted — pull individually via `fetch-warp-token.sh`. |
| [../orchestration/fleet-provision.sh](../orchestration/fleet-provision.sh) | Idempotent fleet driver. Reads sites from TF state, renders + ships per-site user-data either as seed ISOs (`--mode seed-iso`) or via SSH post-install (`--mode post-install`). Skips any host already provisioned (marker + `warp-cli status`). Override with `--force <site>`. |

### Read-only inventory

```bash
./orchestration/inventory-from-tf.sh
# site-a  10.10.0.1  site-a.warp.example  10.10.0.0/24  dev
# site-b  10.10.1.1  site-b.warp.example  10.10.1.0/24  dev
```

### Idempotent fleet provisioning

```bash
# Build per-site seed ISOs under build/seeds/
ANSIBLE_SSH_PUBKEY=~/.ssh/ansible.pub \
  ./orchestration/fleet-provision.sh --mode seed-iso

# Apply post-install over SSH to running hosts
ANSIBLE_SSH_PUBKEY=~/.ssh/ansible.pub \
  ./orchestration/fleet-provision.sh --mode post-install \
    --ssh-key ~/.ssh/ansible

# Force-replay one site
... --mode post-install --force site-a
```

### Idempotency contract

A host is considered already provisioned IFF both:

- `/var/lib/cf-cloud-init/warp.registered` marker file exists, AND
- `warp-cli --accept-tos status` returns success.

`post-install` mode SSHes in to check; if both hold, the site is skipped
entirely. `--force <site>` (repeatable) overrides the check.

`seed-iso` mode rebuilds the ISO every run — whether it's consumed is up
to whoever boots the host.

---

Each script documents its required env / args in its own header. Run with
`bash -x` to see exactly what gets called.
