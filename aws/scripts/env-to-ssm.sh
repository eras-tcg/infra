#!/bin/bash
# env-to-ssm.sh <prod|staging> <drive-manager|users-service> <file.env>
# Stores each KEY=VALUE of a .env file as the SecureString /eras/<env>/<service>/env/KEY, which eras-up turns
# back into the container's env file. Values are never printed. Variables missing from the file are left as they are;
# remove one with: aws ssm delete-parameter --profile eras --region us-east-2 --name /eras/<env>/<service>/env/KEY
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: keep /eras/... and /etc/... as they are for aws.exe and ssh.exe
PROFILE=${AWS_PROFILE_ERAS:-eras}
REGION=us-east-2
env=${1:-} svc=${2:-} file=${3:-}
if ! [[ "$env" =~ ^(prod|staging)$ && "$svc" =~ ^(drive-manager|users-service)$ && -f "$file" ]]; then
  echo "usage: env-to-ssm.sh <prod|staging> <drive-manager|users-service> <file.env>" >&2
  exit 2
fi

count=0
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
  key=${line%%=*}
  value=${line#*=}
  # Strip one level of surrounding quotes, as docker --env-file does not.
  if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then value=${BASH_REMATCH[1]}; fi
  [ -n "$value" ] || { echo "skip $key (empty)"; continue; }
  aws ssm put-parameter --profile "$PROFILE" --region "$REGION" --name "/eras/$env/$svc/env/$key" \
    --type SecureString --overwrite --value "$value" >/dev/null
  echo "set $key"
  count=$((count + 1))
done < "$file"
echo "$count variables stored under /eras/$env/$svc/env/"
