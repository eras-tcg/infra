#!/bin/bash
# deploy-backend.sh <prod|staging> <drive-manager|users-service> <image uri in ECR>
# Starts the server if it sleeps, waits for it and runs eras-deploy there through SSM (healthcheck and automatic
# rollback included). Exits non-zero when the deploy failed; prints the server's output either way.
# In CI the same steps run with the eras-ci credentials.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: keep /eras/... and /etc/... as they are for aws.exe and ssh.exe
PROFILE_ARGS=()
[ -n "${AWS_ACCESS_KEY_ID:-}" ] || PROFILE_ARGS=(--profile "${AWS_PROFILE_ERAS:-eras}")
REGION=us-east-2
env=${1:-} svc=${2:-} image=${3:-}
if ! [[ "$env" =~ ^(prod|staging)$ && "$svc" =~ ^(drive-manager|users-service)$ && -n "$image" ]]; then
  echo "usage: deploy-backend.sh <prod|staging> <drive-manager|users-service> <image>" >&2
  exit 2
fi
aws_() { aws "${PROFILE_ARGS[@]}" --region "$REGION" "$@"; }

instance=$(aws_ ec2 describe-instances --filters Name=tag:aws:cloudformation:stack-name,Values=ErasBackend \
  Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[0].Instances[0].InstanceId' --output text)
state=$(aws_ ec2 describe-instances --instance-ids "$instance" --query 'Reservations[0].Instances[0].State.Name' --output text)
if [ "$state" = stopping ]; then aws_ ec2 wait instance-stopped --instance-ids "$instance"; state=stopped; fi
if [ "$state" = stopped ]; then
  echo "starting $instance"
  aws_ ec2 start-instances --instance-ids "$instance" >/dev/null
fi
aws_ ec2 wait instance-status-ok --instance-ids "$instance"

# eras.service must have finished its first start before a deploy (ssm agent comes up before it).
command=$(aws_ ssm send-command --instance-ids "$instance" --document-name AWS-RunShellScript \
  --comment "eras-deploy $env $svc" --timeout-seconds 900 \
  --parameters "commands=[\"systemctl is-active --quiet eras.service || systemctl start eras.service\",\"/usr/local/bin/eras-sync\",\"/opt/eras/current/bin/eras-deploy $env $svc $image\"]" \
  --query Command.CommandId --output text)
echo "ssm command $command"
status=InProgress
while [[ "$status" =~ ^(Pending|InProgress|Delayed)$ ]]; do
  sleep 10
  status=$(aws_ ssm get-command-invocation --command-id "$command" --instance-id "$instance" --query Status --output text 2>/dev/null || echo Pending)
done
aws_ ssm get-command-invocation --command-id "$command" --instance-id "$instance" \
  --query '[StandardOutputContent, StandardErrorContent]' --output text
echo "status: $status"
[ "$status" = Success ]
