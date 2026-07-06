#!/usr/bin/env bash
# Rename a PostgreSQL database (apps must be stopped first).
# Usage: sudo bash rename-database.sh [--backup] <old-name> <new-name>
set -euo pipefail

BACKUP=no
if [ "${1:-}" = "--backup" ]; then
  BACKUP=yes
  shift
fi

if [ "$#" -ne 2 ]; then
  echo "Usage: sudo $0 [--backup] <old-name> <new-name>" >&2
  exit 1
fi

OLD="$1"
NEW="$2"
BACKUP_DIR="/var/backups/postgres"

if [ "$EUID" -ne 0 ]; then
  echo "Error: run as root (sudo)" >&2
  exit 1
fi

exists_old=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '$OLD'")
if [ "$exists_old" != "1" ]; then
  echo "Error: database '$OLD' not found" >&2
  exit 1
fi

exists_new=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '$NEW'")
if [ "$exists_new" = "1" ]; then
  echo "Error: target database '$NEW' already exists" >&2
  exit 1
fi

echo "Terminating connections to $OLD..."
sudo -u postgres psql -v ON_ERROR_STOP=1 -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$OLD' AND pid <> pg_backend_pid();"

if [ "$BACKUP" = "yes" ]; then
  mkdir -p "$BACKUP_DIR"
  chown postgres:postgres "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  STAMP=$(date +%Y%m%d-%H%M%S)
  FILE="$BACKUP_DIR/${OLD}-${STAMP}.dump"
  echo "Backing up $OLD to $FILE..."
  sudo -u postgres pg_dump -Fc "$OLD" -f "$FILE"
fi

echo "Renaming $OLD -> $NEW..."
sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER DATABASE \"$OLD\" RENAME TO \"$NEW\";"
echo "Done."
