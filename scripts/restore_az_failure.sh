#!/usr/bin/env bash
# Restore ridgepost-db after us-east-1a failure (single-AZ RDS + shared NAT SPOF).
# Usage: ./scripts/restore_az_failure.sh [source-identifier] [target-az]
# RTO ~25-35 min: restore 12-18 + terraform apply 2-5 + ECS healthz 3-5 + buffer.
# VPCE (ecr/secrets/logs) keeps AWS API path if NAT AZ is down.
set -euo pipefail

SRC_ID="${1:-ridgepost-db}"
TARGET_AZ="${2:-us-east-1b}"
NEW_ID="${SRC_ID}-restored-${TARGET_AZ//-/}"
SUBNET_GROUP="${SRC_ID}"
CLUSTER="${SRC_ID%-db}-api"
SERVICE="${SRC_ID%-db}-api"
REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

command -v aws >/dev/null || die "aws CLI required"
command -v terraform >/dev/null || die "terraform required"
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

echo "==> 3/5 NAT SPOF note: single NAT in us-east-1a — non-AWS HTTPS egress dead until rebuilt."
echo "    Interface VPCE (ecr.api/ecr.dkr/secretsmanager/logs) keep AWS API path without NAT."

echo "==> 4/5 DR mode: export TF_VAR overrides and terraform apply (rewires ECS in state)"
export TF_VAR_restored_db_host="${HOST}"
export TF_VAR_restored_secret_arn="${SECRET}"
cd "${ROOT}/envs/prod"
terraform apply -auto-approve
# coalesce() in envs/prod wires module.compute db_host + secret_arn from restored vars.
# Original aws_db_instance.this remains in state (prevent_destroy); retire manually after cutover.

echo "==> 5/6 Force ECS roll after apply registers new task def"
aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$SERVICE" \
  --force-new-deployment >/dev/null
aws ecs wait services-stable --region "$REGION" --cluster "$CLUSTER" --services "$SERVICE"

echo "==> 6/6 Verify ALB /healthz (post-restore smoke test)"
ALB_DNS=$(terraform output -raw alb_dns 2>/dev/null || true)
if [[ -z "$ALB_DNS" || "$ALB_DNS" == "null" ]]; then
  ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --names "${SRC_ID%-db}-alb" --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || true)
fi
[[ -n "$ALB_DNS" && "$ALB_DNS" != "None" ]] || die "could not resolve ALB DNS for health check"
for i in $(seq 1 12); do
  if curl -sf "https://${ALB_DNS}/healthz" >/dev/null; then
    echo "    OK https://${ALB_DNS}/healthz"
    echo "Done. RTO budget ~25-35 min = restore 12-18 + apply 2-5 + healthz 3-5 + buffer."
    exit 0
  fi
  echo "    waiting for /healthz (${i}/12)..."
  sleep 10
done
die "ALB /healthz did not return 200 after restore"
