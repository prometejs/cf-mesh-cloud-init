#!/usr/bin/env bash
# Local lint runner — mirrors what CI does. Run from anywhere.
# Currently shellcheck-only; will gain back schema validation once the
# seed-server flow has its own test harness.
set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)
cd "$REPO"

fail=0

echo "==> shellcheck"
if command -v shellcheck >/dev/null; then
  shellcheck -x scripts/*.sh scripts/lib/*.sh scripts/orchestration/*.sh \
    || fail=1
else
  echo "    (shellcheck not installed; skipping)"
fi

if [[ $fail -eq 0 ]]; then echo "all checks passed"; fi
exit "$fail"
