# Setup — Tinkerbell

[Tinkerbell][tb] is a CNCF bare-metal provisioner: declarative `Workflow`
CRDs in Kubernetes describe boot + image + cloud-init handoff per host.
Originally built at Equinix Metal.

[tb]: https://tinkerbell.org/

## When to use it

- You already run Kubernetes and want bare-metal lifecycle in the same
  control plane (GitOps for hardware).
- You need pluggable boot flows (multiple OS images, custom phases).
- You want declarative re-provisioning (delete the Workflow, re-create).

## When *not* to use it

- Single-machine dev — too much overhead vs a seed ISO.
- You don't run Kubernetes today and don't want to start.

## Wiring cf-cloud-init into Tinkerbell

Tinkerbell's `Template` step `cloud-init` (or a generic `kexec`/`actions`
template) writes user-data into the target's filesystem before the first
boot. Render with `SECRETS_MODE=vault` and reference the rendered file from
your Template's `image` action.

```yaml
# Template excerpt
tasks:
  - name: cloud-init-seed
    actions:
      - name: write-userdata
        image: quay.io/tinkerbell-actions/writefile:latest
        environment:
          DEST_PATH: /var/lib/cloud/seed/nocloud-net/user-data
          CONTENTS: |
            ...rendered cf-cloud-init user-data here...
          UID: "0"
          GID: "0"
          MODE: "0600"
          DIRMODE: "0700"
```

## Advantages

- **GitOps.** Your fleet definition lives in YAML alongside other K8s
  resources — review via PR, apply via Argo/Flux.
- **Pluggable.** Action images are containers; build your own steps.
- **Multi-tenant friendly.** Workflows are scoped per-target.

## Trade-offs

| Concern | DIY PXE | Tinkerbell |
|---|---|---|
| Prerequisites | dnsmasq+nginx | K8s + Smee + Hegel + Tink + Rufio |
| Mental model | Bash + cmdline | CRDs + actions + workflows |
| Power management | DIY | Rufio (IPMI/Redfish) |
| Debuggability | Two services | A handful of K8s controllers |

## Pointer

Full install: <https://docs.tinkerbell.org/latest/>. The Helm chart is the
fastest way in.
