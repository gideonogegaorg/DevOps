#!/usr/bin/env bash
#
# Tests for dotnet/ec2/replace-site.sh. Plain bash, no sudo.
# Run: bash dotnet/ec2/tests/test-replace-site.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/replace-site.sh"
PASS=0
FAIL=0
ROOT=""

setup() {
  ROOT="$(mktemp -d)"
  mkdir -p "$ROOT/staged/wwwroot" "$ROOT/www/site/wwwroot/uploads" "$ROOT/www/site/data/dataprotection-keys"
  echo new > "$ROOT/staged/Web.dll"
  echo new-css > "$ROOT/staged/wwwroot/site.css"
  echo old > "$ROOT/www/site/Web.dll"
  echo stale > "$ROOT/www/site/Serilog.Enrichers.Span.dll"
  echo old-css > "$ROOT/www/site/wwwroot/site.css"
  echo photo > "$ROOT/www/site/wwwroot/uploads/p.jpg"
  echo key > "$ROOT/www/site/data/dataprotection-keys/key-1.xml"
}

teardown() {
  rm -rf "$ROOT"
}

check() {
  local name="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAILED: $name"
  fi
}

run() {
  bash "$SCRIPT" "$ROOT/staged" "$ROOT/www/site" "$@" > "$ROOT/out.log" 2>&1
}

no_keep_dirs_left() {
  [[ -z "$(find "$ROOT/www" -maxdepth 1 -name '.site-keep.*')" ]]
}

setup
run no
check "no-clean copies new build" grep -qx new "$ROOT/www/site/Web.dll"
check "no-clean leaves stale files" test -f "$ROOT/www/site/Serilog.Enrichers.Span.dll"
check "no-clean keeps runtime data" test -f "$ROOT/www/site/data/dataprotection-keys/key-1.xml"
teardown

setup
run yes
check "clean copies new build" grep -qx new "$ROOT/www/site/Web.dll"
check "clean removes stale dll" test ! -e "$ROOT/www/site/Serilog.Enrichers.Span.dll"
check "clean without keep removes data" test ! -e "$ROOT/www/site/data"
check "clean leaves no keep dir" no_keep_dirs_left
teardown

setup
run yes "data, wwwroot/uploads/"
check "keep exits 0" test $? -eq 0
check "keep preserves data protection keys" grep -qx key "$ROOT/www/site/data/dataprotection-keys/key-1.xml"
check "keep preserves nested uploads" grep -qx photo "$ROOT/www/site/wwwroot/uploads/p.jpg"
check "keep still replaces sibling files" grep -qx new-css "$ROOT/www/site/wwwroot/site.css"
check "keep still removes stale dll" test ! -e "$ROOT/www/site/Serilog.Enrichers.Span.dll"
check "keep leaves no keep dir" no_keep_dirs_left
teardown

setup
mkdir -p "$ROOT/staged/data"
echo staged > "$ROOT/staged/data/seed.txt"
run yes data
check "kept path replaces staged copy" test ! -e "$ROOT/www/site/data/seed.txt"
check "kept path content restored" test -f "$ROOT/www/site/data/dataprotection-keys/key-1.xml"
teardown

setup
rm -rf "$ROOT/www/site/data"
run yes "data,missing/path"
check "missing keep paths are ignored" test $? -eq 0
check "missing keep paths still deploy" grep -qx new "$ROOT/www/site/Web.dll"
teardown

for bad in "../escape" "data/../.." "/etc"; do
  setup
  run yes "$bad"
  rc=$?
  check "rejects keep path $bad" test "$rc" -ne 0
  check "rejected keep path leaves site untouched ($bad)" test -f "$ROOT/www/site/Serilog.Enrichers.Span.dll"
  check "rejected keep path keeps data ($bad)" test -f "$ROOT/www/site/data/dataprotection-keys/key-1.xml"
  teardown
done

setup
rm -rf "$ROOT/staged"
run yes data
rc=$?
check "missing staged dir fails" test "$rc" -ne 0
check "missing staged dir leaves site untouched" test -f "$ROOT/www/site/Web.dll"
teardown

echo "replace-site.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
