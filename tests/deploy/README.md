# Deploying seed-server (Apache + systemd)

> This page covers a **standalone seed-only host** (no PXE) — Apache here
> (`seed-server.conf`) proxies `/seed/` and denies everything else.
>
> For a **combined PXE provisioner** (the usual case), run
> [`scripts/bootstrap-provisioner.sh`](../../scripts/bootstrap-provisioner.sh):
> it stands up the same seed app + systemd unit, but installs the combined
> [`pxe/apache-provisioner.conf.example`](../../pxe/apache-provisioner.conf.example) vhost
> instead — one that also serves the static PXE assets (`/boot.ipxe`,
> `/ubuntu/<ver>/…`) from `/var/www/html`. Use the locked-down
> `seed-server.conf` below only when the host serves seeds and nothing else.

LAN-only, plain-HTTP testing deployment. Apache reverse-proxies `:80 → 127.0.0.1:8080`, where a Python `http.server` daemon serves cloud-init `user-data` / `meta-data` / `secret` keyed by MAC.

## Layout on the host

```
/opt/cf-mesh/
  seed-server.py            (from scripts/seed-server.py in this repo)
  cloud-init/user-data.tpl  (from cloud-init/user-data.tpl in this repo)
/etc/seed-server.env        (filled from deploy/seed-server.env.example)
/etc/systemd/system/seed-server.service   (= deploy/seed-server.service)
/etc/apache2/sites-available/seed-server.conf  (= deploy/seed-server.conf)
```

## Install

```bash
# 1. Dedicated system user (no shell, no home)
sudo useradd --system --no-create-home --shell /usr/sbin/nologin seed-server

# 2. Drop the app
sudo mkdir -p /opt/cf-mesh/cloud-init
sudo cp scripts/seed-server.py             /opt/cf-mesh/
sudo cp cloud-init/user-data.tpl           /opt/cf-mesh/cloud-init/
sudo chown -R root:root /opt/cf-mesh
sudo chmod 0755 /opt/cf-mesh /opt/cf-mesh/cloud-init
sudo chmod 0644 /opt/cf-mesh/seed-server.py /opt/cf-mesh/cloud-init/user-data.tpl

# 3. Env file
sudo cp deploy/seed-server.env.example /etc/seed-server.env
sudo chown root:seed-server /etc/seed-server.env
sudo chmod 0640 /etc/seed-server.env
sudoedit /etc/seed-server.env    # fill in S3_*, ANSIBLE_SSH_PUBKEY, (optional) AWS_*

# 4. systemd unit
sudo cp deploy/seed-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now seed-server

# 5. Apache
sudo a2enmod proxy proxy_http
sudo cp deploy/seed-server.conf /etc/apache2/sites-available/
sudo a2ensite seed-server
sudo systemctl reload apache2
```

## Smoke test

```bash
# Local (loopback)
curl -sS http://localhost/seed/aa-bb-cc-00-00-0a/meta-data

# From another host on the same LAN
curl -sS http://<server-ip>/seed/aa-bb-cc-00-00-0a/meta-data
```

Expected: `instance-id: <site-name>\nlocal-hostname: <site-name>\n` for a MAC that exists in the TF state, `404` otherwise.

## Operate

| Action | Command |
|---|---|
| Restart Python only | `sudo systemctl restart seed-server` |
| Reload Apache config | `sudo systemctl reload apache2` |
| Tail Python logs | `sudo journalctl -u seed-server -f` |
| Tail Apache access | `sudo tail -f /var/log/apache2/seed-access.log` |
| Tail Apache errors | `sudo tail -f /var/log/apache2/seed-error.log` |
| Adjust cache TTL | edit `/etc/seed-server.env`, set `CACHE_TTL=…`, then `systemctl restart seed-server` |
| Force cache refresh | `systemctl restart seed-server` (clears in-memory cache) |

## Common troubles

- **`403` from Apache** — your client IP isn't in the `Require ip` list. Edit `/etc/apache2/sites-available/seed-server.conf`, add the CIDR, `systemctl reload apache2`.
- **`502` / `503` from Apache** — the Python daemon isn't up. `systemctl status seed-server`; check `journalctl -u seed-server` for the traceback (usually a missing `S3_BUCKET` / `S3_KEY` in `/etc/seed-server.env` or invalid AWS creds).
- **`404` for a known MAC** — TF state was updated but cache hasn't expired. Either wait `CACHE_TTL` seconds or `systemctl restart seed-server`.
- **`500` with `missing data for <site>: '<VAR>'`** — your template uses a `{{VAR}}` whose value isn't set in `/etc/seed-server.env`. Add it and restart.

## Going to TLS later

When you have a cert:

1. `sudo a2enmod ssl`
2. Add a `<VirtualHost *:443>` block to `seed-server.conf` mirroring the `*:80` block plus `SSLEngine on` + cert paths
3. Optionally redirect `*:80` → `*:443`
4. `systemctl reload apache2`

No change needed to the Python daemon or systemd unit.
