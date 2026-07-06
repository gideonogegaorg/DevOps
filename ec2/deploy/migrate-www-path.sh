#!/usr/bin/env bash
# Copy deploy artifacts from one /var/www path to another.
# Usage: sudo bash migrate-www-path.sh <old-path> <new-path>
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: sudo $0 <old-path> <new-path>" >&2
  exit 1
fi

OLD="$1"
NEW="$2"

if [ "$EUID" -ne 0 ]; then
  echo "Error: run as root (sudo)" >&2
  exit 1
fi

if [ ! -d "$OLD" ]; then
  echo "Error: source not found: $OLD" >&2
  exit 1
fi

mkdir -p "$NEW"
cp -a "$OLD/." "$NEW/"
chown -R ubuntu:www-data "$NEW"
chmod -R 775 "$NEW"
echo "Migrated $OLD -> $NEW"
