#!/usr/bin/env bash
# Helpers for reading terraform-cloudflare-infra state.
# Source from other scripts: . scripts/lib/tf-state.sh

tf_state_default_dir() {
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../terraform-cloudflare-infra" \
    2>/dev/null && pwd
}

tf_site_inventory_json() {
  local tf_dir=${1:-${TF_DIR:-$(tf_state_default_dir)}}
  if [[ -z "$tf_dir" || ! -d "$tf_dir" ]]; then
    echo "tf-state: terraform dir not found" >&2
    return 1
  fi
  ( cd "$tf_dir" && terraform output -json site_inventory )
}

tf_site_names() {
  tf_site_inventory_json "$@" | jq -r 'keys[]'
}

tf_site_token() {
  local site=$1; shift
  tf_site_inventory_json "$@" | jq -er --arg s "$site" '.[$s].tunnel_token'
}

tf_site_field() {
  local site=$1 field=$2; shift 2
  tf_site_inventory_json "$@" | jq -er --arg s "$site" --arg f "$field" '.[$s][$f]'
}
