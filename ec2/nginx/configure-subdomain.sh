#!/usr/bin/env bash
# Provision nginx + systemd for a subdomain on Ubuntu EC2.
# Usage: sudo DLL_NAME=MyApp.Web.dll ./configure-subdomain.sh <hostname> <port> <service_name> [cert_domain] [is_production]
# Example:
#   sudo DLL_NAME=GMO.FamilyTree.Web.dll ./configure-subdomain.sh familytree.goom.life 5002 familytree goom.life true
set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 5 ]; then
  echo "Usage: sudo DLL_NAME=App.Web.dll $0 <hostname> <port> <service_name> [cert_domain] [is_production]" >&2
  exit 1
fi

HOSTNAME="$1"
PORT="$2"
SERVICE_NAME="$3"
CERT_DOMAIN="${4:-example.com}"
IS_PRODUCTION="${5:-false}"
WEB_ROOT="/var/www/$HOSTNAME"
DLL_NAME="${DLL_NAME:-}"

if [ "$EUID" -ne 0 ]; then
  echo "Error: run as root (sudo)" >&2
  exit 1
fi

if [ -z "$DLL_NAME" ]; then
  echo "Error: set DLL_NAME env var (e.g. GMO.FamilyTree.Web.dll)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_SCRIPT="$SCRIPT_DIR/../../dotnet/ec2/install-aspnetcore-runtime.sh"
if [ -f "$RUNTIME_SCRIPT" ]; then
  bash "$RUNTIME_SCRIPT"
else
  echo "Warning: install-aspnetcore-runtime.sh not found at $RUNTIME_SCRIPT; skipping."
fi

echo "Provisioning $HOSTNAME on port $PORT (service=$SERVICE_NAME, cert=$CERT_DOMAIN, production=$IS_PRODUCTION)..."

mkdir -p "$WEB_ROOT"
chown -R ubuntu:www-data "$WEB_ROOT"
chmod -R 775 "$WEB_ROOT"

SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=$HOSTNAME
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

NGINX_FILE="/etc/nginx/sites-available/$HOSTNAME"
ROBOTS_HEADER=""
if [[ "$IS_PRODUCTION" != "production" && "$IS_PRODUCTION" != "true" ]]; then
  ROBOTS_HEADER='add_header X-Robots-Tag "noindex, nofollow" always;'
fi

cat <<EOF > "$NGINX_FILE"
server {
    listen 80;
    server_name $HOSTNAME;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $HOSTNAME;

    ssl_certificate /etc/letsencrypt/live/$CERT_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$CERT_DOMAIN/privkey.pem;

    location / {
        proxy_pass         http://localhost:$PORT;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection keep-alive;
        proxy_set_header   Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        $ROBOTS_HEADER
    }
}
EOF

ln -sf "$NGINX_FILE" "/etc/nginx/sites-enabled/"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"

if nginx -t > /dev/null 2>&1; then
  systemctl reload nginx
else
  echo "Warning: nginx -t failed globally; site file written to $NGINX_FILE"
  nginx -t || true
fi

echo "Done. Deploy to $WEB_ROOT/site and: sudo systemctl restart $SERVICE_NAME"
