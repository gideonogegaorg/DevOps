#!/usr/bin/env bash
# Archive a retired deploy directory under /var/www/.archive-<basename>.
# Usage: sudo bash archive-www-path.sh <path>
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: sudo $0 <path>" >&2
  exit 1
fi

SRC="$1"

if [ "$EUID" -ne 0 ]; then
  echo "Error: run as root (sudo)" >&2
  exit 1
fi

if [ ! -d "$SRC" ]; then
  echo "Warning: $SRC not found; skipping"
  exit 0
fi

BASE=$(basename "$SRC")
DEST="/var/www/.archive-$BASE"
mv "$SRC" "$DEST"
echo "Archived $SRC -> $DEST"
