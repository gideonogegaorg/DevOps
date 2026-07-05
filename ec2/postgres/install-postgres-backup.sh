#!/bin/bash
# Idempotent installer for Postgres S3 backup scripts on Ubuntu EC2 (ARM64 or x86_64).
# Usage: sudo bash install-postgres-backup.sh [path-to-devops-repo-root]
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Error: run as root (sudo)"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVOPS_ROOT="${1:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
POSTGRES_DIR="$DEVOPS_ROOT/ec2/postgres"

install_aws_cli() {
  if command -v aws >/dev/null 2>&1; then
    echo "AWS CLI already installed: $(aws --version)"
    return
  fi
  ARCH=$(uname -m)
  case "$ARCH" in
    aarch64|arm64) AWS_ARCH=aarch64 ;;
    x86_64|amd64)  AWS_ARCH=x86_64 ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
  esac
  if ! command -v unzip >/dev/null 2>&1; then
    apt-get update
    apt-get install -y unzip
  fi
  TMP=$(mktemp -d)
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o "$TMP/awscliv2.zip"
  unzip -q "$TMP/awscliv2.zip" -d "$TMP"
  "$TMP/aws/install" --update
  rm -rf "$TMP"
  echo "Installed: $(aws --version)"
}

install_jq() {
  if command -v jq >/dev/null 2>&1; then return; fi
  apt-get update
  apt-get install -y jq
}

echo "[install] Installing AWS CLI if needed..."
install_aws_cli

echo "[install] Verifying instance profile..."
if ! aws sts get-caller-identity; then
  echo "ERROR: AWS credentials not available. Attach IAM policy PostgresBackupS3Policy to EC2 role."
  exit 1
fi

echo "[install] Installing jq if needed..."
install_jq

echo "[install] Copying scripts to /usr/local/sbin/..."
install -m 750 "$POSTGRES_DIR/pg-backup-to-s3.sh" /usr/local/sbin/pg-backup-to-s3.sh
install -m 750 "$POSTGRES_DIR/pg-backup-cleanup-s3.sh" /usr/local/sbin/pg-backup-cleanup-s3.sh

echo "[install] Installing cron job..."
install -m 644 "$POSTGRES_DIR/postgres-s3-backup.cron" /etc/cron.d/postgres-s3-backup

echo "[install] Creating directories and log file..."
mkdir -p /var/backups/postgres
chmod 700 /var/backups/postgres
touch /var/log/postgres-backup.log
chmod 640 /var/log/postgres-backup.log

echo "[install] Done. Test with: sudo /usr/local/sbin/pg-backup-to-s3.sh"
