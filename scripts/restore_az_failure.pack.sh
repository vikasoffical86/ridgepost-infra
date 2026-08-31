#!/usr/bin/env bash
# Compact DR script for pack; full version in repo scripts/restore_az_failure.sh
set -euo pipefail
SRC_ID="${1:-ridgepost-db}"; TARGET_AZ="${2:-us-east-1b}"
NEW_ID="${SRC_ID}-restored-${TARGET_AZ//-/}"; REGION="${AWS_REGION:-us-east-1}"
die(){ echo "ERROR: $*" >&2; exit 1; }
SNAP=$(aws rds describe-db-snapshots --region "$REGION" --db-instance-identifier "$SRC_ID" --snapshot-type automated --query 'reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[0].DBSnapshotIdentifier' --output text)
[[ -n "$SNAP" && "$SNAP" != "None" ]] || die "no automated snapshot"
aws rds restore-db-instance-from-db-snapshot --region "$REGION" --db-instance-identifier "$NEW_ID" --db-snapshot-identifier "$SNAP" --db-subnet-group-name "$SRC_ID" --availability-zone "$TARGET_AZ" --no-publicly-accessible --manage-master-user-password
aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$NEW_ID"
HOST=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$NEW_ID" --query 'DBInstances[0].Endpoint.Address' --output text)
SECRET=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$NEW_ID" --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
[[ -n "$HOST" && "$HOST" != "None" ]] || die "restored endpoint missing"
[[ -n "$SECRET" && "$SECRET" != "None" ]] || die "managed secret missing"
export TF_VAR_restored_db_host="$HOST" TF_VAR_restored_secret_arn="$SECRET"
cd envs/prod && terraform apply -auto-approve
aws ecs update-service --region "$REGION" --cluster ridgepost-api --service ridgepost-api --force-new-deployment
aws ecs wait services-stable --region "$REGION" --cluster ridgepost-api --services ridgepost-api
ALB=$(terraform output -raw alb_dns)
for i in $(seq 1 12); do curl -sf "https://${ALB}/healthz" && exit 0; sleep 10; done
die "ALB /healthz failed post-restore"
