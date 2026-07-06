#!/usr/bin/env bash
# Stop, disable, and remove a systemd service unit.
# Usage: sudo bash remove-systemd-service.sh <service-name>
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: sudo $0 <service-name>" >&2
  exit 1
fi

SERVICE="$1"
UNIT="/etc/systemd/system/${SERVICE}.service"

if [ "$EUID" -ne 0 ]; then
  echo "Error: run as root (sudo)" >&2
  exit 1
fi

systemctl stop "$SERVICE" 2>/dev/null || true
systemctl disable "$SERVICE" 2>/dev/null || true
rm -f "$UNIT"
systemctl daemon-reload
echo "Removed systemd service $SERVICE"
