#!/usr/bin/env bash
# Obtain a wildcard Let's Encrypt certificate via Route 53 DNS-01.
# Usage: sudo bash setup-wildcard-route53.sh <base-domain> [email]
# Requires: certbot, python3-certbot-dns-route53, EC2 IAM route53:ChangeResourceRecordSets
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: sudo $0 <base-domain> [email]" >&2
  exit 1
fi

DOMAIN="$1"
EMAIL="${2:-}"

if [ "$EUID" -ne 0 ]; then
  echo "Error: run as root (sudo)" >&2
  exit 1
fi

ARGS=(
  certonly --dns-route53
  -d "$DOMAIN" -d "*.$DOMAIN"
  --non-interactive --agree-tos
  --cert-name "$DOMAIN"
)

if [ -n "$EMAIL" ]; then
  ARGS+=(--email "$EMAIL")
else
  ARGS+=(--register-unsafely-without-email)
fi

certbot "${ARGS[@]}"
echo "Certificate: /etc/letsencrypt/live/$DOMAIN/"
