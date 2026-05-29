#!/usr/bin/env bash
# One-shot bootstrap for a cf-mesh provisioner host (Debian/Ubuntu).
#
# Stands up the full PXE provisioning stack in one run:
#   - dnsmasq  : authoritative DHCP + TFTP (chainloads iPXE)
#   - apache2  : reverse-proxy fronting the seed server, LAN-restricted
#   - seed-server.py : hardened systemd service rendering cloud-init per MAC
#
# Automates the union of pxe/SETUP.md and tests/deploy/README.md. Idempotent:
# safe to re-run. Run as root, from a checkout/tarball of this repo.
#
# Usage:
#   sudo ./scripts/bootstrap-provisioner.sh \
#     --iface enp1s0 --ip 10.0.10.10 \
#     --dhcp-range 10.0.10.50,10.0.10.150,12h \
#     --s3-bucket BUCKET --s3-key path/to/terraform.tfstate --s3-region eu-west-2 \
#     --ssh-pubkey "ssh-ed25519 AAAA... ansible@fleet"
#
# Required: --iface --ip --dhcp-range --s3-bucket --s3-key --ssh-pubkey
# Optional: --gateway (default: --ip) --dns (default: 1.1.1.1,1.0.0.1)
#           --s3-region --ubuntu-version (default: 22.04) --assume-yes -h|--help
#
# AWS credentials are NOT passed as flags (they would leak into the process
# list). Provide them via an EC2 instance role or ~seed-server/.aws/credentials.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

IFACE=; IP=; DHCP_RANGE=; GATEWAY=; DNS=1.1.1.1,1.0.0.1
S3_BUCKET=; S3_KEY=; S3_REGION=; SSH_PUBKEY=
UBUNTU_VERSION=22.04; ASSUME_YES=0

APP_DIR=/opt/cf-mesh
SEED_USER=seed-server
SEED_ENV=/etc/seed-server.env
TFTP_ROOT=/srv/tftp
WWW_ROOT=/var/www/html

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

die() { echo "error: $*" >&2; exit 2; }

require() { [[ -n "${!1}" ]] || die "--${2} is required"; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --iface)          IFACE=$2;          shift 2 ;;
    --ip)             IP=$2;             shift 2 ;;
    --dhcp-range)     DHCP_RANGE=$2;     shift 2 ;;
    --gateway)        GATEWAY=$2;        shift 2 ;;
    --dns)            DNS=$2;            shift 2 ;;
    --s3-bucket)      S3_BUCKET=$2;      shift 2 ;;
    --s3-key)         S3_KEY=$2;         shift 2 ;;
    --s3-region)      S3_REGION=$2;      shift 2 ;;
    --ssh-pubkey)     SSH_PUBKEY=$2;     shift 2 ;;
    --ubuntu-version) UBUNTU_VERSION=$2; shift 2 ;;
    --assume-yes|-y)  ASSUME_YES=1;      shift ;;
    -h|--help)        usage; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

# ---- 1. Preflight --------------------------------------------------------
[[ $EUID -eq 0 ]] || die "must run as root"
command -v apt-get >/dev/null || die "this script targets Debian/Ubuntu (apt-get not found)"

require IFACE iface
require IP ip
require DHCP_RANGE dhcp-range
require S3_BUCKET s3-bucket
require S3_KEY s3-key
require SSH_PUBKEY ssh-pubkey
GATEWAY=${GATEWAY:-$IP}

for f in scripts/seed-server.py cloud-init/user-data.tpl \
         tests/deploy/seed-server.service tests/deploy/seed-server.conf; do
  [[ -f "$REPO_ROOT/$f" ]] || die "expected repo asset missing: $f (run from a repo checkout)"
done

if [[ $ASSUME_YES -ne 1 ]]; then
  echo "WARNING: about to enable an AUTHORITATIVE DHCP server on '$IFACE'"
  echo "         (range $DHCP_RANGE). On a shared LAN this can hand out leases"
  echo "         and disrupt other hosts. Only proceed on an isolated"
  echo "         provisioning VLAN."
  read -r -p "Type 'yes' to continue: " reply
  [[ "$reply" == "yes" ]] || die "aborted"
fi

echo "==> Bootstrapping provisioner: ip=$IP iface=$IFACE ubuntu=$UBUNTU_VERSION"

# ---- 2. Packages ---------------------------------------------------------
# awscli here is v1 (Ubuntu universe) — fine for `aws s3 cp`. For v2 use the
# official installer (awscli-exe) instead.
echo "==> Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y dnsmasq apache2 ipxe python3 awscli jq cloud-init

# ---- 3. Seed app ---------------------------------------------------------
echo "==> Installing seed app to $APP_DIR"
id "$SEED_USER" &>/dev/null || \
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SEED_USER"
install -d -m0755 -o root -g root "$APP_DIR" "$APP_DIR/cloud-init"
install -m0644 "$REPO_ROOT/scripts/seed-server.py"        "$APP_DIR/seed-server.py"
install -m0644 "$REPO_ROOT/cloud-init/user-data.tpl"      "$APP_DIR/cloud-init/user-data.tpl"

# ---- 4. Seed env ---------------------------------------------------------
echo "==> Writing $SEED_ENV"
install -m0640 -o root -g "$SEED_USER" /dev/null "$SEED_ENV"
cat > "$SEED_ENV" <<EOF
# Managed by bootstrap-provisioner.sh — edit and 'systemctl restart seed-server'.
S3_BUCKET=$S3_BUCKET
S3_KEY=$S3_KEY
S3_REGION=$S3_REGION
ANSIBLE_SSH_PUBKEY=$SSH_PUBKEY
BIND_HOST=127.0.0.1
BIND_PORT=8080
CACHE_TTL=120
INVENTORY_KEY=site_inventory.value
EOF
chown root:"$SEED_USER" "$SEED_ENV"
chmod 0640 "$SEED_ENV"

# ---- 5. systemd ----------------------------------------------------------
echo "==> Installing systemd unit"
install -m0644 "$REPO_ROOT/tests/deploy/seed-server.service" \
  /etc/systemd/system/seed-server.service
systemctl daemon-reload
systemctl enable --now seed-server

# ---- 6. Apache -----------------------------------------------------------
echo "==> Configuring Apache reverse-proxy"
a2enmod proxy proxy_http
install -m0644 "$REPO_ROOT/tests/deploy/seed-server.conf" \
  /etc/apache2/sites-available/seed-server.conf
a2ensite seed-server
a2dissite 000-default 2>/dev/null || true

# ---- 7. TFTP / iPXE ------------------------------------------------------
echo "==> Loading iPXE binaries into $TFTP_ROOT"
install -d -m0755 "$TFTP_ROOT"
install -m0644 /usr/lib/ipxe/undionly.kpxe "$TFTP_ROOT/"
[[ -f /usr/lib/ipxe/ipxe.efi ]] && install -m0644 /usr/lib/ipxe/ipxe.efi "$TFTP_ROOT/"

# ---- 8. dnsmasq config ---------------------------------------------------
# Reference: pxe/dnsmasq.conf.example (kept in sync by hand).
echo "==> Writing /etc/dnsmasq.d/pxe.conf"
cat > /etc/dnsmasq.d/pxe.conf <<EOF
# Managed by bootstrap-provisioner.sh
interface=$IFACE
bind-interfaces
domain-needed
bogus-priv

dhcp-range=$DHCP_RANGE
dhcp-option=3,$GATEWAY
dhcp-option=6,$DNS

enable-tftp
tftp-root=$TFTP_ROOT

# Tag iPXE clients (DHCP option 175) and detect BIOS vs UEFI.
dhcp-match=set:ipxe,175
dhcp-match=set:bios,option:client-arch,0
dhcp-match=set:uefi,option:client-arch,7
dhcp-match=set:uefi,option:client-arch,9

# Stage 1: legacy PXE -> iPXE binary. Stage 2: iPXE -> HTTP boot script.
dhcp-boot=tag:!ipxe,tag:bios,undionly.kpxe
dhcp-boot=tag:!ipxe,tag:uefi,ipxe.efi
dhcp-boot=tag:ipxe,http://$IP/boot.ipxe

log-dhcp
EOF
systemctl enable dnsmasq

# ---- 9. HTTP root / boot.ipxe -------------------------------------------
# Reference: pxe/boot.ipxe.example (kept in sync by hand).
echo "==> Writing $WWW_ROOT/boot.ipxe"
install -d -m0755 "$WWW_ROOT"
cat > "$WWW_ROOT/boot.ipxe" <<EOF
#!ipxe
# Managed by bootstrap-provisioner.sh
set base http://$IP/ubuntu/$UBUNTU_VERSION
set seed http://$IP/seed/\${mac:hexhyp}/

kernel \${base}/vmlinuz \\
  initrd=initrd \\
  ip=dhcp \\
  url=\${base}/ubuntu-$UBUNTU_VERSION-live-server-amd64.iso \\
  autoinstall \\
  ds=nocloud-net;s=\${seed} \\
  cloud-config-url=\${seed}user-data \\
  ---
initrd \${base}/initrd
boot
EOF

# ---- 10. ISO verify (no download) ---------------------------------------
ISO_DIR="$WWW_ROOT/ubuntu/$UBUNTU_VERSION"
if [[ -f "$ISO_DIR/vmlinuz" && -f "$ISO_DIR/initrd" ]] && \
   compgen -G "$ISO_DIR/*.iso" >/dev/null; then
  echo "==> ISO boot files present under $ISO_DIR"
else
  echo "WARNING: Ubuntu boot files missing under $ISO_DIR"
  echo "         Stage them before PXE-booting targets, e.g.:"
  echo "           sudo mkdir -p $ISO_DIR"
  echo "           sudo mount -o loop ubuntu-$UBUNTU_VERSION-live-server-amd64.iso /mnt"
  echo "           sudo cp -r /mnt/* $ISO_DIR/"
  echo "           sudo umount /mnt"
fi

# ---- 11. Restart + smoke test -------------------------------------------
echo "==> Restarting services"
systemctl restart dnsmasq
systemctl restart apache2

for svc in dnsmasq apache2 seed-server; do
  if systemctl is-active --quiet "$svc"; then
    echo "    $svc: active"
  else
    echo "    $svc: NOT active — check 'journalctl -u $svc'" >&2
  fi
done

code=$(curl -s -o /dev/null -w '%{http_code}' \
  http://localhost/seed/aa-bb-cc-00-00-0a/meta-data || true)
case "$code" in
  200|404) echo "    seed stack healthy (HTTP $code from loopback)" ;;
  *)       echo "    seed stack UNHEALTHY (HTTP $code) — check 'journalctl -u seed-server'" >&2 ;;
esac

# ---- 12. Summary ---------------------------------------------------------
cat <<EOF

==> Done.
    seed app   : $APP_DIR/seed-server.py
    seed env   : $SEED_ENV   (S3_BUCKET=$S3_BUCKET)
    dnsmasq    : /etc/dnsmasq.d/pxe.conf  (DHCP $DHCP_RANGE on $IFACE)
    tftp root  : $TFTP_ROOT
    http root  : $WWW_ROOT  (boot.ipxe -> http://$IP/boot.ipxe)

Next steps:
  1. Ensure AWS creds are available to '$SEED_USER' (instance role or
     ~$SEED_USER/.aws/credentials) — they are NOT set by this script.
  2. Stage the Ubuntu ISO under $WWW_ROOT/ubuntu/$UBUNTU_VERSION/ if warned above.
  3. Power on a target with PXE first; watch 'journalctl -u dnsmasq -f'.
EOF
