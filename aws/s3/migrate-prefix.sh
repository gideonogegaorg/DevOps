#!/usr/bin/env bash
# Copy objects between S3 key prefixes within one bucket (aws s3 sync).
# Usage: bash migrate-prefix.sh <bucket> <old-prefix> <new-prefix> [--dry-run]
# Example:
#   bash migrate-prefix.sh gideonogega-internal family/prod familytree/prod --dry-run
#   bash migrate-prefix.sh gideonogega-internal family/prod familytree/prod
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <bucket> <old-prefix> <new-prefix> [--dry-run]" >&2
  exit 1
fi

BUCKET="$1"
OLD_PREFIX="${2%/}"
NEW_PREFIX="${3%/}"
DRY_RUN=""
if [ "${4:-}" = "--dry-run" ]; then
  DRY_RUN="--dryrun"
fi

SRC="s3://${BUCKET}/${OLD_PREFIX}/"
DST="s3://${BUCKET}/${NEW_PREFIX}/"

echo "Sync $SRC -> $DST"
aws s3 sync "$SRC" "$DST" $DRY_RUN

if [ -z "$DRY_RUN" ]; then
  echo "Source objects:"
  aws s3 ls "$SRC" --recursive --summarize | tail -2
  echo "Destination objects:"
  aws s3 ls "$DST" --recursive --summarize | tail -2
fi

echo "Done."
