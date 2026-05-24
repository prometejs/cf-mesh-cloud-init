#!/usr/bin/env bash
# Render cloud-init/user-data.tpl to stdout. Every {{VAR}} placeholder is
# replaced with $VAR from the environment; missing/empty values error.
#
# Usage:  set -a; . tests/fixtures/ci.env; set +a
#         ./scripts/render-template.sh > /tmp/rendered.cfg

set -euo pipefail

TEMPLATE=${TEMPLATE:-$(dirname -- "${BASH_SOURCE[0]}")/../cloud-init/user-data.tpl}
[[ -f "$TEMPLATE" ]] || { echo "template not found: $TEMPLATE" >&2; exit 1; }

content=$(<"$TEMPLATE")
for v in $(grep -oE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$TEMPLATE" | tr -d '{}' | sort -u || true); do
  [[ -n "${!v:-}" ]] || { echo "missing env var: \$$v" >&2; exit 1; }
  content=${content//"{{${v}}}"/${!v}}
done
printf '%s\n' "$content"
