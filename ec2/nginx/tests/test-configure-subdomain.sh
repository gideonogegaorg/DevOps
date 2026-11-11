#!/usr/bin/env bash
#
# Smoke test for ec2/nginx/configure-subdomain.sh. Runs as root in a throwaway Ubuntu container
# (it writes to /etc/nginx and /etc/systemd); systemctl is stubbed. CONFIGURE_SUBDOMAIN_SCRIPT overrides
# the script under test (e.g. an older revision). From Git Bash at the repo root:
#   MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W):/repo:ro" -w /repo ubuntu:26.04 bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx openssl > /dev/null && bash ec2/nginx/tests/test-configure-subdomain.sh"

set -uo pipefail

if [[ "$EUID" -ne 0 ]] || [[ ! -f /.dockerenv ]]; then
  echo "Run this inside a disposable container as root; it rewrites /etc/nginx and /etc/systemd." >&2
  exit 1
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "${CONFIGURE_SUBDOMAIN_SCRIPT:-$here/../configure-subdomain.sh}" "$work/configure-subdomain.sh"
script="$work/configure-subdomain.sh"
passed=0
failed=0
rc=0

printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/systemctl
chmod +x /usr/local/bin/systemctl
id ubuntu > /dev/null 2>&1 || useradd -m ubuntu

make_cert() {
  mkdir -p "/etc/letsencrypt/live/$1"
  openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj "/CN=$1" -keyout "/etc/letsencrypt/live/$1/privkey.pem" -out "/etc/letsencrypt/live/$1/fullchain.pem" > /dev/null 2>&1
}

check() {
  local name="$1"
  shift
  if "$@"; then
    passed=$((passed + 1))
    echo "PASS $name"
  else
    failed=$((failed + 1))
    echo "FAIL $name"
  fi
}

run() {
  env "$@" > "$work/log" 2>&1
  rc=$?
}

exited_nonzero() { [[ "$rc" -ne 0 ]]; }
exited_zero() { [[ "$rc" -eq 0 ]]; }
absent() { local p; for p in "$@"; do [[ ! -e "$p" && ! -L "$p" ]] || return 1; done; }
links_to() { [[ -L "$1" ]] && [[ "$(readlink "$1")" == "$2" ]]; }
contains() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }
same() { cmp -s "$1" "$2"; }
nginx_ok() { nginx -t > /dev/null 2>&1; }

site=/etc/nginx/sites-available/app.example.test
link=/etc/nginx/sites-enabled/app.example.test
unit=/etc/systemd/system/app.service

run DLL_NAME=App.Web.dll bash "$script" app.example.test 0 app example.test production
check "validation: port 0 rejected" exited_nonzero
check "validation: port error names the port" contains "$work/log" "port '0'"
run DLL_NAME=App.Web.dll bash "$script" app.example.test 70000 app example.test production
check "validation: port 70000 rejected" exited_nonzero
run DLL_NAME=App.Web.dll bash "$script" app.example.test 50a1 app example.test production
check "validation: non-numeric port rejected" exited_nonzero
run DLL_NAME=App.Web.dll bash "$script" "bad_host;rm" 5000 app example.test production
check "validation: bad hostname rejected" exited_nonzero
run DLL_NAME=App.Web.dll bash "$script" app.example.test 5000 "" example.test production
check "validation: empty service name rejected" exited_nonzero
run DLL_NAME=App.Web.dll DEPLOY_PATH=/etc/app bash "$script" app.example.test 5000 app example.test production
check "validation: DEPLOY_PATH outside /var/www rejected" exited_nonzero
run DLL_NAME=App.Web.dll DEPLOY_PATH=/var/www/../etc bash "$script" app.example.test 5000 app example.test production
check "validation: DEPLOY_PATH with .. rejected" exited_nonzero
run bash "$script" app.example.test 5000 app example.test production
check "validation: missing DLL_NAME rejected" exited_nonzero
check "validation: nothing written" absent "$site" "$link" "$unit"

run DLL_NAME=App.Web.dll bash "$script" app.example.test 5000 app missing-cert.test production
check "new site, nginx -t fails: exit non-zero" exited_nonzero
check "new site, nginx -t fails: site file and symlink removed" absent "$site" "$link"
check "new site, nginx -t fails: systemd unit not written" absent "$unit"

make_cert example.test
run DLL_NAME=App.Web.dll DEPLOY_PATH=/var/www/app.example.test bash "$script" app.example.test 5000 app example.test true
check "valid site: exit 0" exited_zero
check "valid site: symlink enabled" links_to "$link" "$site"
check "valid site: unit points at DLL under DEPLOY_PATH" contains "$unit" "ExecStart=/usr/bin/dotnet /var/www/app.example.test/site/App.Web.dll"
check "valid site: true counts as production (no noindex)" lacks "$site" "X-Robots-Tag"
check "valid site: nginx -t passes" nginx_ok
check "valid site: websocket Connection uses the upgrade map" contains "$site" "Connection \$connection_upgrade"
check "valid site: upgrade map defined once in conf.d" contains /etc/nginx/conf.d/connection-upgrade.conf "map \$http_upgrade \$connection_upgrade"

cp -p "$site" "$work/good-site"
cp -p "$unit" "$work/good-unit"
run DLL_NAME=App.Web.dll bash "$script" app.example.test 5001 app missing-cert.test development
check "existing site, nginx -t fails: exit non-zero" exited_nonzero
check "existing site, nginx -t fails: previous site restored" same "$site" "$work/good-site"
check "existing site, nginx -t fails: symlink kept" links_to "$link" "$site"
check "existing site, nginx -t fails: unit unchanged" same "$unit" "$work/good-unit"
check "existing site, nginx -t fails: nginx config still valid" nginx_ok

run DLL_NAME=App.Web.dll bash "$script" app.example.test 5002 app example.test development
check "development: exit 0" exited_zero
check "development: noindex header added" contains "$site" "X-Robots-Tag"
check "development: default root is /var/www/<hostname>" contains "$unit" "WorkingDirectory=/var/www/app.example.test/site"

echo
echo "Passed: $passed  Failed: $failed"
[[ "$failed" -eq 0 ]]
