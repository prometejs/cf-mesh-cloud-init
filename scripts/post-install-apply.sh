#!/usr/bin/env bash
# Apply a rendered cloud-config to a host with Linux already installed.
#
# Usage: post-install-apply.sh <rendered-cloud-config>

set -euo pipefail

CFG=${1:-}
[[ -n "$CFG" && -f "$CFG" ]] || { echo "usage: $0 <rendered-cloud-config>" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "must be root" >&2; exit 1; }
command -v cloud-init >/dev/null || { echo "cloud-init not installed" >&2; exit 1; }

install -m 0644 "$CFG" /etc/cloud/cloud.cfg.d/99-cf-mesh.cfg
cloud-init clean --logs
cloud-init init --local
cloud-init init
cloud-init modules --mode=config
cloud-init modules --mode=final
