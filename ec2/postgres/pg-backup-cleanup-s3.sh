#!/bin/bash
# Delete S3 postgres backups older than RETENTION_DAYS (default 30).
# Set DRY_RUN=1 to list without deleting.
set -euo pipefail

BUCKET="${PG_BACKUP_BUCKET:-gideonogega-postgres-backups}"
PREFIX="${PG_BACKUP_PREFIX:-ec2-ubuntu}"
RETENTION_DAYS="${PG_BACKUP_RETENTION_DAYS:-30}"
LOG_FILE="/var/log/postgres-backup.log"
STAMP=$(date '+%Y-%m-%d %H:%M:%S')
DRY_RUN="${DRY_RUN:-0}"

log() { echo "[$STAMP] $*" | tee -a "$LOG_FILE"; }

CUTOFF_EPOCH=$(date -u -d "${RETENTION_DAYS} days ago" +%s)
TOKEN=""

while true; do
  if [ -n "$TOKEN" ]; then
    RESP=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "${PREFIX}/" --starting-token "$TOKEN" --output json)
  else
    RESP=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "${PREFIX}/" --output json)
  fi

  while IFS=$'\t' read -r key lastmod; do
    [ -z "$key" ] && continue
    mod_epoch=$(date -u -d "$lastmod" +%s 2>/dev/null || echo 0)
    if [ "$mod_epoch" -lt "$CUTOFF_EPOCH" ]; then
      if [ "$DRY_RUN" = "1" ]; then
        log "DRY_RUN: would delete s3://${BUCKET}/${key} (modified $lastmod)"
      else
        log "Deleting s3://${BUCKET}/${key} (modified $lastmod)"
        aws s3 rm "s3://${BUCKET}/${key}"
      fi
    fi
  done < <(echo "$RESP" | jq -r '.Contents[]? | [.Key, .LastModified] | @tsv')

  TOKEN=$(echo "$RESP" | jq -r '.NextContinuationToken // empty')
  [ -z "$TOKEN" ] && break
done

log "Cleanup finished (retention=${RETENTION_DAYS}d, dry_run=${DRY_RUN})."
