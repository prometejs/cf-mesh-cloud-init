# cf-cloud-init

Cloud-init (`NoCloud` datasource) for provisioning Linux hosts that join a
Cloudflare Zero Trust network as **WARP Connectors**. Targets bare metal and
VMs. The user-data installs the WARP Connector, registers it as a systemd
service, hardens SSH, and creates an `ansible` user with authorized keys so
downstream configuration management can take over.

Companion to [`terraform-cloudflare-infra`](../terraform-cloudflare-infra) —
that repo creates the tunnel and emits the per-site `tunnel_token`; this repo
delivers that token to the host at first boot.

## What it does

At first boot the rendered user-data:

1. Updates apt, installs base packages (`curl`, `gnupg`, `jq`, `openssh-server`).
2. Creates the `ansible` user, adds authorized SSH keys, grants passwordless
   sudo.
3. Hardens `sshd` (no password auth, no root login).
4. Installs the Cloudflare WARP Connector from `pkg.cloudflareclient.com`.
5. Fetches the WARP `tunnel_token` (mode-dependent: baked, HTTP, or Vault).
6. Registers the connector (`warp-cli connector new <token>`) and enables
   `warp-svc`.
7. Reports completion via cloud-init's standard exit signal.

## Repo layout

```
.
├── cloud-init/
│   ├── user-data.tpl              # Main NoCloud user-data template
│   ├── meta-data.tpl              # NoCloud meta-data template
│   ├── modules/                   # Composable cloud-config snippets
│   └── examples/                  # Pre-rendered scenarios
├── scripts/
│   ├── render-userdata.sh         # Render template → user-data
│   ├── make-seed-iso.sh           # Build NoCloud CIDATA ISO
│   ├── fetch-warp-token.sh        # Pull tunnel_token from TF state / Vault
│   └── post-install-apply.sh      # Run on already-installed OS
├── orchestration/
│   ├── inventory-from-tf.sh       # Read terraform-cloudflare-infra state
│   └── fleet-provision.sh         # Idempotent fleet driver
├── pxe/                           # dnsmasq / iPXE samples
├── docs/                          # Setup guides per scenario
└── .github/workflows/validate.yml # cloud-init schema + yaml + shell linting
```

## Quick start (VirtualBox dev)

```bash
# Render user-data with your inputs
WARP_TUNNEL_TOKEN="$(cat ~/.warp-tokens/dev-site-a)" \
ANSIBLE_SSH_PUBKEY="$(cat ~/.ssh/ansible.pub)" \
HOSTNAME="dev-site-a" \
  ./scripts/render-userdata.sh > /tmp/user-data

# Build a NoCloud seed ISO
./scripts/make-seed-iso.sh /tmp/user-data /tmp/seed.iso

# Attach /tmp/seed.iso as a CD/DVD to your Ubuntu 22.04+ VM and boot
```

Full walkthrough: [docs/setup-virtualbox.md](docs/setup-virtualbox.md).

## Provisioning modes

| Scenario | Guide | When to use |
|---|---|---|
| VirtualBox VM | [setup-virtualbox.md](docs/setup-virtualbox.md) | Dev / iteration |
| PXE + dnsmasq + iPXE | [setup-pxe.md](docs/setup-pxe.md) | Bare metal, you control the LAN |
| Already-installed OS | [post-install.md](docs/post-install.md) | Existing host, can't reinstall |
| netboot.xyz | [setup-netbootxyz.md](docs/setup-netbootxyz.md) | Bare metal, no PXE infra of your own |
| MAAS | [setup-maas.md](docs/setup-maas.md) | Fleet, full lifecycle, you run the LAN |
| Tinkerbell | [setup-tinkerbell.md](docs/setup-tinkerbell.md) | Fleet, K8s-native, declarative |

## Secrets

Three modes are supported. See [docs/secrets.md](docs/secrets.md).

- `baked` — `tunnel_token` rendered into user-data at build time. Simplest.
  Acceptable for dev seed ISOs that you control end-to-end.
- `http` — user-data fetches the token from a one-shot URL at first boot
  using a short-lived enrollment token passed via kernel cmdline or
  metadata. Recommended for PXE.
- `vault` — user-data authenticates to HashiCorp Vault (AppRole or JWT) and
  reads the token from a KV path. Recommended for fleet / production.

## Orchestration

[`orchestration/`](orchestration/) reads `terraform-cloudflare-infra` state,
enumerates sites, and drives provisioning. The driver is **idempotent** — a
host already registered as a WARP Connector (verified via `warp-cli status`
and a marker file) is skipped, never reconfigured. Override with
`--force <site>` if you mean it.

See [docs/orchestration.md](docs/orchestration.md).

## Validation

PRs run `.github/workflows/validate.yml`:

- `cloud-init schema --config-file` against every rendered example
- `yamllint` over `cloud-init/`
- `shellcheck` over `scripts/` and `orchestration/`
- `bash -n` syntax check on rendered user-data fragments

## License

MIT — see [LICENSE](LICENSE).
