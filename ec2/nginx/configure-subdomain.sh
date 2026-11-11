#!/usr/bin/env bash
# Provision nginx + systemd for a subdomain on Ubuntu EC2.
# Usage: sudo DLL_NAME=MyApp.Web.dll [DEPLOY_PATH=/var/www/<hostname>] ./configure-subdomain.sh <hostname> <port> <service_name> [cert_domain] [is_production]
# Example:
#   sudo DLL_NAME=GMO.FamilyTree.Web.dll ./configure-subdomain.sh familytree.goom.life 5002 familytree goom.life production
# is_production: production or true allow indexing; anything else adds X-Robots-Tag noindex.
# The nginx site is checked with nginx -t before anything else changes. On failure the previous
# site file and symlink are restored (or the new ones removed) and the script exits non-zero.
set -euo pipefail

usage() {
  echo "Usage: sudo DLL_NAME=App.Web.dll [DEPLOY_PATH=/var/www/<hostname>] $0 <hostname> <port> <service_name> [cert_domain] [is_production]" >&2
  exit 1
}

die() {
  echo "Error: $*" >&2
  exit 1
}

if [[ "$#" -lt 3 ]] || [[ "$#" -gt 5 ]]; then
  usage
fi

SITE_HOSTNAME="$1"
PORT="$2"
SERVICE_NAME="$3"
CERT_DOMAIN="${4:-example.com}"
IS_PRODUCTION="${5:-development}"
WEB_ROOT="${DEPLOY_PATH:-/var/www/$SITE_HOSTNAME}"
DLL_NAME="${DLL_NAME:-}"
hostname_re='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'

[[ "$SITE_HOSTNAME" =~ $hostname_re ]] || die "hostname '$SITE_HOSTNAME' is not a valid DNS name"
[[ "$CERT_DOMAIN" =~ $hostname_re ]] || die "cert_domain '$CERT_DOMAIN' is not a valid DNS name"
if [[ ! "$PORT" =~ ^[0-9]{1,5}$ ]] || ((10#$PORT < 1 || 10#$PORT > 65535)); then
  die "port '$PORT' must be a number from 1 to 65535"
fi
[[ "$SERVICE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]] || die "service_name must be non-empty and contain only letters, digits, _ . @ -"
if [[ "$WEB_ROOT" != /var/www/?* ]] || [[ "$WEB_ROOT" == *..* ]] || [[ ! "$WEB_ROOT" =~ ^[A-Za-z0-9/._-]+$ ]]; then
  die "DEPLOY_PATH '$WEB_ROOT' must be under /var/www/"
fi
[[ -n "$DLL_NAME" ]] || die "set DLL_NAME env var (e.g. GMO.FamilyTree.Web.dll)"
[[ "$DLL_NAME" =~ ^[A-Za-z0-9_.-]+\.dll$ ]] || die "DLL_NAME '$DLL_NAME' must be a file name ending in .dll"
WEB_ROOT="${WEB_ROOT%/}"

if [[ "$EUID" -ne 0 ]]; then
  die "run as root (sudo)"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_SCRIPT="$SCRIPT_DIR/../../dotnet/ec2/install-aspnetcore-runtime.sh"
if [[ -f "$RUNTIME_SCRIPT" ]]; then
  bash "$RUNTIME_SCRIPT"
else
  echo "Warning: install-aspnetcore-runtime.sh not found at $RUNTIME_SCRIPT; skipping."
fi

echo "Provisioning $SITE_HOSTNAME on port $PORT (service=$SERVICE_NAME, cert=$CERT_DOMAIN, production=$IS_PRODUCTION, root=$WEB_ROOT)..."

NGINX_FILE="/etc/nginx/sites-available/$SITE_HOSTNAME"
NGINX_LINK="/etc/nginx/sites-enabled/$SITE_HOSTNAME"
ROBOTS_HEADER=""
if [[ "$IS_PRODUCTION" != "production" && "$IS_PRODUCTION" != "true" ]]; then
  ROBOTS_HEADER='add_header X-Robots-Tag "noindex, nofollow" always;'
fi

# Shared by every site on the host, so it lives in conf.d (one http-level definition) rather than
# in a site file, where a second site's copy would be a duplicate-variable error. WebSocket
# requests (SignalR) get Connection: upgrade; everything else keeps upstream keep-alive.
UPGRADE_MAP_FILE="/etc/nginx/conf.d/connection-upgrade.conf"
cat <<'EOF' > "$UPGRADE_MAP_FILE"
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      "";
}
EOF

BACKUP_DIR="$(mktemp -d)"
trap 'rm -rf "$BACKUP_DIR"' EXIT
if [[ -f "$NGINX_FILE" ]]; then
  cp -p "$NGINX_FILE" "$BACKUP_DIR/site"
fi
if [[ -e "$NGINX_LINK" ]] || [[ -L "$NGINX_LINK" ]]; then
  cp -P "$NGINX_LINK" "$BACKUP_DIR/link"
fi

restore_nginx() {
  rm -f "$NGINX_FILE" "$NGINX_LINK"
  if [[ -f "$BACKUP_DIR/site" ]]; then
    cp -p "$BACKUP_DIR/site" "$NGINX_FILE"
  fi
  if [[ -e "$BACKUP_DIR/link" ]] || [[ -L "$BACKUP_DIR/link" ]]; then
    cp -P "$BACKUP_DIR/link" "$NGINX_LINK"
  fi
}

cat <<EOF > "$NGINX_FILE"
server {
    listen 80;
    server_name $SITE_HOSTNAME;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $SITE_HOSTNAME;

    ssl_certificate /etc/letsencrypt/live/$CERT_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$CERT_DOMAIN/privkey.pem;

    location / {
        proxy_pass         http://localhost:$PORT;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection \$connection_upgrade;
        proxy_set_header   Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        $ROBOTS_HEADER
    }
}
EOF

ln -sfn "$NGINX_FILE" "$NGINX_LINK"

if ! nginx_output="$(nginx -t 2>&1)"; then
  echo "$nginx_output" >&2
  restore_nginx
  if [[ -f "$BACKUP_DIR/site" ]]; then
    echo "Error: nginx -t failed; restored the previous $NGINX_FILE. systemd unit left unchanged." >&2
  else
    echo "Error: nginx -t failed; removed the new $NGINX_FILE and its symlink. systemd unit left unchanged." >&2
  fi
  exit 1
fi
systemctl reload nginx

mkdir -p "$WEB_ROOT"
chown -R ubuntu:www-data "$WEB_ROOT"
chmod -R 775 "$WEB_ROOT"

SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=$SITE_HOSTNAME
After=network.target

[Service]
WorkingDirectory=$WEB_ROOT/site
ExecStart=/usr/bin/dotnet $WEB_ROOT/site/$DLL_NAME --urls "http://localhost:$PORT"
Restart=always
RestartSec=10
KillSignal=SIGINT
SyslogIdentifier=$SERVICE_NAME
User=ubuntu
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_PRINT_TELEMETRY_MESSAGE=false

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"

echo "Done. Deploy to $WEB_ROOT/site and: sudo systemctl restart $SERVICE_NAME"
