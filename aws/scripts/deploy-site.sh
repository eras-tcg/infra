#!/bin/bash
# deploy-site.sh <prod|staging> <dist/eras-web/browser>
# Uploads the Angular build (configuration "aws") to the environment's bucket and invalidates CloudFront.
# Hashed files are cached for a year; index.html and the rest are revalidated on every visit.
# In CI the same steps run with the eras-ci credentials.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: keep /eras/... and /etc/... as they are for aws.exe and ssh.exe
PROFILE_ARGS=()
[ -n "${AWS_ACCESS_KEY_ID:-}" ] || PROFILE_ARGS=(--profile "${AWS_PROFILE_ERAS:-eras}")
REGION=us-east-2
env=${1:-} dir=${2:-}
if ! [[ "$env" =~ ^(prod|staging)$ && -d "$dir" ]]; then
  echo "usage: deploy-site.sh <prod|staging> <build dir>" >&2
  exit 2
fi
stack=$([ "$env" = prod ] && echo ErasSiteProd || echo ErasSiteStaging)
output() {
  aws cloudformation describe-stacks "${PROFILE_ARGS[@]}" --region "$REGION" --stack-name "$stack" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
bucket=$(output BucketName)
distribution=$(output DistributionId)

# Hashed bundles (main-AbCd1234.js, chunk-…, styles-….css) are kept from earlier builds: a page loaded before
# this deploy may still ask for its lazy chunks.
hashed=(--include '*-????????.js' --include '*-????????.css')
aws s3 sync "${PROFILE_ARGS[@]}" "$dir" "s3://$bucket" --exclude '*' "${hashed[@]}" \
  --cache-control 'public, max-age=31536000, immutable'
aws s3 sync "${PROFILE_ARGS[@]}" "$dir" "s3://$bucket" --delete \
  --exclude '*-????????.js' --exclude '*-????????.css' \
  --cache-control 'no-cache'
aws cloudfront create-invalidation "${PROFILE_ARGS[@]}" --distribution-id "$distribution" --paths '/index.html' '/' >/dev/null
echo "uploaded to s3://$bucket, invalidated $distribution"
