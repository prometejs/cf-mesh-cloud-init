# scripts/

Helpers for rendering, applying, and serving cloud-init user-data for the
Cloudflare WARP site-to-site mesh fleet.

## [render-template.sh](render-template.sh)

Renders `cloud-init/user-data.tpl` to stdout, replacing every `{{VAR}}`
placeholder with `$VAR` from the environment. Missing or empty values error.

- **Requires:** `bash`, `grep`
- **Variables:** one env var per `{{VAR}}` placeholder in the template;
  `TEMPLATE` (optional) overrides the template path.

```bash
set -a; . tests/fixtures/ci.env; set +a
./scripts/render-template.sh > /tmp/rendered.cfg
```

## [post-install-apply.sh](post-install-apply.sh)

Applies a rendered cloud-config to an already-installed Linux host: installs
it to `/etc/cloud/cloud.cfg.d/99-cf-mesh.cfg`, then runs `cloud-init clean`
and the four cloud-init phases (init-local, init, config, final).

- **Requires:** run as root on the target; `cloud-init` installed
- **Args:** `<rendered-cloud-config>` — path to the rendered file

```bash
sudo ./scripts/post-install-apply.sh /tmp/rendered.cfg
```

## [read-tf-state.sh](read-tf-state.sh)

Reads the `site_inventory` output from a Terraform statefile (local file or
S3) and emits it as `json`, `tsv`, or `names`. Supports filtering to one site
and masking keys.

- **Requires:** `jq`; `aws` CLI (s3 backend only)
- **Variables:** AWS creds via env / `AWS_PROFILE`; `AWS_REGION` (s3 backend,
  unless `--s3-region` given). IAM `s3:GetObject` required for s3.
- **Flags:**
  - `-b, --backend local|s3` (default: local; any `--s3-*` flag implies s3)
  - `-d, --tf-dir DIR` (local: reads `DIR/terraform.tfstate`)
  - `-u, --s3-bucket NAME` / `-k, --s3-key PATH` (s3, required)
  - `-r, --s3-region REGION` (s3, optional)
  - `-i, --inventory-key PATH` dot-path under `.outputs` (default: `site_inventory.value`)
  - `-o, --output json|tsv|names` (default: json)
  - `-s, --site NAME` filter to one site
  - `-m, --mask LIST` comma-separated keys (dot-paths) to mask as `"***"`

```bash
./scripts/read-tf-state.sh --tf-dir ../terraform-cloudflare-infra -o tsv
```

## [seed-server.py](seed-server.py)

Stdlib `http.server` NoCloud seed server. Serves cloud-init data keyed by the
booting node's primary-NIC MAC, looked up against `site_inventory[*].tags.mac`
(hyphen-lower) from Terraform state on S3 (cached). No secrets are baked into
user-data; the tunnel token is served separately.

- `GET /seed/<mac>/user-data` — rendered cloud-config
- `GET /seed/<mac>/meta-data` — instance-id + local-hostname
- `GET /seed/<mac>/secret` — `{"warp_orchestration_token": "..."}`

- **Requires:** `python3` (stdlib only); `aws` CLI; AWS creds in env
- **Variables:**
  - `S3_BUCKET`, `S3_KEY` (required)
  - `S3_REGION` (optional)
  - `INVENTORY_KEY` (default: `site_inventory.value`)
  - `BIND_HOST` (default: `0.0.0.0`), `BIND_PORT` (default: `8080`)
  - `CACHE_TTL` seconds (default: `120`)
  - `TEMPLATE` (default: `../cloud-init/user-data.tpl`)

```bash
S3_BUCKET=cf-mesh-state S3_KEY=infra/terraform.tfstate \
  ./scripts/seed-server.py
```

## [bootstrap-provisioner.sh](bootstrap-provisioner.sh)

One-shot, idempotent bootstrap for a provisioner host: installs and wires up
the full PXE stack — `dnsmasq` (authoritative DHCP + TFTP + iPXE chainload),
`apache2` (reverse-proxy fronting the seed server), and `seed-server.py` as a
hardened systemd service. Automates the union of [../pxe/SETUP.md](../pxe/SETUP.md)
and [../tests/deploy/README.md](../tests/deploy/README.md).

- **Requires:** run as root on Debian/Ubuntu; run from a checkout/tarball of
  this repo (it copies sibling assets). Installs `dnsmasq apache2 ipxe python3
  awscli jq cloud-init` itself.
- **Flags:**
  - `--iface NAME` (req) — PXE NIC for dnsmasq
  - `--ip ADDR` (req) — provisioner static IP (used in `dhcp-boot` + `boot.ipxe`)
  - `--dhcp-range START,END,LEASE` (req)
  - `--gateway ADDR` (default: `--ip`) / `--dns LIST` (default: `1.1.1.1,1.0.0.1`)
  - `--s3-bucket NAME` (req), `--s3-key PATH` (req), `--s3-region REGION`
  - `--ssh-pubkey STR` (req) — written as `ANSIBLE_SSH_PUBKEY`
  - `--ubuntu-version X.Y` (default: `22.04`)
  - `--assume-yes` skip the authoritative-DHCP confirmation prompt; `-h, --help`
- **AWS creds:** not taken as flags (would leak into the process list) — provide
  via an instance role or `~seed-server/.aws/credentials`.

The Ubuntu ISO is **not** downloaded; the script only verifies the boot files
exist under `/var/www/html/ubuntu/<ver>/` and warns if missing.

```bash
sudo ./scripts/bootstrap-provisioner.sh \
  --iface enp1s0 --ip 10.0.10.10 --dhcp-range 10.0.10.50,10.0.10.150,12h \
  --s3-bucket tf-prometejs-state-bucket \
  --s3-key cloudflare-infra/dev/terraform.tfstate --s3-region eu-west-2 \
  --ssh-pubkey "ssh-ed25519 AAAA... ansible@fleet"
```
