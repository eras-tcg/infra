#!/bin/bash
# Once, before the first deploy: the random secret CloudFront sends to the server and the wake function.
# Rotating it: run with --rotate, then `cdk deploy ErasBackend ErasSiteProd ErasSiteStaging` and restart eras.service.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: keep /eras/... and /etc/... as they are for aws.exe and ssh.exe
PROFILE=${AWS_PROFILE_ERAS:-eras}
REGION=us-east-2
NAME=/eras/infra/origin-secret

if aws ssm get-parameter --profile "$PROFILE" --region "$REGION" --name "$NAME" >/dev/null 2>&1 && [ "${1:-}" != --rotate ]; then
  echo "$NAME already exists (use --rotate to replace it)"
  exit 0
fi
aws ssm put-parameter --profile "$PROFILE" --region "$REGION" --name "$NAME" --type String --overwrite \
  --description 'Header X-Eras-Origin: CloudFront -> server and wake function' \
  --value "$(openssl rand -hex 24)" >/dev/null
echo "$NAME written"
