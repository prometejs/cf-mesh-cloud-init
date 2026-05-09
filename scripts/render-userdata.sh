#!/usr/bin/env bash
# Render cloud-init/user-data.tpl to stdout.
# Substitutes only the {{VAR}} placeholders listed below — shell ${...} in
# embedded scripts is left untouched.
#
# Required env: HOSTNAME, ANSIBLE_SSH_PUBKEY, SECRETS_MODE
# Mode-specific env (rest default to empty):
#   baked: WARP_TUNNEL_TOKEN
#   http : SECRET_FETCH_URL [SECRET_FETCH_AUTH_HEADER]
#   vault: VAULT_ADDR VAULT_KV_PATH (VAULT_ROLE_ID+VAULT_SECRET_ID | VAULT_JWT_ROLE+VAULT_JWT_PATH)
#
# Values must be single-line.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
TEMPLATE="${TEMPLATE:-$SCRIPT_DIR/../cloud-init/user-data.tpl}"

VARS=(
  HOSTNAME
  ANSIBLE_SSH_PUBKEY
  SECRETS_MODE
  WARP_TUNNEL_TOKEN
  SECRET_FETCH_URL
  SECRET_FETCH_AUTH_HEADER
  VAULT_ADDR
  VAULT_KV_PATH
  VAULT_ROLE_ID
  VAULT_SECRET_ID
  VAULT_JWT_ROLE
  VAULT_JWT_PATH
)

require() {
  local v=$1
  if [[ -z "${!v:-}" ]]; then
    echo "render-userdata: \$$v is required" >&2
    exit 1
  fi
}

require HOSTNAME
require ANSIBLE_SSH_PUBKEY
require SECRETS_MODE

case "$SECRETS_MODE" in
  baked) require WARP_TUNNEL_TOKEN ;;
  http)  require SECRET_FETCH_URL ;;
  vault)
    require VAULT_ADDR
    require VAULT_KV_PATH
    if [[ -z "${VAULT_ROLE_ID:-}" || -z "${VAULT_SECRET_ID:-}" ]]; then
      if [[ -z "${VAULT_JWT_ROLE:-}" || -z "${VAULT_JWT_PATH:-}" ]]; then
        echo "render-userdata: vault mode needs AppRole or JWT auth vars" >&2
        exit 1
      fi
    fi
    ;;
  *) echo "render-userdata: SECRETS_MODE must be baked|http|vault" >&2; exit 1 ;;
esac

content=$(cat -- "$TEMPLATE")

for v in "${VARS[@]}"; do
  val=${!v:-}
  if [[ "$val" == *$'\n'* ]]; then
    echo "render-userdata: \$$v contains a newline; values must be single-line" >&2
    exit 1
  fi
  placeholder="{{${v}}}"
  content=${content//"$placeholder"/$val}
done

printf '%s\n' "$content"
