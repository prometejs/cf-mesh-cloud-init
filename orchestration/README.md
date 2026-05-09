# orchestration/

Drives provisioning across the fleet defined by
`terraform-cloudflare-infra` state. Two ways to use it:

## Read-only inventory

```bash
./inventory-from-tf.sh
# site-a  10.10.0.1  site-a.warp.example  10.10.0.0/24  dev
# site-b  10.10.1.1  site-b.warp.example  10.10.1.0/24  dev
```

Tokens are deliberately omitted from this output; pull individually via
`scripts/fetch-warp-token.sh <site>`.

## Idempotent fleet provisioning

```bash
# Build per-site seed ISOs under build/seeds/
ANSIBLE_SSH_PUBKEY=~/.ssh/ansible.pub \
  ./fleet-provision.sh --mode seed-iso

# Apply to already-running hosts via SSH (skips already-provisioned ones)
ANSIBLE_SSH_PUBKEY=~/.ssh/ansible.pub \
  ./fleet-provision.sh --mode post-install \
    --ssh-key ~/.ssh/ansible

# Force-replay one site
... --mode post-install --force site-a
```

### Idempotency

A host is considered already provisioned if BOTH:

- `/var/lib/cf-cloud-init/warp.registered` marker exists, AND
- `warp-cli --accept-tos status` returns success.

In `post-install` mode the driver SSHes in to check; if both conditions hold,
the site is skipped entirely. Passing `--force <site>` overrides the check.

In `seed-iso` mode the check is not applicable (you're producing media for a
fresh install); ISOs are always rebuilt for every site under `--out-dir`.
