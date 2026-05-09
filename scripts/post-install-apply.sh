#!/usr/bin/env bash
# Apply a rendered cloud-config to a host that already has Linux installed.
# usage: post-install-apply.sh <rendered-cloud-config>
#
# Run this on the target host as root. It places the config in
# /etc/cloud/cloud.cfg.d/ and re-runs cloud-init's per-instance modules.

set -euo pipefail

CFG=${1:?usage: $0 <rendered-cloud-config>}
[[ -f "$CFG" ]] || { echo "config not found: $CFG" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "must be root" >&2; exit 1; }

if ! command -v cloud-init >/dev/null; then
  if command -v apt-get >/dev/null; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y cloud-init
  else
    echo "cloud-init not installed and no apt-get available; install it manually" >&2
    exit 1
  fi
fi

install -m 0644 "$CFG" /etc/cloud/cloud.cfg.d/99-cf-cloud-init.cfg

# Force re-run of per-instance modules. cloud-init keys idempotency on
# instance-id; bumping it via a clean ensures modules execute again.
cloud-init clean --logs
cloud-init init --local
cloud-init init
cloud-init modules --mode=config
cloud-init modules --mode=final

echo "post-install apply complete; check 'cloud-init status --long'"
