#!/bin/bash
# Ensure ASP.NET Core Runtime 10 is installed (idempotent).
# Usage: sudo ./install-aspnetcore-runtime.sh
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run as root (sudo)"
  exit 1
fi

DOTNET_BIN="${DOTNET_BIN:-/usr/bin/dotnet}"
RUNTIME_PACKAGE="aspnetcore-runtime-10.0"

has_aspnetcore_10() {
  if [ ! -x "$DOTNET_BIN" ]; then
    return 1
  fi
  "$DOTNET_BIN" --list-runtimes 2>/dev/null | grep -qE 'Microsoft\.AspNetCore\.App 10\.'
}

if has_aspnetcore_10; then
  echo "ASP.NET Core Runtime 10 already installed:"
  "$DOTNET_BIN" --list-runtimes | grep -E 'Microsoft\.AspNetCore\.App 10\.' || true
  exit 0
fi

echo "Installing $RUNTIME_PACKAGE..."
export DEBIAN_FRONTEND=noninteractive
apt-get update

if ! apt-cache show "$RUNTIME_PACKAGE" >/dev/null 2>&1; then
  echo "Package $RUNTIME_PACKAGE not in apt cache; adding ppa:dotnet/backports (Ubuntu 22.04)..."
  apt-get install -y software-properties-common
  add-apt-repository -y ppa:dotnet/backports
  apt-get update
fi

apt-get install -y "$RUNTIME_PACKAGE"

if ! has_aspnetcore_10; then
  echo "Error: $RUNTIME_PACKAGE installed but Microsoft.AspNetCore.App 10.x not found."
  "$DOTNET_BIN" --list-runtimes 2>&1 || true
  exit 1
fi

echo "ASP.NET Core Runtime 10 installed:"
"$DOTNET_BIN" --list-runtimes | grep -E 'Microsoft\.AspNetCore\.App 10\.' || true
