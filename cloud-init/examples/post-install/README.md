# Example: post-install (existing OS)

For a host that's already running Linux you don't need a NoCloud seed at all.
Use `scripts/post-install-apply.sh` to drop a rendered cloud-config into
`/etc/cloud/cloud.cfg.d/` and trigger the modules manually.

```bash
HOSTNAME=site-a \
ANSIBLE_SSH_PUBKEY="$(cat ~/.ssh/ansible.pub)" \
SECRETS_MODE=baked \
WARP_TUNNEL_TOKEN="$(cat ~/.warp/site-a)" \
  ../../../scripts/render-userdata.sh > /tmp/site-a.cfg

scp /tmp/site-a.cfg root@host:/tmp/cf.cfg
ssh root@host /path/to/post-install-apply.sh /tmp/cf.cfg
```

See `docs/post-install.md`.
