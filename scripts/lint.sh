#!/usr/bin/env bash
# Local lint runner — mirrors what CI does.
# Validates rendered cloud-init, yamllint, shellcheck. Run from repo root.
# can be used as a pre-commit hook or run manually before pushing changes.
set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)
cd "$REPO"

fail=0

echo "==> shellcheck"
if command -v shellcheck >/dev/null; then
  shellcheck -x scripts/*.sh scripts/lib/*.sh orchestration/*.sh tests/*.sh \
    || fail=1
else
  echo "    (shellcheck not installed; skipping)"
fi

echo "==> render + parse + bash -n"
shopt -s nullglob
for f in tests/fixtures/*.env; do
  echo "    fixture: $f"
  ( set -a; . "$f"; set +a; ./scripts/render-userdata.sh ) > /tmp/rendered.cfg
  python3 -c 'import yaml,sys; yaml.safe_load(open("/tmp/rendered.cfg"))' \
    || { echo "FAIL: yaml parse"; fail=1; continue; }
  rm -rf /tmp/cfscripts && mkdir -p /tmp/cfscripts
  ./tests/extract-scripts.py /tmp/rendered.cfg /tmp/cfscripts >/dev/null \
    || { echo "FAIL: extract"; fail=1; continue; }
  for s in /tmp/cfscripts/*; do
    bash -n "$s" || { echo "FAIL: bash -n $s"; fail=1; }
  done
done

echo "==> yamllint hand-written examples"
if command -v yamllint >/dev/null; then
  yamllint -d '{extends: default, rules: {line-length: disable, document-start: disable, comments: disable, indentation: {spaces: 2, indent-sequences: true}}}' \
    cloud-init/examples/virtualbox-dev/user-data \
    || fail=1
else
  echo "    (yamllint not installed; skipping)"
fi

echo "==> cloud-init schema"
if command -v cloud-init >/dev/null; then
  for f in tests/fixtures/*.env; do
    ( set -a; . "$f"; set +a; ./scripts/render-userdata.sh ) > /tmp/rendered.cfg
    cloud-init schema --config-file /tmp/rendered.cfg \
      || { echo "FAIL: schema $f"; fail=1; }
  done
else
  echo "    (cloud-init not installed; skipping)"
fi

if [[ $fail -eq 0 ]]; then echo "all checks passed"; fi
exit "$fail"
