#!/usr/bin/env bash
# Copies a staged build into the live site dir.
# Usage: replace-site.sh <staged_site> <live_site> <clean yes|no> [keep_csv]
# With clean=yes the live dir is emptied first so files of removed packages do not linger;
# keep_csv lists site-relative paths the app writes at runtime, moved aside and restored over the staged copy.
set -euo pipefail

STAGED="$1"
LIVE="$2"
CLEAN="$3"
KEEP_CSV="${4:-}"

if [[ ! -d "$STAGED" ]]; then
  echo "::error::Missing staging site dir: $STAGED"
  exit 1
fi
mkdir -p "$LIVE"

keep_paths=()
IFS=',' read -ra raw_keep <<< "$KEEP_CSV"
for k in "${raw_keep[@]}"; do
  k="${k// /}"
  k="${k%/}"
  [[ -z "$k" ]] && continue
  if [[ "$k" == /* ]] || [[ "$k" == *..* ]]; then
    echo "::error::Keep path must be site-relative without '..': $k"
    exit 1
  fi
  keep_paths+=("$k")
done

if [[ "$CLEAN" != "yes" ]]; then
  cp -r "$STAGED/." "$LIVE/"
  exit 0
fi

keep_dir="$(mktemp -d "$(dirname "$LIVE")/.site-keep.XXXXXX")"
for k in "${keep_paths[@]}"; do
  if [[ -e "$LIVE/$k" ]]; then
    echo "[Deploy] Keeping site/$k"
    mkdir -p "$keep_dir/$(dirname "$k")"
    mv "$LIVE/$k" "$keep_dir/$k"
  fi
done

echo "[Deploy] Emptying $LIVE..."
find "$LIVE" -mindepth 1 -delete
cp -r "$STAGED/." "$LIVE/"

for k in "${keep_paths[@]}"; do
  if [[ -e "$keep_dir/$k" ]]; then
    rm -rf "${LIVE:?}/$k"
    mkdir -p "$LIVE/$(dirname "$k")"
    mv "$keep_dir/$k" "$LIVE/$k"
  fi
done
rm -rf "$keep_dir"
