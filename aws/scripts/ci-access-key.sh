#!/bin/bash
# Creates a new access key for eras-ci and stores it straight into the eras-tcg organization's Actions secrets
# (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY); the key is never printed. Run again to rotate (every 90 days):
# it deletes the older key once the new one is stored. Needs `gh` logged in as an org admin.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: keep /eras/... and /etc/... as they are for aws.exe and ssh.exe
PROFILE=${AWS_PROFILE_ERAS:-eras}
ORG=eras-tcg
USER_NAME=eras-ci
gh_() { env -u GH_TOKEN gh "$@"; }   # GH_TOKEN on this PC belongs to another account

old=$(aws iam list-access-keys --profile "$PROFILE" --user-name "$USER_NAME" --query 'AccessKeyMetadata[].AccessKeyId' --output text)
if [ "$(wc -w <<<"$old")" -ge 2 ]; then
  echo "$USER_NAME already has two keys; delete one first" >&2
  exit 1
fi

key=$(aws iam create-access-key --profile "$PROFILE" --user-name "$USER_NAME" --output json)
jq -r .AccessKey.AccessKeyId <<<"$key" | gh_ secret set AWS_ACCESS_KEY_ID --org "$ORG" --visibility all
jq -r .AccessKey.SecretAccessKey <<<"$key" | gh_ secret set AWS_SECRET_ACCESS_KEY --org "$ORG" --visibility all
unset key
echo "new key stored in $ORG secrets"

for id in $old; do
  aws iam delete-access-key --profile "$PROFILE" --user-name "$USER_NAME" --access-key-id "$id"
  echo "deleted old key $id"
done
