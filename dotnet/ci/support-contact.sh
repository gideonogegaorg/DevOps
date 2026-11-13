#!/usr/bin/env bash
#
# Prints the support address for a deploy: the override when set, otherwise
# support@<last two labels of the hostname> (music-dev.goom.life -> support@goom.life).
# Multi-label public suffixes (example.co.uk) are not recognised; pass an override for those.
#
# Usage: support-contact.sh <hostname> [override]
# Exit codes: 0 printed, 1 usage or invalid override, 3 no address can be derived from the hostname.

set -euo pipefail

if [[ "$#" -lt 1 ]] || [[ "$#" -gt 2 ]]; then
  echo "::error::Usage: $0 <hostname> [override]" >&2
  exit 1
fi

override="${2:-}"
if [[ -n "$override" ]]; then
  if [[ ! "$override" =~ ^[A-Za-z0-9._%+-]+@([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; then
    echo "::error::The support contact override is not an email address." >&2
    exit 1
  fi
  printf '%s\n' "$override"
  exit 0
fi

host="${1,,}"
host="${host%.}"
if [[ ! "$host" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
  echo "::warning::Cannot derive a support contact from hostname '${host}'." >&2
  exit 3
fi

IFS=. read -ra labels <<< "$host"
count="${#labels[@]}"
printf 'support@%s.%s\n' "${labels[count - 2]}" "${labels[count - 1]}"
