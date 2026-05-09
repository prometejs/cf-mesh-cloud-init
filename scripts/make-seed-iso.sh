#!/usr/bin/env bash
# Build a NoCloud seed ISO from a rendered user-data file.
# usage: make-seed-iso.sh <user-data> <out.iso> [meta-data]
#
# If meta-data is omitted, a minimal one is generated from $(basename <out.iso>).
# Requires one of: xorriso, genisoimage, mkisofs.

set -euo pipefail

USER_DATA=${1:?usage: $0 <user-data> <out.iso> [meta-data]}
OUT_ISO=${2:?usage: $0 <user-data> <out.iso> [meta-data]}
META_DATA=${3:-}

[[ -f "$USER_DATA" ]] || { echo "user-data not found: $USER_DATA" >&2; exit 1; }

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

cp "$USER_DATA" "$workdir/user-data"

if [[ -n "$META_DATA" ]]; then
  cp "$META_DATA" "$workdir/meta-data"
else
  iid=$(basename "$OUT_ISO" .iso)
  cat > "$workdir/meta-data" <<EOF
instance-id: $iid-$(date +%s)
local-hostname: $iid
EOF
fi

mkdir -p "$(dirname "$OUT_ISO")"

if command -v xorriso >/dev/null; then
  xorriso -as mkisofs -joliet -rock -volid CIDATA \
    -output "$OUT_ISO" "$workdir" >/dev/null
elif command -v genisoimage >/dev/null; then
  genisoimage -output "$OUT_ISO" -volid CIDATA -joliet -rock \
    "$workdir/user-data" "$workdir/meta-data" >/dev/null 2>&1
elif command -v mkisofs >/dev/null; then
  mkisofs -output "$OUT_ISO" -volid CIDATA -joliet -rock \
    "$workdir/user-data" "$workdir/meta-data" >/dev/null 2>&1
else
  echo "need one of: xorriso, genisoimage, mkisofs" >&2
  exit 1
fi

echo "wrote $OUT_ISO"
