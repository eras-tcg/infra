#!/usr/bin/env bash
# One-time VPS setup for GitHub Actions deploys (run as root).
#   - creates user github-runner (no password, member of docker, NOT a general sudoer)
#   - lets it read the service .env files and run only eras-nginx-apply via sudo
#   - installs the org-level self-hosted runner (label eras-vps) as a systemd service
#
# Usage: sudo bash setup-runner.sh <registration-token>
#   token: gh api -X POST orgs/eras-tcg/actions/runners/registration-token --jq .token  (valid 1 h)
set -euo pipefail

token="${1:?registration token}"
org_url="https://github.com/eras-tcg"
user="github-runner"
home="/home/$user"
here="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" = "0" ] || { echo "run as root" >&2; exit 1; }

id "$user" >/dev/null 2>&1 || useradd -m -s /bin/bash "$user"
usermod -aG docker "$user"

# Service env files: readable by the runner (docker CLI reads --env-file client side), not by others.
for d in /etc/drive-manager /etc/drive-manager-staging /etc/users-service /etc/users-service-staging; do
  [ -d "$d" ] || continue
  chgrp "$user" "$d" && chmod 750 "$d"
  for f in "$d/.env" "$d/drive-service-account.json"; do
    [ -f "$f" ] && chgrp "$user" "$f" && chmod 640 "$f"
  done
done

install -m 0755 -o root -g root "$here/eras-nginx-apply" /usr/local/sbin/eras-nginx-apply
echo "$user ALL=(root) NOPASSWD: /usr/local/sbin/eras-nginx-apply" > /etc/sudoers.d/eras-github-runner
chmod 0440 /etc/sudoers.d/eras-github-runner
visudo -cf /etc/sudoers.d/eras-github-runner

# Runner binary (latest release)
version=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | grep -oP '"tag_name":\s*"v\K[^"]+')
runner_dir="$home/actions-runner"
mkdir -p "$runner_dir"
if [ ! -x "$runner_dir/config.sh" ]; then
  curl -fsSL -o /tmp/actions-runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v${version}/actions-runner-linux-x64-${version}.tar.gz"
  tar -xzf /tmp/actions-runner.tar.gz -C "$runner_dir"
  rm -f /tmp/actions-runner.tar.gz
fi
chown -R "$user:$user" "$runner_dir"
"$runner_dir/bin/installdependencies.sh" >/dev/null

sudo -u "$user" bash -c "cd '$runner_dir' && ./config.sh --unattended --replace \
  --url '$org_url' --token '$token' --name 'eras-vps' --labels 'eras-vps' --work _work"

cd "$runner_dir"
./svc.sh install "$user"
./svc.sh start
./svc.sh status | head -5
echo "runner ready (label eras-vps, runner v${version})"
