#!/usr/bin/env bash
#
# Set PG_USER and PG_PASS once at the GitHub organization level.
# Deploy workflows read secrets.PG_USER / secrets.PG_PASS from there; repo or environment
# secrets with the same names would override them and block org-wide rotation, so avoid them.
#
# Prerequisites:
#   gh auth refresh -h github.com -s admin:org
#
# Usage:
#   export PG_USER='your_pg_role'
#   export PG_PASS='your_pg_password'
#   bash github/set-org-postgres-secrets.sh
#
# Optional:
#   GITHUB_ORG=other-org            target another organization (default gideonogegaorg)
#   SECRET_VISIBILITY=private       all | private (default all); ignored when REPOS is set
#   REPOS=gideonogegaorg/Family,gideonogegaorg/SpotifySmartPlaylists   restrict to selected repos

set -euo pipefail

ORG="${GITHUB_ORG:-gideonogegaorg}"
VISIBILITY="${SECRET_VISIBILITY:-all}"
REPOS="${REPOS:-}"

for name in PG_USER PG_PASS; do
  if [[ -z "${!name:-}" ]]; then
    echo "::error::Set $name in the environment before running." >&2
    exit 1
  fi
done

set_secret() {
  local name="$1" value="$2"
  if [[ -n "$REPOS" ]]; then
    printf '%s' "$value" | gh secret set "$name" --org "$ORG" --visibility selected --repos "$REPOS"
  else
    printf '%s' "$value" | gh secret set "$name" --org "$ORG" --visibility "$VISIBILITY"
  fi
  echo "Set organization secret: $name"
}

set_secret PG_USER "$PG_USER"
set_secret PG_PASS "$PG_PASS"

echo "Done. Ensure org secret policies allow the GitHub Environments used by deploy (prod, dev)."
