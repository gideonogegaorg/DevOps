#!/usr/bin/env bash
# UPSERT A records in a Route 53 hosted zone.
# Usage: bash upsert-a-records.sh <zone-name> <fqdn>=<ip> [<fqdn>=<ip> ...]
# Example:
#   bash upsert-a-records.sh goom.life familytree.goom.life=35.172.36.171
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <zone-name> <fqdn>=<ip> [<fqdn>=<ip> ...]" >&2
  exit 1
fi

ZONE_NAME="$1"
shift

ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$ZONE_NAME" \
  --query "HostedZones[0].Id" --output text | sed 's|/hostedzone/||')

if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "None" ]; then
  echo "Error: hosted zone not found for $ZONE_NAME" >&2
  exit 1
fi

CHANGES=""
for pair in "$@"; do
  name="${pair%%=*}"
  ip="${pair#*=}"
  if [ -z "$name" ] || [ -z "$ip" ] || [ "$name" = "$pair" ]; then
    echo "Error: invalid pair '$pair' (expected fqdn=ip)" >&2
    exit 1
  fi
  CHANGES="${CHANGES}{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"${name}\",
        \"Type\": \"A\",
        \"TTL\": 300,
        \"ResourceRecords\": [{\"Value\": \"${ip}\"}]
      }
    },"
done
CHANGES="${CHANGES%,}"

aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "{
  \"Changes\": [${CHANGES}]
}"

echo "UPSERT complete in zone $ZONE_NAME ($ZONE_ID)"
