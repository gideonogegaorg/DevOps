#!/usr/bin/env bash
#
# Tests for dotnet/ci/support-contact.sh. Plain bash.
# Run: bash dotnet/ci/tests/test-support-contact.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/support-contact.sh"
PASS=0
FAIL=0

expect() {
  local name="$1" want_status="$2" want_out="$3"
  shift 3
  local out status
  out="$(bash "$SCRIPT" "$@" 2> /dev/null)"
  status=$?
  if [[ "$status" -eq "$want_status" ]] && [[ "$out" == "$want_out" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAILED: $name (exit $status, output '$out'; expected exit $want_status, '$want_out')"
  fi
}

expect "subdomain of goom.life" 0 "support@goom.life" music-dev.goom.life
expect "subdomain of goom.tech" 0 "support@goom.tech" app.goom.tech
expect "apex hostname" 0 "support@gideonogega.com" gideonogega.com
expect "deep subdomain" 0 "support@goom.life" a.b.familytree-dev.goom.life
expect "upper case and trailing dot" 0 "support@goom.life" Music.GOOM.Life.
expect "empty override derives" 0 "support@goom.life" music.goom.life ""
expect "override wins" 0 "privacy@example.org" music.goom.life privacy@example.org
expect "override wins over an underivable host" 0 "privacy@example.org" "" privacy@example.org
expect "override with newline rejected" 1 "" music.goom.life $'a@example.org\nX=1'
expect "override without at rejected" 1 "" music.goom.life support
expect "override with spaces rejected" 1 "" music.goom.life "a b@example.org"
expect "single label host" 3 "" localhost
expect "empty host" 3 "" ""
expect "ip address" 3 "" 10.0.0.1
expect "host with newline" 3 "" $'goom.life\nX=1'
expect "no arguments" 1 ""
expect "too many arguments" 1 "" a.b c@d.ef extra

echo "support-contact: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
