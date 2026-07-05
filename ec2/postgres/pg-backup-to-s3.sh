#!/bin/bash
# Daily Postgres backup: dump all user databases to S3.
# Installed to /usr/local/sbin/pg-backup-to-s3.sh by install-postgres-backup.sh
set -euo pipefail

BUCKET="${PG_BACKUP_BUCKET:-gideonogega-postgres-backups}"
PREFIX="${PG_BACKUP_PREFIX:-ec2-ubuntu}"
BACKUP_DIR="/var/backups/postgres"
LOG_FILE="/var/log/postgres-backup.log"
DATE=$(date +%Y-%m-%d)
STAMP=$(date '+%Y-%m-%d %H:%M:%S')

log() { echo "[$STAMP] $*" | tee -a "$LOG_FILE"; }

cleanup_tmp() {
  rm -f "${BACKUP_DIR:?}/"*.dump.gz 2>/dev/null || true
}
trap cleanup_tmp EXIT

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

mapfile -t DATABASES < <(
  sudo -u postgres psql -tAc \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');"
)

if [ "${#DATABASES[@]}" -eq 0 ]; then
  log "ERROR: No databases found to backup."
  exit 1
fi

FAILED=0
for db in "${DATABASES[@]}"; do
  db=$(echo "$db" | tr -d '[:space:]')
  [ -z "$db" ] && continue
  tmp="${BACKUP_DIR}/${db}-${DATE}.dump.gz"
  s3_key="${PREFIX}/${db}/${DATE}.dump.gz"
  log "Backing up database: $db"
  if sudo -u postgres pg_dump -Fc "$db" | gzip > "$tmp"; then
    if aws s3 cp "$tmp" "s3://${BUCKET}/${s3_key}" --only-show-errors; then
      log "Uploaded s3://${BUCKET}/${s3_key}"
      rm -f "$tmp"
    else
      log "ERROR: S3 upload failed for $db"
      FAILED=1
    fi
  else
    log "ERROR: pg_dump failed for $db"
    FAILED=1
  fi
done

if [ "$FAILED" -ne 0 ]; then
  log "Backup completed with errors."
  exit 1
fi
log "Backup completed successfully for ${#DATABASES[@]} database(s)."
