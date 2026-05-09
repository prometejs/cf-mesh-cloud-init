# Setup — already-installed OS

You have a Linux host that's already running and reachable via SSH. You
don't want to reinstall. cloud-init still works as long as you can reach
it from a sudo shell.

## Approach

`scripts/post-install-apply.sh`:

1. Installs `cloud-init` if missing (apt only).
2. Drops your rendered user-data into `/etc/cloud/cloud.cfg.d/99-cf-cloud-init.cfg`.
3. Runs `cloud-init clean --logs` to clear the per-instance state.
4. Re-runs the four cloud-init phases (`init --local`, `init`, `modules
   --mode=config`, `modules --mode=final`).

The result is identical to a fresh boot from a NoCloud seed.

## Steps

```bash
# 1. Render on your workstation
HOSTNAME=site-a \
ANSIBLE_SSH_PUBKEY="$(cat ~/.ssh/ansible.pub)" \
SECRETS_MODE=baked \
WARP_TUNNEL_TOKEN="$(./scripts/fetch-warp-token.sh site-a)" \
  ./scripts/render-userdata.sh > /tmp/site-a.cfg

# 2. Ship to the host
scp /tmp/site-a.cfg                       you@host:/tmp/cf.cfg
scp scripts/post-install-apply.sh         you@host:/tmp/cf-apply.sh

# 3. Apply
ssh you@host 'sudo bash /tmp/cf-apply.sh /tmp/cf.cfg'

# 4. Verify
ssh ansible@host 'cloud-init status --long && warp-cli --accept-tos status'
```

## Caveats

- **The runcmd `shred` step deletes the source files** under `/etc/cf-cloud-init/`,
  so the rendered cfg is fine to leave in `/etc/cloud/cloud.cfg.d/` afterwards.
- If the host already has a different ansible user / authorized_keys, the
  cloud-config will *add* the listed key — it does not strip existing keys.
- `cloud-init clean` removes per-instance state; if the host was previously
  configured by a different cloud-config (e.g. it came from a cloud image),
  some of that may re-run. Inspect `/etc/cloud/cloud.cfg.d/` before applying.
- **WARP already running?** `cf-install-warp` checks the marker file +
  `warp-cli status`. Re-running on an already-registered host is a no-op.
