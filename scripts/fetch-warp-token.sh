#!/usr/bin/env bash
# Pull a tunnel_token for a given site from terraform-cloudflare-infra state.
# usage: fetch-warp-token.sh <site-name> [tf-dir]
#
# Default tf-dir is ../../terraform-cloudflare-infra relative to this repo.
# Requires terraform CLI and a configured backend (AWS creds for the S3 backend).

set -euo pipefail

SITE=${1:?usage: $0 <site-name> [tf-dir]}
TF_DIR=${2:-${TF_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../terraform-cloudflare-infra" 2>/dev/null && pwd || true)}}

if [[ -z "${TF_DIR:-}" || ! -d "$TF_DIR" ]]; then
  echo "fetch-warp-token: terraform dir not found; pass it as arg 2 or set TF_DIR" >&2
  exit 1
fi

cd "$TF_DIR"
terraform output -json site_inventory \
  | jq -er --arg s "$SITE" '.[$s].tunnel_token // empty' \
  || { echo "site '$SITE' not found in site_inventory" >&2; exit 1; }
