#!/usr/bin/env bash
# Idempotent fleet provisioner. Reads sites from terraform-cloudflare-infra
# state and renders + ships a NoCloud seed (or applies post-install) per site.
#
# Idempotency contract:
#   A host is considered provisioned if /var/lib/cf-cloud-init/warp.registered
#   exists AND `warp-cli status` returns success. Such hosts are SKIPPED.
#   Pass --force <site> to re-provision a specific site anyway.
#
# Modes:
#   --mode seed-iso          Build a NoCloud ISO per site under $OUT_DIR
#   --mode post-install      SSH to each connector_ip and run post-install
#                            (requires the host to be reachable via SSH already)
#
# usage: fleet-provision.sh --mode <seed-iso|post-install> [--force <site>]
#                           [--out-dir <dir>] [--tf-dir <dir>]
#                           [--ssh-user ansible] [--ssh-key ~/.ssh/ansible]

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
# shellcheck source=../scripts/lib/tf-state.sh
. "$REPO_DIR/scripts/lib/tf-state.sh"

MODE=""
FORCE_SITES=()
OUT_DIR="$REPO_DIR/build/seeds"
TF_DIR_ARG=""
SSH_USER="ansible"
SSH_KEY=""
ANSIBLE_SSH_PUBKEY="${ANSIBLE_SSH_PUBKEY:-}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --mode) MODE=$2; shift 2 ;;
    --force) FORCE_SITES+=("$2"); shift 2 ;;
    --out-dir) OUT_DIR=$2; shift 2 ;;
    --tf-dir) TF_DIR_ARG=$2; shift 2 ;;
    --ssh-user) SSH_USER=$2; shift 2 ;;
    --ssh-key) SSH_KEY=$2; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ "$MODE" == "seed-iso" || "$MODE" == "post-install" ]] || {
  echo "fleet-provision: --mode must be seed-iso or post-install" >&2; exit 2
}
[[ -n "$ANSIBLE_SSH_PUBKEY" ]] || {
  echo "fleet-provision: \$ANSIBLE_SSH_PUBKEY must be set (path or value)" >&2; exit 2
}
# Allow ANSIBLE_SSH_PUBKEY to be a path
if [[ -f "$ANSIBLE_SSH_PUBKEY" ]]; then
  ANSIBLE_SSH_PUBKEY=$(cat "$ANSIBLE_SSH_PUBKEY")
fi

is_forced() {
  local s=$1
  for f in "${FORCE_SITES[@]:-}"; do [[ "$f" == "$s" ]] && return 0; done
  return 1
}

# Returns 0 if the host is already provisioned (skip), 1 if not (proceed).
host_already_provisioned() {
  local host=$1
  [[ -n "$SSH_KEY" ]] || return 1
  local ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -i "$SSH_KEY")
  ssh "${ssh_opts[@]}" "${SSH_USER}@${host}" \
    'test -f /var/lib/cf-cloud-init/warp.registered && warp-cli --accept-tos status' \
    >/dev/null 2>&1
}

inv=$(tf_site_inventory_json ${TF_DIR_ARG:+"$TF_DIR_ARG"})

mkdir -p "$OUT_DIR"

echo "$inv" | jq -r 'to_entries[] | [.key, .value.connector_ip, .value.tunnel_token] | @tsv' \
| while IFS=$'\t' read -r site host token; do
  echo ">>> $site ($host)"

  if [[ "$MODE" == "post-install" ]] && ! is_forced "$site" \
     && host_already_provisioned "$host"; then
    echo "    SKIP: already provisioned (marker present, warp-cli status ok)"
    continue
  fi

  rendered="$OUT_DIR/$site.user-data"
  HOSTNAME=$site \
  ANSIBLE_SSH_PUBKEY=$ANSIBLE_SSH_PUBKEY \
  SECRETS_MODE=baked \
  WARP_TUNNEL_TOKEN=$token \
    "$REPO_DIR/scripts/render-userdata.sh" > "$rendered"
  echo "    rendered: $rendered"

  case "$MODE" in
    seed-iso)
      iso="$OUT_DIR/$site.iso"
      "$REPO_DIR/scripts/make-seed-iso.sh" "$rendered" "$iso"
      ;;
    post-install)
      ssh_opts=(-o StrictHostKeyChecking=accept-new -i "$SSH_KEY")
      scp "${ssh_opts[@]}" "$rendered" "${SSH_USER}@${host}:/tmp/cf-cloud-init.cfg"
      scp "${ssh_opts[@]}" "$REPO_DIR/scripts/post-install-apply.sh" \
        "${SSH_USER}@${host}:/tmp/cf-post-install.sh"
      ssh "${ssh_opts[@]}" "${SSH_USER}@${host}" \
        "sudo bash /tmp/cf-post-install.sh /tmp/cf-cloud-init.cfg && rm -f /tmp/cf-cloud-init.cfg /tmp/cf-post-install.sh"
      ;;
  esac
  echo "    done: $site"
done

echo "fleet-provision: complete"
