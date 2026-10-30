#!/bin/bash
# deploy-backend.sh <prod|staging> <drive-manager|users-service> <image uri in ECR>
# Runs eras-deploy on the server (starting it if it sleeps): healthcheck and automatic rollback included.
# Exits non-zero when the deploy failed; prints the server's output either way.
set -euo pipefail
env=${1:-} svc=${2:-} image=${3:-}
if ! [[ "$env" =~ ^(prod|staging)$ && "$svc" =~ ^(drive-manager|users-service)$ && -n "$image" ]]; then
  echo "usage: deploy-backend.sh <prod|staging> <drive-manager|users-service> <image>" >&2
  exit 2
fi
exec bash "$(dirname "$0")/server-run.sh" eras-deploy "$env" "$svc" "$image"
