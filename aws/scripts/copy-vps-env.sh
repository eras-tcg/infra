#!/bin/bash
# Copies the four .env files of the Contabo VPS into SSM (/eras/<env>/<service>/env/*), never printing a value.
# Run from Git Bash on the PC that has the `eras-vps` SSH alias (key in the Windows ssh-agent):
#   bash infra/aws/scripts/copy-vps-env.sh
# While Contabo and AWS run side by side against the same Atlas databases, the AWS copy differs in:
#   DRIVE_INSTANCE_ID       <value>-aws: its own Drive channel and sync state, so the two servers do not take
#                           each other's channel
#   DRIVE_WEBHOOK_URL       left out: no Drive push channel until the cutover; it catches up on every start instead
#   DRIVE_CATCH_UP_ON_START true
#   CORS_ALLOWED_ORIGINS    plus the environment's CloudFront URL
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: keep /eras/... and /etc/... as they are for aws.exe and ssh.exe
here=$(cd "$(dirname "$0")" && pwd)
SSH=${SSH:-/c/Windows/System32/OpenSSH/ssh.exe}
PROFILE=${AWS_PROFILE_ERAS:-eras}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"

site_url() {
  aws cloudformation describe-stacks --profile "$PROFILE" --region us-east-2 --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='Url'].OutputValue" --output text
}

copy() {  # copy <env> <service> <remote file> <site stack>
  local env=$1 svc=$2 remote=$3 stack=$4 file="$tmp/$1-$2.env" url
  "$SSH" -o BatchMode=yes eras-vps "sudo cat $remote" > "$file"
  [ -s "$file" ] || { echo "$remote came back empty" >&2; exit 1; }
  url=$(site_url "$stack")
  # Drop the variables the AWS copy replaces, then add the AWS values.
  # NGROK_AUTH_TOKEN: without a webhook URL DriveManager would open a public ngrok tunnel to itself.
  sed -i -E '/^(DRIVE_WEBHOOK_URL|DRIVE_CATCH_UP_ON_START|NGROK_AUTH_TOKEN)=/d' "$file"
  sed -i -E "s|^(DRIVE_INSTANCE_ID=.*)$|\\1-aws|" "$file"
  sed -i -E "s|^(CORS_ALLOWED_ORIGINS=.*)$|\\1,$url|" "$file"
  if [ "$svc" = drive-manager ]; then
    echo 'DRIVE_CATCH_UP_ON_START=true' >> "$file"
    grep -q '^DRIVE_INSTANCE_ID=' "$file" || echo "DRIVE_INSTANCE_ID=$env-aws" >> "$file"
  fi
  echo "== $env/$svc"
  bash "$here/env-to-ssm.sh" "$env" "$svc" "$file"
}

copy prod drive-manager /etc/drive-manager/.env ErasSiteProd
copy staging drive-manager /etc/drive-manager-staging/.env ErasSiteStaging
copy prod users-service /etc/users-service/.env ErasSiteProd
copy staging users-service /etc/users-service-staging/.env ErasSiteStaging
echo "done; the server picks them up on its next eras-up (deploy or restart)"
