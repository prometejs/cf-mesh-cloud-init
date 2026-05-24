#!/usr/bin/env bash
# Read site_inventory from a Terraform statefile (local file or S3).
#
# Usage: read-tf-state.sh [OPTIONS]
#
#   -b, --backend local|s3        default: local
#   -d, --tf-dir DIR              required for local; reads DIR/terraform.tfstate
#   -u, --s3-bucket NAME          required for s3
#   -k, --s3-key PATH             required for s3
#   -r, --s3-region REGION        optional (falls back to AWS_REGION env)
#   -i, --inventory-key PATH      dot-path under .outputs (default: site_inventory.value)
#   -o, --output json|tsv|names   default: json
#   -s, --site NAME               filter to one site (assumes result is {name: {...}})
#   -h, --help
#
# Any --s3-* flag implies --backend s3.
# AWS creds via env / AWS_PROFILE; IAM s3:GetObject required.

set -euo pipefail

BACKEND=local; TF_DIR=; OUTPUT=json; SITE=
S3_BUCKET=; S3_KEY=; S3_REGION=
INVENTORY_KEY=site_inventory.value

while [[ $# -gt 0 ]]; do
  case $1 in
    -b|--backend)        BACKEND=$2;       shift 2 ;;
    -d|--tf-dir)         TF_DIR=$2;        shift 2 ;;
    -o|--output)         OUTPUT=$2;        shift 2 ;;
    -s|--site)           SITE=$2;          shift 2 ;;
    -u|--s3-bucket)      S3_BUCKET=$2;     shift 2 ;;
    -k|--s3-key)         S3_KEY=$2;        shift 2 ;;
    -r|--s3-region)      S3_REGION=$2;     shift 2 ;;
    -i|--inventory-key)  INVENTORY_KEY=$2; shift 2 ;;
    -h|--help)           sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$S3_BUCKET$S3_KEY$S3_REGION" ]] && BACKEND=s3

case "$BACKEND" in
  local) [[ -d "$TF_DIR" ]] || { echo "--tf-dir is required and must exist for local backend" >&2; exit 2; } ;;
  s3)    [[ -n "$S3_BUCKET" && -n "$S3_KEY" ]] || { echo "--s3-bucket and --s3-key are required for s3 backend" >&2; exit 2; } ;;
  *)     echo "--backend must be local or s3" >&2; exit 2 ;;
esac
[[ "$OUTPUT" =~ ^(json|tsv|names)$ ]] || { echo "--output must be json|tsv|names" >&2; exit 2; }

if [[ "$BACKEND" == "local" ]]; then
  raw=$(cat -- "$TF_DIR/terraform.tfstate")
else
  raw=$(aws s3 cp ${S3_REGION:+--region "$S3_REGION"} "s3://$S3_BUCKET/$S3_KEY" -)
fi

inv=$(jq -ec --arg p "$INVENTORY_KEY" \
  'getpath(["outputs"] + ($p | split("."))) // empty' <<<"$raw") \
  || { echo "key '$INVENTORY_KEY' not found under .outputs in state" >&2; exit 1; }

if [[ -n "$SITE" ]]; then
  inv=$(jq -ec --arg s "$SITE" 'if has($s) then {($s): .[$s]} else empty end' <<<"$inv") \
    || { echo "site '$SITE' not in inventory" >&2; exit 1; }
fi

case "$OUTPUT" in
  json)  jq '.' <<<"$inv" ;;
  names) jq -r 'keys[]' <<<"$inv" ;;
  tsv)   jq -r 'to_entries[] | [.key, .value.connector_ip, .value.cidr, .value.environment, .value.tunnel_id] | @tsv' <<<"$inv" ;;
esac
