#!/bin/bash

set -euo pipefail

team_id="${CLOUDKIT_TEAM_ID:-975JU2ENN7}"
container_id="${CLOUDKIT_CONTAINER_ID:-iCloud.com.jonesthevan.blog.InstaBlog}"

if [[ -n "${CKTOOL_BIN:-}" ]]; then
  cktool=("$CKTOOL_BIN")
else
  cktool=(xcrun cktool)
fi

schema_directory="$(mktemp -d "${TMPDIR:-/tmp}/instablog-cloudkit-schema.XXXXXX")"
trap 'rm -rf "$schema_directory"' EXIT

export_schema() {
  local environment="$1"
  "${cktool[@]}" export-schema \
    --team-id "$team_id" \
    --container-id "$container_id" \
    --environment "$environment" \
    --output-file "$schema_directory/$environment.ckdb"
}

echo "Checking CloudKit schema for $container_id"
export_schema development
export_schema production

if ! cmp -s "$schema_directory/development.ckdb" "$schema_directory/production.ckdb"; then
  echo "CloudKit schema is not promoted to Production." >&2
  echo "Deploy the pending schema changes in CloudKit Console before archiving." >&2
  exit 1
fi

echo "CloudKit Development and Production schemas match."
