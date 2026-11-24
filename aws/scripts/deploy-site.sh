#!/bin/bash
# deploy-site.sh <prod|staging> <dist/eras-web/browser>
# Uploads the Angular build (configuration "aws") to the environment's bucket and invalidates CloudFront.
# Hashed files are cached for a year; index.html and the rest are revalidated on every visit.
# The build may carry the apps under app/ (eras-web's CI): the Android app (ERAS.apk, web-<version>.zip,
# app-update.json, when the APK is signed) and the Windows app (ERAS-Setup.exe, desktop.json, and latest.yml with the
# installer's blockmap for the app's own updates). Each is published
# only when the build carries it; one missing leaves the one published before as it is.
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
# The apps under app/ go on their own below (excluded paths are not deleted)
aws s3 sync "${PROFILE_ARGS[@]}" "$dir" "s3://$bucket" --delete \
  --exclude '*-????????.js' --exclude '*-????????.css' --exclude 'app/*' \
  --cache-control 'no-cache'
# The Android app, when this build carries it (signed): its files replace the published ones (old zips deleted)
if [ -f "$dir/app/app-update.json" ]; then
  aws s3 sync "${PROFILE_ARGS[@]}" "$dir/app" "s3://$bucket/app" --delete \
    --exclude '*' --include 'app-update.json' --include 'web-*.zip' --include 'ERAS.apk' \
    --cache-control 'no-cache'
fi
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
# The Windows app, when this build carries it: the installer as a download, then its manifest (what the site offers)
if [ -f "$dir/app/desktop.json" ]; then
  aws s3 cp "${PROFILE_ARGS[@]}" "$dir/app/ERAS-Setup.exe" "s3://$bucket/app/ERAS-Setup.exe" \
    --content-type 'application/vnd.microsoft.portable-executable' --cache-control 'no-cache' \
    --content-disposition 'attachment; filename="ERAS-Setup.exe"'
  # What the installed app reads to update itself (electron-updater): the installer's blockmap, then latest.yml
  # last, so it never names an installer not uploaded yet
  if [ -f "$dir/app/latest.yml" ]; then
    aws s3 cp "${PROFILE_ARGS[@]}" "$dir/app/ERAS-Setup.exe.blockmap" "s3://$bucket/app/ERAS-Setup.exe.blockmap"       --content-type 'application/octet-stream' --cache-control 'no-cache'
    aws s3 cp "${PROFILE_ARGS[@]}" "$dir/app/latest.yml" "s3://$bucket/app/latest.yml"       --content-type 'text/yaml' --cache-control 'no-cache'
  fi
  aws s3 cp "${PROFILE_ARGS[@]}" "$dir/app/desktop.json" "s3://$bucket/app/desktop.json" \
    --content-type 'application/json' --cache-control 'no-cache'
fi
# The service worker's files are invalidated with the page, so an installed app sees a new version at once; the
# apps' files too (the Android app's update check, the APK's and the installer's downloads)
aws cloudfront create-invalidation "${PROFILE_ARGS[@]}" --distribution-id "$distribution" \
  --paths '/index.html' '/' '/ngsw.json' '/eras-sw.js' '/eras-pictures-sw.js' '/ngsw-worker.js' '/manifest.json' '/app/*' >/dev/null
echo "uploaded to s3://$bucket, invalidated $distribution"
