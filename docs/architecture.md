# Architecture

## Datasource: NoCloud

We use cloud-init's [NoCloud][nc] datasource because the targets are bare
metal and VMs — there is no cloud provider metadata service. NoCloud reads
`user-data` and `meta-data` (and optionally `network-config`) from one of:

| Source | Form | Used for |
|---|---|---|
| `CIDATA` filesystem | ISO9660 / vfat volume labelled `CIDATA` | VirtualBox, attached as a CD/DVD |
| Kernel cmdline | `ds=nocloud-net;s=http://host/path/` | PXE / iPXE bare metal |
| Local seed dir | `/var/lib/cloud/seed/nocloud/` | Post-install on already-running OS |

[nc]: https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html

## End-to-end flow

```
                 ┌───────────────────────────┐
                 │ terraform-cloudflare-infra│   creates per-site
                 │  outputs.site_inventory   │   tunnels and tokens
                 └─────────────┬─────────────┘
                               │ tunnel_token (sensitive)
                               ▼
        ┌──────────────────────────────────────────┐
        │ scripts/render-userdata.sh                │
        │   substitutes {{VAR}} placeholders        │
        │   in cloud-init/user-data.tpl             │
        └─────────────┬─────────────────────────────┘
                      │ rendered user-data
                      ▼
   ┌───────────────────────────────────────────────────────┐
   │ Delivery (pick one):                                  │
   │   • make-seed-iso.sh → CIDATA ISO  (VirtualBox)       │
   │   • served via HTTP for ds=nocloud-net (PXE)          │
   │   • dropped into /etc/cloud/cloud.cfg.d (post-install)│
   └─────────────┬─────────────────────────────────────────┘
                 │ first boot / re-run
                 ▼
   ┌───────────────────────────────────────────────────────┐
   │ Host                                                  │
   │   1. apt update + base packages                       │
   │   2. ansible user + authorized_keys + sudo            │
   │   3. sshd hardened (no password, no root)             │
   │   4. install cloudflare-warp                          │
   │   5. cf-fetch-secret  →  tunnel_token                 │
   │   6. warp-cli connector new <token>                   │
   │   7. warp-cli connect; touch warp.registered marker   │
   │   8. shred secrets.env + baked-token                  │
   └───────────────────────────────────────────────────────┘
```

## Idempotency

`/usr/local/sbin/cf-install-warp` checks
`/var/lib/cf-cloud-init/warp.registered` AND `warp-cli status`. If both
hold, the install/register block exits early. cloud-init itself keys per
`instance-id` on `/var/lib/cloud/instances/<id>` — bumping the instance-id
(or running `cloud-init clean`) re-runs the modules.

The fleet driver mirrors this at the orchestration layer: it SSHes to each
host and skips any host whose marker + `warp-cli status` both pass.

## What is NOT in this repo

- **WARP tunnel resources.** Created by
  [`terraform-cloudflare-infra`](../../terraform-cloudflare-infra). This
  repo only consumes its outputs.
- **Day-2 host configuration.** Handled by
  [`ansible-cloudflare-infra`](../../ansible-cloudflare-infra) (or whatever
  Ansible repo you point at the ansible user this repo creates). cloud-init
  ends with a working SSH listener and a privileged ansible user — Ansible
  takes it from there.
