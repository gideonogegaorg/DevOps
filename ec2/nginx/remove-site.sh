#!/usr/bin/env bash
# Remove an nginx site and reload nginx.
# Usage: sudo bash remove-site.sh <hostname>
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: sudo $0 <hostname>" >&2
  exit 1
fi

HOSTNAME="$1"

if [ "$EUID" -ne 0 ]; then
  echo "Error: run as root (sudo)" >&2
  exit 1
fi

rm -f "/etc/nginx/sites-enabled/$HOSTNAME" "/etc/nginx/sites-available/$HOSTNAME"
nginx -t
systemctl reload nginx
echo "Removed nginx site $HOSTNAME"
