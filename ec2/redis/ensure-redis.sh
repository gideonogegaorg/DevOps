#!/usr/bin/env bash

# Idempotently installs and reconciles the shared host-local Redis service.
# Applications share this instance and isolate keys with an app/environment prefix.

set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

if ! command -v redis-server >/dev/null 2>&1; then
  echo "[Redis] Installing redis-server..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y redis-server
fi

CONF=/etc/redis/redis.conf
if [ ! -f "$CONF" ]; then
  echo "[Redis] Expected configuration file not found: $CONF"
  exit 1
fi

before_hash="$(sha256sum "$CONF" | awk '{print $1}')"

set_directive() {
  local name="$1"
  local value="$2"

  if grep -Eq "^[[:space:]#]*${name}[[:space:]]+" "$CONF"; then
    sed -Ei "s|^[[:space:]#]*${name}[[:space:]]+.*|${name} ${value}|" "$CONF"
  else
    printf '\n%s %s\n' "$name" "$value" >> "$CONF"
  fi
}

set_directive bind "127.0.0.1 ::1"
set_directive protected-mode "yes"
set_directive supervised "systemd"
set_directive appendonly "yes"
set_directive appendfsync "everysec"
set_directive dir "/var/lib/redis"

after_hash="$(sha256sum "$CONF" | awk '{print $1}')"

systemctl enable redis-server
if [ "$before_hash" != "$after_hash" ] || ! systemctl is-active --quiet redis-server; then
  echo "[Redis] Starting/restarting redis-server..."
  systemctl restart redis-server
fi

for attempt in 1 2 3 4 5; do
  if [ "$(redis-cli -h 127.0.0.1 ping 2>/dev/null || true)" = "PONG" ]; then
    echo "[Redis] Shared Redis is healthy on 127.0.0.1:6379."
    exit 0
  fi
  echo "[Redis] Health check attempt ${attempt} failed; retrying..."
  sleep 2
done

echo "[Redis] redis-server failed its health check."
systemctl status redis-server --no-pager || true
exit 1
