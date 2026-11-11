#!/usr/bin/env bash
# Apply FamilyTree S3 photo prefix policy to EC2-Certbot-Role.
# Requires AWS credentials with iam:PutRolePolicy (root/admin).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLE_NAME="${EC2_ROLE_NAME:-EC2-Certbot-Role}"
POLICY_NAME="${S3_POLICY_NAME:-FamilyTreePhotosS3Policy}"
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document "file://${SCRIPT_DIR}/familytree-photos-policy.json"
echo "Applied ${POLICY_NAME} on ${ROLE_NAME}"
