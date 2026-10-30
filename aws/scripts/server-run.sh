#!/bin/bash
# server-run.sh <eras-* command and its arguments>
# Starts the server if it sleeps, waits for it and runs /opt/eras/current/bin/<command> there through SSM, after
# eras.service has started and the server's scripts are synced. Prints the server's output and exits non-zero
# when the command failed. Used by deploy-backend.sh and backup-mongo.sh, locally (profile eras) or in CI.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: keep /eras/... and /etc/... as they are for aws.exe and ssh.exe
PROFILE_ARGS=()
[ -n "${AWS_ACCESS_KEY_ID:-}" ] || PROFILE_ARGS=(--profile "${AWS_PROFILE_ERAS:-eras}")
REGION=us-east-2
if ! [[ "${1:-}" =~ ^eras-[a-z]+$ ]]; then
  echo "usage: server-run.sh <eras-command> [arguments]" >&2
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

# The ssm agent comes up before eras.service has finished its first start.
# SSM takes a comment of 100 characters at most (a deploy's arguments carry the whole image URI)
comment="$*"
command=$(aws_ ssm send-command --instance-ids "$instance" --document-name AWS-RunShellScript \
  --comment "${comment:0:100}" --timeout-seconds 900 \
  --parameters "commands=[\"systemctl is-active --quiet eras.service || systemctl start eras.service\",\"/usr/local/bin/eras-sync\",\"/opt/eras/current/bin/$*\"]" \
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
