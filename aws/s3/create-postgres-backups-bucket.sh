#!/bin/bash
# Create and secure the Postgres backups S3 bucket (idempotent).
set -euo pipefail

BUCKET="gideonogega-postgres-backups"
REGION="${AWS_REGION:-us-east-1}"

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "Bucket $BUCKET already exists."
else
  echo "Creating bucket $BUCKET in $REGION..."
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION"
  fi
fi

echo "Blocking public access..."
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "Enabling default encryption..."
aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

echo "Adding lifecycle rule (expire ec2-ubuntu/* after 30 days)..."
LIFECYCLE='{
  "Rules": [{
    "ID": "expire-postgres-backups-30d",
    "Status": "Enabled",
    "Filter": { "Prefix": "ec2-ubuntu/" },
    "Expiration": { "Days": 30 }
  }]
}'
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" \
  --lifecycle-configuration "$LIFECYCLE"

echo "Done. Bucket: s3://$BUCKET/ec2-ubuntu/"
