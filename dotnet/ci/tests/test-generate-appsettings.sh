#!/usr/bin/env bash
#
# Tests for dotnet/ci/generate-appsettings.sh. Plain bash, needs jq.
# Every run uses env -i with fake values only, so no real environment reaches the generator.
#
# Usage: bash dotnet/ci/tests/test-generate-appsettings.sh

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gen="$here/../generate-appsettings.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
status=0

pass() {
  passed=$((passed + 1))
  echo "PASS $1"
}

fail() {
  failed=$((failed + 1))
  echo "FAIL $1"
  [[ -n "${2:-}" ]] && echo "     $2"
}

# run [VAR=value ...] -- <template> <output> [defaults]
run() {
  local -a vars=()
  while [[ "$1" != "--" ]]; do
    vars+=("$1")
    shift
  done
  shift
  env -i PATH="$PATH" "${vars[@]}" bash "$gen" "$@" > "$work/log" 2>&1
  status=$?
}

# Compared as JSON-encoded strings: jq on Windows writes raw newlines as CRLF, and
# MSYS_NO_PATHCONV stops Git Bash rewriting /paths passed to it.
expect_value() {
  local name="$1" file="$2" path="$3" expected actual
  expected="$(MSYS_NO_PATHCONV=1 jq -cn --arg v "$4" '$v')"
  actual="$(jq -c "$path | tostring" "$file")"
  if [[ "$actual" == "$expected" ]]; then
    pass "$name"
  else
    fail "$name" "expected $expected got $actual"
  fi
}

expect_status() {
  local name="$1" expected="$2"
  if [[ "$status" -eq "$expected" ]]; then
    pass "$name"
  else
    fail "$name" "exit $status, expected $expected; output: $(cat "$work/log")"
  fi
}

expect_absent() {
  if [[ -e "$2" ]]; then
    fail "$1" "$2 exists"
  else
    pass "$1"
  fi
}

expect_log() {
  local name="$1" pattern="$2"
  if grep -qF -- "$pattern" "$work/log"; then
    pass "$name"
  else
    fail "$name" "log lacks [$pattern]: $(cat "$work/log")"
  fi
}

expect_log_lacks() {
  local name="$1" pattern="$2"
  if grep -qF -- "$pattern" "$work/log"; then
    fail "$name" "log contains [$pattern]"
  else
    pass "$name"
  fi
}

cat > "$work/strings.json.template" <<'EOF'
{
  "S": "^^S^^",
  "Prefixed": "pre-^^S^^-post",
  "Path": "^^LOG_PATH^^/log-.txt",
  "AfterEscapedQuote": "a\"^^PLAIN^^",
  "Two": "^^PLAIN^^ and ^^PLAIN^^"
}
EOF

tricky=$'quote" back\\slash |pipe &amp /slash\nnewline\ttab\rcr ^^PLAIN^^ ${X} \x01ctl'
run "S=$tricky" "LOG_PATH=/var/www/app.example.test/logs" "PLAIN=plain" -- "$work/strings.json.template" "$work/strings.json"
expect_status "string tokens: exit 0" 0
expect_value "string tokens: special characters round-trip" "$work/strings.json" .S "$tricky"
expect_value "string tokens: token inside a longer string" "$work/strings.json" .Prefixed "pre-${tricky}-post"
expect_value "string tokens: path suffix kept" "$work/strings.json" .Path "/var/www/app.example.test/logs/log-.txt"
expect_value "string tokens: string state survives an escaped quote" "$work/strings.json" .AfterEscapedQuote 'a"plain'
expect_value "string tokens: repeated token" "$work/strings.json" .Two "plain and plain"

cat > "$work/scalars.json.template" <<'EOF'
{ "A": ^^A^^, "B": ^^B^^, "C": ^^C^^, "D": ^^D^^, "E": ^^E^^, "F": ^^F^^, "G": ^^G^^, "H": ^^H^^ }
EOF
run A=True B=yes C=1 D=no E= F=0 G=42 H=-1.5e3 -- "$work/scalars.json.template" "$work/scalars.json"
expect_status "scalars: exit 0" 0
expect_value "scalars: True -> true" "$work/scalars.json" .A true
expect_value "scalars: yes -> true" "$work/scalars.json" .B true
expect_value "scalars: 1 -> true" "$work/scalars.json" .C true
expect_value "scalars: no -> false" "$work/scalars.json" .D false
expect_value "scalars: empty -> false" "$work/scalars.json" .E false
expect_value "scalars: 0 -> false" "$work/scalars.json" .F false
expect_value "scalars: integer passes through" "$work/scalars.json" .G 42
if grep -qF '"H": -1.5e3 ' "$work/scalars.json"; then
  pass "scalars: exponent number passes through unchanged"
else
  fail "scalars: exponent number passes through unchanged" "$(cat "$work/scalars.json")"
fi

cat > "$work/bad-scalar.json.template" <<'EOF'
{ "Flag": ^^FLAG^^ }
EOF
run FLAG=fake-not-a-bool-value -- "$work/bad-scalar.json.template" "$work/bad-scalar.json"
expect_status "scalars: non-bool value outside a string fails" 1
expect_log "scalars: failure names the token" "FLAG"
expect_log_lacks "scalars: failure hides the value" "fake-not-a-bool-value"
expect_absent "scalars: no output on failure" "$work/bad-scalar.json"

cat > "$work/family.json.template" <<'EOF'
{
  "Prefix": "^^PHOTOS_STORAGE_PREFIX^^",
  "From": "^^EMAIL_FROM_ADDRESS^^",
  "Display": "^^EMAIL_FROM_DISPLAY_NAME^^",
  "Region": "^^EMAIL_REGION^^",
  "Literal": "^^LITERAL^^",
  "Escaped": "^^ESCAPED^^",
  "Later": "^^USES_LATER^^",
  "Quoted": "^^QUOTED^^",
  "IsProduction": ^^IS_PRODUCTION^^
}
EOF
cat > "$work/family.defaults.lf" <<'EOF'
# Family-style derived defaults

USES_LATER=${DEFINED_LATER}
PHOTOS_PREFIX_FROM_ENV=${PHOTOS_APP_NAME:+${PHOTOS_ENVIRONMENT:+${PHOTOS_APP_NAME}/${PHOTOS_ENVIRONMENT}}}
PHOTOS_PREFIX_FROM_TELEMETRY=${PHOTOS_APP_NAME:+${TELEMETRY_ENVIRONMENT_NAME:+${PHOTOS_APP_NAME}/${TELEMETRY_ENVIRONMENT_NAME}}}
PHOTOS_STORAGE_PREFIX=${PHOTOS_PREFIX_FROM_ENV:-${PHOTOS_PREFIX_FROM_TELEMETRY}}
EMAIL_FROM_ADDRESS=${EMAIL_DOMAIN:+noreply@${EMAIL_DOMAIN}}
EMAIL_FROM_DISPLAY_NAME=GOOM Family Tree
EMAIL_REGION=us-east-1
LITERAL='${NOT_EXPANDED}'
ESCAPED=$${KEEP} ${EMAIL_REGION}
QUOTED="a b"
DEFINED_LATER=late
IS_PRODUCTION=false
EOF
sed 's/$/\r/' "$work/family.defaults.lf" > "$work/family.defaults"

run PHOTOS_APP_NAME=familytree PHOTOS_ENVIRONMENT=dev TELEMETRY_ENVIRONMENT_NAME=other EMAIL_DOMAIN=familytree-dev.example.test -- "$work/family.json.template" "$work/family.json" "$work/family.defaults"
expect_status "defaults: exit 0 with CRLF defaults file" 0
expect_value "defaults: prefix from app and environment" "$work/family.json" .Prefix "familytree/dev"
expect_value "defaults: from address derived from domain" "$work/family.json" .From "noreply@familytree-dev.example.test"
expect_value "defaults: plain default" "$work/family.json" .Display "GOOM Family Tree"
expect_value "defaults: single quotes are literal" "$work/family.json" .Literal "\${NOT_EXPANDED}"
expect_value "defaults: \$\${ escape and earlier key reference" "$work/family.json" .Escaped "\${KEEP} us-east-1"
expect_value "defaults: reference to a later key is empty" "$work/family.json" .Later ""
expect_value "defaults: double quotes removed" "$work/family.json" .Quoted "a b"
expect_value "defaults: bool default" "$work/family.json" .IsProduction false

run PHOTOS_APP_NAME=familytree TELEMETRY_ENVIRONMENT_NAME=prod -- "$work/family.json.template" "$work/family.json" "$work/family.defaults"
expect_value "defaults: prefix falls back to telemetry environment" "$work/family.json" .Prefix "familytree/prod"
expect_value "defaults: from address empty without a domain" "$work/family.json" .From ""

run PHOTOS_STORAGE_PREFIX=explicit/prefix EMAIL_FROM_ADDRESS=ops@example.test EMAIL_REGION= IS_PRODUCTION=true -- "$work/family.json.template" "$work/family.json" "$work/family.defaults"
expect_value "precedence: non-empty env wins over a derived default" "$work/family.json" .Prefix "explicit/prefix"
expect_value "precedence: env wins over a defaults reference" "$work/family.json" .From "ops@example.test"
expect_value "precedence: empty env falls back to the default" "$work/family.json" .Region "us-east-1"
expect_value "precedence: env bool wins" "$work/family.json" .IsProduction true

cat > "$work/unresolved.json.template" <<'EOF'
{ "A": "^^SET_TOKEN^^", "B": "^^MISSING_ONE^^", "C": "^^MISSING_TWO^^", "D": "^^EMPTY_TOKEN^^", "E": "^^OPTIONAL_TOKEN^^" }
EOF
run SET_TOKEN=fake-secret-value EMPTY_TOKEN= -- "$work/unresolved.json.template" "$work/unresolved.json"
expect_status "unresolved: fails" 1
expect_log "unresolved: names the first missing token" "MISSING_ONE"
expect_log "unresolved: names the second missing token" "MISSING_TWO"
expect_log "unresolved: emits a GitHub error annotation" "::error::"
expect_log_lacks "unresolved: set-but-empty token is resolved" "EMPTY_TOKEN"
expect_log_lacks "unresolved: values never printed" "fake-secret-value"
expect_absent "unresolved: no output written" "$work/unresolved.json"

run SET_TOKEN=x EMPTY_TOKEN= "APPSETTINGS_OPTIONAL_TOKENS=MISSING_ONE,MISSING_TWO OPTIONAL_TOKEN" -- "$work/unresolved.json.template" "$work/unresolved.json"
expect_status "optional: listed tokens resolve to empty" 0
expect_value "optional: value is empty" "$work/unresolved.json" .B ""

cat > "$work/broken.json.template" <<'EOF'
{ "A": "^^A^^", }
EOF
run A=fake-broken-value -- "$work/broken.json.template" "$work/broken.json"
expect_status "json: invalid template fails validation" 1
expect_log "json: reports invalid JSON" "not valid JSON"
expect_log_lacks "json: failure hides the value" "fake-broken-value"
expect_absent "json: invalid output removed" "$work/broken.json"

cat > "$work/lower.json.template" <<'EOF'
{ "A": "^^lowerToken^^" }
EOF
run -- "$work/lower.json.template" "$work/lower.json"
expect_status "names: lower-case token rejected" 1

printf 'BAD KEY=value\n' > "$work/bad.defaults"
run -- "$work/strings.json.template" "$work/strings.json" "$work/bad.defaults"
expect_status "defaults: invalid key rejected" 1
printf 'NOEQUALS\n' > "$work/bad.defaults"
run -- "$work/strings.json.template" "$work/strings.json" "$work/bad.defaults"
expect_status "defaults: line without = rejected" 1
cat > "$work/bad.defaults" <<'EOF'
A=${UNTERMINATED:-x
EOF
run -- "$work/strings.json.template" "$work/strings.json" "$work/bad.defaults"
expect_status "defaults: unterminated reference rejected" 1
cat > "$work/inject.defaults" <<EOF
A=\$(echo injected > $work/pwned1)
B=\`touch $work/pwned2\`
EOF
cat > "$work/inject.json.template" <<'EOF'
{ "A": "^^A^^", "B": "^^B^^" }
EOF
run -- "$work/inject.json.template" "$work/inject.json" "$work/inject.defaults"
expect_status "defaults: command substitution kept literal (exit 0)" 0
if [[ ! -e "$work/pwned1" ]] && [[ ! -e "$work/pwned2" ]]; then
  pass "defaults: no command executed"
else
  fail "defaults: no command executed"
fi
expect_value "defaults: \$() stays literal" "$work/inject.json" .A "\$(echo injected > $work/pwned1)"

cat > "$work/site.json.template" <<'EOF'
{
  "Site": {
    "IsProduction": ^^IS_PRODUCTION^^,
    "Title": "Example"
  }
}
EOF
printf 'IS_PRODUCTION=false\n' > "$work/site.defaults"
run IS_PRODUCTION=true -- "$work/site.json.template" "$work/site.json" "$work/site.defaults"
expect_value "site: IsProduction from env" "$work/site.json" .Site.IsProduction true
run -- "$work/site.json.template" "$work/site.json" "$work/site.defaults"
expect_value "site: IsProduction default for local dev" "$work/site.json" .Site.IsProduction false

run -- "$work/missing.template" "$work/out.json"
expect_status "args: missing template fails" 1
run -- "$work/site.json.template"
expect_status "args: missing output argument fails" 1

echo
echo "Passed: $passed  Failed: $failed"
[[ "$failed" -eq 0 ]]
