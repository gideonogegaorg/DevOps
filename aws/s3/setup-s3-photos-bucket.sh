#!/usr/bin/env bash
#
# Creates a private S3 bucket for app photo storage, shared by apps through key prefixes.
# Idempotent: safe to re-run.
#
# Usage:
#   bash aws/s3/setup-s3-photos-bucket.sh [bucket-name] [region]
#
# Defaults:
#   bucket = gideonogega-internal
#   region = us-east-1
#
# Optional environment:
#   ORG_TAG      value of the "org" tag (default gideonogegaorg)
#   PURPOSE_TAG  value of the "purpose" tag (default internal-private-assets)
#   APP_NAME     app name used in the prefix hint printed at the end (default <app>)

set -euo pipefail

BUCKET="${1:-gideonogega-internal}"
REGION="${2:-us-east-1}"
ORG_TAG="${ORG_TAG:-gideonogegaorg}"
PURPOSE_TAG="${PURPOSE_TAG:-internal-private-assets}"
APP_NAME="${APP_NAME:-<app>}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ENCRYPTION_JSON="$TMP_DIR/s3-encryption.json"
cat > "$ENCRYPTION_JSON" <<'JSON'
{
  "Rules": [
    {
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }
  ]
}
JSON

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "Bucket $BUCKET already exists."
else
  if [[ "$REGION" = "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" --create-bucket-configuration "LocationConstraint=$REGION"
  fi
  echo "Created bucket $BUCKET in $REGION."
fi

aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration "file://${ENCRYPTION_JSON}"

aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging "TagSet=[{Key=org,Value=${ORG_TAG}},{Key=purpose,Value=${PURPOSE_TAG}}]"

echo "Bucket $BUCKET is private (public access blocked) with AES256 default encryption."
echo "Use path prefixes per app/env, e.g. ${APP_NAME}/prod/, ${APP_NAME}/dev/."
