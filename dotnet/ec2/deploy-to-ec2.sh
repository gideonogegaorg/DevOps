#!/usr/bin/env bash
# Remote deploy steps for EC2. Invoked from GitHub Actions over SSH.
# Keep bash-only syntax here; do not use the literal word "true" (GitHub masks it in inline scripts).
set -euo pipefail

DEPLOY_PATH="$1"
FULL_HOSTNAME="$2"
PORT="$3"
SERVICE_NAME="$4"
CERT_DOMAIN="$5"
PRODUCTION_MODE="$6"
STAGING="$7"

trap 'rm -rf "$STAGING"' EXIT

resolve_script() {
  for candidate in "$@"; do
    if [ -f "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  echo ""
}

RUNTIME_SCRIPT=$(resolve_script \
  "$STAGING/DevOps/dotnet/ec2/install-aspnetcore-runtime.sh" \
  "$STAGING/dotnet/ec2/install-aspnetcore-runtime.sh" \
  "$STAGING/scripts/install-aspnetcore-runtime.sh")
CONFIGURE_SCRIPT=$(resolve_script \
  "$STAGING/DevOps/ec2/nginx/configure-subdomain.sh" \
  "$STAGING/ec2/nginx/configure-subdomain.sh" \
  "$STAGING/scripts/configure-subdomain.sh")

if [ -z "$RUNTIME_SCRIPT" ] || [ -z "$CONFIGURE_SCRIPT" ]; then
  echo "::error::Missing runtime or configure script in staging dir"
  ls -laR "$STAGING" || :
  exit 1
fi

echo "[Deploy] Ensuring ASP.NET Core Runtime 10..."
sudo bash "$RUNTIME_SCRIPT"

echo "[Deploy] Ensuring directory..."
sudo mkdir -p "$DEPLOY_PATH/site" "$DEPLOY_PATH/logs" "$DEPLOY_PATH/uploads"
if ! sudo chown -R ubuntu:www-data "$DEPLOY_PATH"; then
  echo "::error::Failed to set ownership on $DEPLOY_PATH"
  ls -la "$DEPLOY_PATH" || :
  exit 1
fi

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
NEEDS_SETUP=no
if [ "${SETUP_CHANGED:-no}" != "no" ] || [ ! -f "$SERVICE_FILE" ]; then
  NEEDS_SETUP=yes
else
  DEPLOYED_DLL=""
  deployed_path="$(find "$STAGING/site" -maxdepth 1 -type f -name '*.Web.dll' 2>/dev/null | head -n1)"
  if [ -n "$deployed_path" ]; then
    DEPLOYED_DLL="$(basename "$deployed_path")"
  fi
  if [ -n "$DEPLOYED_DLL" ] && ! grep -qF "$DEPLOYED_DLL" "$SERVICE_FILE"; then
    echo "[Deploy] Systemd unit does not reference $DEPLOYED_DLL; re-running configure-subdomain.sh..."
    NEEDS_SETUP=yes
  fi
fi

if [ "$NEEDS_SETUP" = "yes" ]; then
  echo "[Deploy] Running configure-subdomain.sh..."
  if [ -z "${DLL_NAME:-}" ]; then
    deployed_path="$(find "$STAGING/site" -maxdepth 1 -type f -name '*.Web.dll' 2>/dev/null | head -n1)"
    if [ -n "$deployed_path" ]; then
      export DLL_NAME="$(basename "$deployed_path")"
    fi
  fi
  if [ -z "${DLL_NAME:-}" ]; then
    echo "::error::DLL_NAME not set and no *.Web.dll found in staging site"
    exit 1
  fi
  sudo -E bash "$CONFIGURE_SCRIPT" "$FULL_HOSTNAME" "$PORT" "$SERVICE_NAME" "$CERT_DOMAIN" "$PRODUCTION_MODE"
fi

echo "[Deploy] Copying site output..."
if [ ! -d "$STAGING/site" ]; then
  echo "::error::Missing staging site dir: $STAGING/site"
  ls -la "$STAGING" || :
  exit 1
fi
cp -r "$STAGING/site/." "$DEPLOY_PATH/site/"
sudo chown -R ubuntu:www-data "$DEPLOY_PATH"

echo "[Deploy] Restarting service..."
sudo systemctl restart "$SERVICE_NAME"
if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  echo "::error::Service $SERVICE_NAME failed to start after deploy."
  sudo journalctl -u "$SERVICE_NAME" -n 80 --no-pager
  exit 1
fi

echo "[Deploy] Waiting for local health check on port $PORT..."
HEALTH_OK=no
for i in $(seq 1 24); do
  if curl -sf "http://127.0.0.1:${PORT}/health" > /dev/null; then
    echo "[Deploy] Local health check passed (+$(( (i - 1) * 5 ))s)."
    HEALTH_OK=yes
    break
  fi
  sleep 5
done
if [ "$HEALTH_OK" != "yes" ]; then
  echo "::error::Local health check failed after 115s on http://127.0.0.1:${PORT}/health"
  sudo journalctl -u "$SERVICE_NAME" -n 80 --no-pager
  exit 1
fi

echo "[Deploy] Service healthy; public health check runs from GitHub Actions."
