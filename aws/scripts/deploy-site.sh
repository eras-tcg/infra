#!/bin/bash
# deploy-site.sh <prod|staging> <dist/eras-web/browser>
# Uploads the Angular build (configuration "aws") to the environment's bucket and invalidates CloudFront.
# Hashed files are cached for a year; index.html and the rest are revalidated on every visit.
# The build may carry the Android app under app/ (ERAS.apk, web-<version>.zip, app-update.json: eras-web's CI, when
# the APK is signed); a build without it leaves the published app/ as it is.
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
# No Android app in this build (not signed): the one published before stays (excluded paths are not deleted)
keep_app=()
[ -f "$dir/app/app-update.json" ] || keep_app=(--exclude 'app/*')
aws s3 sync "${PROFILE_ARGS[@]}" "$dir" "s3://$bucket" --delete \
  --exclude '*-????????.js' --exclude '*-????????.css' "${keep_app[@]}" \
  --cache-control 'no-cache'
# The web app manifest needs its own content type (sync would send it as plain application/json)
if [ -f "$dir/manifest.json" ]; then
  aws s3 cp "${PROFILE_ARGS[@]}" "$dir/manifest.json" "s3://$bucket/manifest.json" \
    --content-type 'application/manifest+json' --cache-control 'no-cache'
fi
# The Android app's APK with its own content type (browsers then offer to install it; sync guesses from the runner)
if [ -f "$dir/app/ERAS.apk" ]; then
  aws s3 cp "${PROFILE_ARGS[@]}" "$dir/app/ERAS.apk" "s3://$bucket/app/ERAS.apk" \
    --content-type 'application/vnd.android.package-archive' --cache-control 'no-cache' \
    --content-disposition 'attachment; filename="ERAS.apk"'
fi
# The service worker's files are invalidated with the page, so an installed app sees a new version at once; the
# Android app's files too (its update check and the APK's download)
aws cloudfront create-invalidation "${PROFILE_ARGS[@]}" --distribution-id "$distribution" \
  --paths '/index.html' '/' '/ngsw.json' '/eras-sw.js' '/eras-pictures-sw.js' '/ngsw-worker.js' '/manifest.json' '/app/*' >/dev/null
echo "uploaded to s3://$bucket, invalidated $distribution"
