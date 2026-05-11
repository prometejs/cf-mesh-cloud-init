#!/usr/bin/env bash
# scripts/render-userdata.sh
#
# Render cloud-init/user-data.tpl to stdout. Auto-detects every {{VAR}}
# placeholder in the template and substitutes from the environment.
#
# Inputs: each placeholder {{VAR}} must have a non-empty $VAR exported in
# the calling environment, e.g.:
#     set -a; . tests/fixtures/ci.env; set +a
#     ./scripts/render-userdata.sh > /tmp/rendered.cfg
#
# Optional:
#   TEMPLATE  override template path (default: ../cloud-init/user-data.tpl)
#
# Placeholder grammar: {{ + [A-Z_][A-Z0-9_]* + }}

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
TEMPLATE="${TEMPLATE:-$SCRIPT_DIR/../cloud-init/user-data.tpl}"

[[ -f "$TEMPLATE" ]] || {
  echo "render-userdata: template not found: $TEMPLATE" >&2
  exit 1
}

content=$(cat -- "$TEMPLATE")

while IFS= read -r v; do
  if [[ -z "${!v:-}" ]]; then
    echo "render-userdata: \$$v is required (template uses {{$v}})" >&2
    exit 1
  fi
  val=${!v}
  if [[ "$val" == *$'\n'* ]]; then
    echo "render-userdata: \$$v contains a newline; values must be single-line" >&2
    exit 1
  fi
  content=${content//"{{${v}}}"/$val}
done < <(grep -oE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$TEMPLATE" \
          | sed -E 's/\{\{//; s/\}\}//' \
          | sort -u)

printf '%s\n' "$content"