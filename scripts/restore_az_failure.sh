#!/usr/bin/env bash
# Restore ridgepost-db after us-east-1a failure (single-AZ RDS + shared NAT).
# Usage: ./scripts/restore_az_failure.sh [source-identifier] [target-az]
# RTO ~25 min: restore 12-18 + secret/task 2 + healthz 3-5 + buffer.
# With Interface VPC endpoints (ecr/secrets/logs), ECS AWS API calls survive NAT AZ loss.
set -euo pipefail

SRC_ID="${1:-ridgepost-db}"
TARGET_AZ="${2:-us-east-1b}"
NEW_ID="${SRC_ID}-restored-${TARGET_AZ//-/}"
SUBNET_GROUP="${SRC_ID}"
CLUSTER="${SRC_ID%-db}-api"
SERVICE="${SRC_ID%-db}-api"
REGION="${AWS_REGION:-us-east-1}"

die() { echo "ERROR: $*" >&2; exit 1; }

command -v aws >/dev/null || die "aws CLI required"
[[ -n "$SRC_ID" && -n "$TARGET_AZ" ]] || die "usage: $0 <db-identifier> <target-az>"

echo "==> 1/5 Latest automated snapshot for ${SRC_ID}"
SNAP=$(aws rds describe-db-snapshots \
  --region "$REGION" \
  --db-instance-identifier "$SRC_ID" \
  --snapshot-type automated \
  --query 'reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[0].DBSnapshotIdentifier' \
  --output text)
[[ -n "$SNAP" && "$SNAP" != "None" && "$SNAP" != "null" ]] || die "no automated snapshot for ${SRC_ID}"
echo "    SNAP=${SNAP}"

echo "==> 2/5 Restore into ${TARGET_AZ} as ${NEW_ID} (publicly_accessible=false, managed password)"
aws rds restore-db-instance-from-db-snapshot \
  --region "$REGION" \
  --db-instance-identifier "$NEW_ID" \
  --db-snapshot-identifier "$SNAP" \
  --db-subnet-group-name "$SUBNET_GROUP" \
  --availability-zone "$TARGET_AZ" \
  --no-publicly-accessible \
  --manage-master-user-password >/dev/null

aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$NEW_ID"
HOST=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$NEW_ID" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
SECRET=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$NEW_ID" \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
[[ -n "$HOST" && "$HOST" != "None" ]] || die "restored endpoint missing"
[[ -n "$SECRET" && "$SECRET" != "None" ]] || die "managed MasterUserSecret ARN missing"
echo "    HOST=${HOST}"
echo "    SECRET=${SECRET}"

echo "==> 3/5 NAT AZ note: Interface VPCE (ecr.api/ecr.dkr/secretsmanager/logs) keep AWS API path."
echo "    Recreate NAT in ${TARGET_AZ} only if non-AWS HTTPS egress is required."

echo "==> 4/5 Wire compute to new host + secret (terraform apply or new task def)"
cat <<EOF
export TF_VAR_restored_db_host=${HOST}
export TF_VAR_restored_secret_arn=${SECRET}
# Set module.compute db_host + secret_arn, then:
#   cd envs/prod && terraform apply
# Or register task def with DB_HOST=${HOST} and secrets valueFrom=${SECRET}
EOF

echo "==> 5/5 Force ECS roll (requires task def already pointing at new HOST/SECRET)"
aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$SERVICE" \
  --force-new-deployment >/dev/null
echo "Done. RTO budget ~25 min = restore 12-18 + secret/task 2 + healthz 3-5 + buffer."
