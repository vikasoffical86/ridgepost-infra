#!/usr/bin/env bash
# AZ-failure DR: PITR (RPO ~5m) with snapshot fallback. flock so two on-calls cannot race.
# Usage: ./scripts/restore_az_failure.sh [source-id] [target-az]
set -euo pipefail
SRC_ID="${1:-ridgepost-db}"
TARGET_AZ="${2:-us-east-1b}"
NEW_ID="${SRC_ID}-restored-${TARGET_AZ//-/}"
CLUSTER="${SRC_ID%-db}-api"
SERVICE="$CLUSTER"
REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }
command -v aws >/dev/null && command -v terraform >/dev/null || die "aws+terraform required"
exec 9>"${TMPDIR:-/tmp}/ridgepost-dr.lock" || die "lock"
flock -n 9 || { echo "DR already running"; exit 0; }

SUBNET_GROUP=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$SRC_ID" \
  --query 'DBInstances[0].DBSubnetGroup.DBSubnetGroupName' --output text 2>/dev/null || true)
[[ -n "$SUBNET_GROUP" && "$SUBNET_GROUP" != "None" ]] || SUBNET_GROUP="${SRC_ID%-db}-db"

ST=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$NEW_ID" \
  --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo none)
if [[ "$ST" == "available" ]]; then
  echo "reuse $NEW_ID"
elif [[ "$ST" != "none" ]]; then
  aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$NEW_ID"
else
  if ! aws rds restore-db-instance-to-point-in-time --region "$REGION" \
    --source-db-instance-identifier "$SRC_ID" --target-db-instance-identifier "$NEW_ID" \
    --use-latest-restorable-time --db-subnet-group-name "$SUBNET_GROUP" \
    --availability-zone "$TARGET_AZ" --no-publicly-accessible --manage-master-user-password >/dev/null; then
    SNAP=$(aws rds describe-db-snapshots --region "$REGION" --db-instance-identifier "$SRC_ID" \
      --snapshot-type automated --query 'reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[0].DBSnapshotIdentifier' --output text)
    [[ -n "$SNAP" && "$SNAP" != "None" ]] || die "no snapshot"
    aws rds restore-db-instance-from-db-snapshot --region "$REGION" --db-instance-identifier "$NEW_ID" \
      --db-snapshot-identifier "$SNAP" --db-subnet-group-name "$SUBNET_GROUP" \
      --availability-zone "$TARGET_AZ" --no-publicly-accessible --manage-master-user-password >/dev/null
  fi
  aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$NEW_ID"
fi
HOST=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$NEW_ID" --query 'DBInstances[0].Endpoint.Address' --output text)
SECRET=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$NEW_ID" --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
[[ -n "$HOST" && "$HOST" != "None" && -n "$SECRET" && "$SECRET" != "None" ]] || die "HOST/SECRET missing"
echo "WARNING: DR MODE ECS -> $HOST secret $SECRET (original $SRC_ID stays in TF state)"
export TF_VAR_restored_db_host="$HOST" TF_VAR_restored_secret_arn="$SECRET"
cd "$ROOT/envs/prod" && terraform apply -auto-approve
aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$SERVICE" --force-new-deployment >/dev/null
aws ecs wait services-stable --region "$REGION" --cluster "$CLUSTER" --services "$SERVICE"
ALB=$(terraform output -raw alb_dns 2>/dev/null || true)
[[ -n "$ALB" && "$ALB" != "null" ]] || ALB=$(aws elbv2 describe-load-balancers --region "$REGION" --names "${SRC_ID%-db}-alb" --query 'LoadBalancers[0].DNSName' --output text)
[[ -n "$ALB" && "$ALB" != "None" ]] || die "no ALB"
for i in $(seq 1 12); do curl -sf "https://${ALB}/healthz" && echo OK && exit 0; sleep 10; done
die "healthz failed"
