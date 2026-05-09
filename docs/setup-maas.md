# Setup — MAAS

[Canonical MAAS][maas] (Metal-as-a-Service) treats bare metal like a cloud
provider — full lifecycle: discovery, commissioning, deploy, release. It
runs the full PXE/DHCP/DNS stack for you and exposes a REST API.

[maas]: https://maas.io/

## When to use it

- You manage 10+ bare-metal hosts and want self-service provisioning.
- You want PXE/DHCP/IPMI all behind one admin UI.
- You're already on Ubuntu and willing to run a regional + rack controller.

## When *not* to use it

- Single-host learning / hobby fleet — too heavy.
- Mixed-OS targets that aren't well-supported by MAAS images.
- You want a fully declarative, K8s-native flow — see Tinkerbell instead.

## Wiring cf-cloud-init into MAAS

MAAS [supports user-data injection][maas-curtin] at deploy time via either
the API or the CLI. Render with `SECRETS_MODE=vault` so MAAS never sees
the tunnel_token.

[maas-curtin]: https://maas.io/docs/about-cloud-init

### Per-machine deploy with rendered user-data

```bash
# Render
HOSTNAME=site-a \
ANSIBLE_SSH_PUBKEY="$(cat ~/.ssh/ansible.pub)" \
SECRETS_MODE=vault \
VAULT_ADDR=https://vault.internal:8200 \
VAULT_KV_PATH=kv/data/warp/site-a \
VAULT_ROLE_ID=$(cat ~/.vault/site-a.role_id) \
VAULT_SECRET_ID=$(cat ~/.vault/site-a.secret_id) \
  ./scripts/render-userdata.sh > /tmp/user-data

# Deploy via MAAS CLI
maas $PROFILE machine deploy <SYSTEM_ID> \
  user_data=$(base64 -w0 /tmp/user-data)
```

### Curtin late-commands (alternative)

If you'd rather have MAAS install the OS its own way and then layer this
repo's logic on top, drop the rendered user-data into
`/etc/cloud/cloud.cfg.d/99-cf-cloud-init.cfg` via a Curtin late-command and
re-run cloud-init's modules — same flow as
[post-install.md](post-install.md).

## Advantages

- **Hardware lifecycle.** MAAS can power-cycle hosts via IPMI/Redfish —
  good for failed-deploy automation.
- **Built-in DNS/DHCP/PXE.** No dnsmasq + nginx of your own.
- **Tag-based fleet selection.** Deploy by hardware tags, rack, etc.
- **REST API.** Trivially driven by terraform/ansible/CI.

## Trade-offs vs roll-your-own PXE

| Concern | DIY PXE | MAAS |
|---|---|---|
| Setup time | ~1 hour | ~half a day |
| Footprint | dnsmasq + nginx | postgres + region + rack ctlr |
| Debuggability | Logs of two services | One stack to learn |
| Hardware ops (power) | None | IPMI integration |
| Multi-arch | You wire it | Built-in |

## Pointer

Full MAAS install: <https://maas.io/docs/how-to-install-maas>. Deploy with
user-data: <https://maas.io/docs/how-to-customise-machines>.
