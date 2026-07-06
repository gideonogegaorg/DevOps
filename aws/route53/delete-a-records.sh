#!/usr/bin/env bash
# DELETE A records from a Route 53 hosted zone (reads current TTL/value for exact match).
# Usage: bash delete-a-records.sh <zone-name> <fqdn> [<fqdn> ...]
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <zone-name> <fqdn> [<fqdn> ...]" >&2
  exit 1
fi

ZONE_NAME="$1"
shift

if [ -n "${ROUTE53_ZONE_ID:-}" ]; then
  ZONE_ID="${ROUTE53_ZONE_ID#/hostedzone/}"
else
  ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$ZONE_NAME" \
    --query "HostedZones[0].Id" --output text | sed 's|/hostedzone/||')
fi

if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "None" ]; then
  echo "Error: hosted zone not found for $ZONE_NAME" >&2
  exit 1
fi

CHANGES=""
for name in "$@"; do
  record=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --query "ResourceRecordSets[?Name=='${name}.' && Type=='A'] | [0]" --output json)
  if [ "$record" = "null" ] || [ -z "$record" ]; then
    echo "Warning: no A record for $name; skipping" >&2
    continue
  fi
  ttl=$(echo "$record" | jq -r '.TTL')
  value=$(echo "$record" | jq -r '.ResourceRecords[0].Value')
  CHANGES="${CHANGES}{
      \"Action\": \"DELETE\",
      \"ResourceRecordSet\": {
        \"Name\": \"${name}\",
        \"Type\": \"A\",
        \"TTL\": ${ttl},
        \"ResourceRecords\": [{\"Value\": \"${value}\"}]
      }
    },"
done

if [ -z "$CHANGES" ]; then
  echo "No records to delete."
  exit 0
fi
CHANGES="${CHANGES%,}"

aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "{
  \"Changes\": [${CHANGES}]
}"

echo "DELETE complete in zone $ZONE_NAME ($ZONE_ID)"
