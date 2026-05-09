# Example: PXE bare metal (HTTP secret fetch)

For a PXE-booted host the NoCloud datasource is loaded over HTTP via the
kernel cmdline `ds=nocloud-net;s=http://<seed-host>/<host-id>/`. The seed
directory contains rendered `user-data` and `meta-data` keyed by host.

Render the user-data with `SECRETS_MODE=http` so the host fetches its
`tunnel_token` from a one-shot endpoint at first boot:

```bash
HOSTNAME=site-a \
ANSIBLE_SSH_PUBKEY="$(cat ~/.ssh/ansible.pub)" \
SECRETS_MODE=http \
SECRET_FETCH_URL="https://secrets.internal/warp/site-a?nonce=$(uuidgen)" \
SECRET_FETCH_AUTH_HEADER="Authorization: Bearer $(cat enrollment.token)" \
  ../../../scripts/render-userdata.sh > /srv/seed/site-a/user-data
```

See `pxe/` and `docs/setup-pxe.md` for the boot infrastructure.
