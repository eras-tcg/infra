#!/usr/bin/env bash
# Deploy one ERAS service on the VPS with health check and automatic rollback.
# Runs on the self-hosted GitHub Actions runner (user github-runner, member of group docker).
#
# Usage: deploy.sh <service> <environment> <image>
#   service:     drive-manager | users-service | eras-frontend
#   environment: staging | prod
#   image:       e.g. ghcr.io/eras-tcg/drive-manager:<sha>
#
# Container names, ports, network and env files match the old Jenkinsfiles, so nginx
# upstreams and /etc/<service>[-staging]/.env keep working unchanged.
set -euo pipefail

svc="${1:?service}"; env="${2:?environment}"; image="${3:?image}"
network="eras-network"
health_timeout=120

case "$env" in
  staging) suffix="-staging"; etc_suffix="-staging" ;;
  prod)    suffix="-prod";    etc_suffix="" ;;
  *) echo "unknown environment: $env" >&2; exit 2 ;;
esac
name="${svc}${suffix}"

case "$svc:$env" in
  drive-manager:staging) port=8091; container_port=8081 ;;
  drive-manager:prod)    port=8081; container_port=8081 ;;
  users-service:staging) port=8090; container_port=8090 ;;
  users-service:prod)    port=8082; container_port=8082 ;;
  eras-frontend:staging) port=3001; container_port=80 ;;
  eras-frontend:prod)    port=3000; container_port=80 ;;
  *) echo "unknown service: $svc" >&2; exit 2 ;;
esac

run_args=(-d --name "$name" --restart unless-stopped --network "$network" -p "${port}:${container_port}")
case "$svc" in
  drive-manager)
    etc="/etc/drive-manager${etc_suffix}"
    run_args+=(--env-file "$etc/.env" -v "$etc/drive-service-account.json:$etc/drive-service-account.json:ro") ;;
  users-service)
    run_args+=(--env-file "/etc/users-service${etc_suffix}/.env") ;;
esac

# Health check hits the database where possible, not just "process is up".
healthy() {
  local code
  case "$svc" in
    drive-manager)
      code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:${port}/api/cards/search/edition?edition=ST1" || true)
      [ "$code" = "200" ] ;;
    users-service)
      # Non-existent user -> 401 means the service answered after querying MongoDB.
      code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
        -d '{"username":"healthcheck_probe","password":"Xx1!xxxxxx"}' "http://127.0.0.1:${port}/api/auth/login" || true)
      [ "$code" = "401" ] ;;
    eras-frontend)
      code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:${port}/" || true)
      [ "$code" = "200" ] ;;
  esac
}

wait_healthy() {
  local waited=0
  while [ $waited -lt $health_timeout ]; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != "true" ]; then
      echo "container $name is not running"; return 1
    fi
    if healthy; then echo "healthy after ${waited}s"; return 0; fi
    sleep 5; waited=$((waited + 5))
  done
  echo "not healthy after ${health_timeout}s"; return 1
}

start() { docker rm -f "$name" >/dev/null 2>&1 || true; docker run "${run_args[@]}" "$1" >/dev/null; }

echo "::group::pull $image"
docker pull "$image"
echo "::endgroup::"

previous=$(docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null || true)
echo "deploying $name: ${previous:-<none>} -> $image"

start "$image"
if wait_healthy; then
  echo "deployed $name ($image)"
else
  echo "::error::deploy of $name failed health check, last logs:"
  docker logs --tail 60 "$name" 2>&1 || true
  if [ -n "$previous" ] && [ "$previous" != "$image" ]; then
    echo "rolling back to $previous"
    start "$previous"
    wait_healthy || echo "::error::rollback of $name is also unhealthy"
  fi
  exit 1
fi

# Frontend owns its nginx vhost (same as the old Jenkinsfile).
if [ "$svc" = "eras-frontend" ] && [ -n "${NGINX_VHOST_FILE:-}" ]; then
  vhost_name=$([ "$env" = "prod" ] && echo "erastcg.com" || echo "staging.erastcg.com")
  sudo /usr/local/sbin/eras-nginx-apply "$NGINX_VHOST_FILE" "$vhost_name"
fi

# Keep disk in check: drop unused images older than 14 days (running/rollback images stay).
docker image prune -af --filter "until=336h" >/dev/null 2>&1 || true
