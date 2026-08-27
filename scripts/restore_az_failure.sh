#!/usr/bin/env bash
# Restore ridgepost-db after us-east-1a failure (single-AZ + shared NAT trade-off).
# Usage: ./scripts/restore_az_failure.sh [source-identifier] [target-az]
# Prerequisites: AWS CLI, jq, terraform outputs available or env vars set.
set -euo pipefail

SRC_ID="${1:-ridgepost-db}"
TARGET_AZ="${2:-us-east-1b}"
NEW_ID="${SRC_ID}-restored-${TARGET_AZ//-/}"
SUBNET_GROUP="${SRC_ID}"          # aws_db_subnet_group name = ridgepost-db
CLUSTER="${SRC_ID%-db}-api"       # ridgepost-api cluster name pattern
SERVICE="${SRC_ID%-db}-api"
REGION="${AWS_REGION:-us-east-1}"

echo "==> 1/5 Latest automated snapshot for ${SRC_ID}"
SNAP=$(aws rds describe-db-snapshots \
  --region "$REGION" \
  --db-instance-identifier "$SRC_ID" \
  --snapshot-type automated \
  --query 'reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[0].DBSnapshotIdentifier' \
  --output text)
echo "    SNAP=${SNAP}"

echo "==> 2/5 Restore into ${TARGET_AZ} as ${NEW_ID} (publicly_accessible=false)"
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
echo "    HOST=${HOST}"
echo "    SECRET=${SECRET}"

echo "==> 3/5 If NAT AZ also died: recreate EIP+NAT in ${TARGET_AZ} public subnet (manual or terraform apply of networking count)."
echo "    Private ECS still needs :443 via NAT for ECR/Secrets until NAT is back."

echo "==> 4/5 Point ECS at new host + managed secret"
# Export for operator to feed into terraform.tfvars / TF_VAR or a one-shot task-def revise:
cat <<EOF
export TF_VAR_restored_db_host=${HOST}
export TF_VAR_restored_secret_arn=${SECRET}
# Then: update module.compute db_host + secret_arn and terraform apply
# Or: aws ecs update-service --cluster ${CLUSTER} --service ${SERVICE} --force-new-deployment
# after registering a new task definition with DB_HOST=${HOST} and secrets valueFrom=${SECRET}
EOF

echo "==> 5/5 Force ECS roll (after task def / tf apply updates host+secret)"
aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$SERVICE" \
  --force-new-deployment >/dev/null || true

echo "Done. RTO budget ~25 min = restore 12-18 + secret/task-def 2 + ECS healthz 3-5 + NAT rebuild buffer."
