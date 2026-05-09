#!/usr/bin/env bash
# Print site inventory from terraform-cloudflare-infra state as TSV:
#   site_name<TAB>connector_ip<TAB>private_hostname<TAB>cidr<TAB>environment
# Tokens are NOT printed here — use scripts/fetch-warp-token.sh to retrieve.
#
# usage: inventory-from-tf.sh [tf-dir]

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=../scripts/lib/tf-state.sh
. "$SCRIPT_DIR/../scripts/lib/tf-state.sh"

tf_site_inventory_json "$@" | jq -r '
  to_entries[]
  | [.key, .value.connector_ip, .value.private_hostname, .value.cidr, .value.environment]
  | @tsv
'
