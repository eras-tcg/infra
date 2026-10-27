#!/usr/bin/env bash
# SSH + host hardening for the ERAS VPS (run as root, keep your current session open).
#   - admin user with sudo, login by SSH key only
#   - no root login, no password logins
#   - ufw: only 22/80/443 inbound; fail2ban for sshd; unattended security upgrades
#
# Usage: sudo bash harden-ssh.sh <admin-user> "<ssh public key>"
# Test BEFORE closing this session:  ssh <admin-user>@<server>  and  sudo -v
set -euo pipefail

admin="${1:?admin user}"; pubkey="${2:?public key}"
[ "$(id -u)" = "0" ] || { echo "run as root" >&2; exit 1; }
case "$pubkey" in ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*) ;; *) echo "not an SSH public key" >&2; exit 1 ;; esac

# Admin user (sudo without password: login itself already requires the private key)
id "$admin" >/dev/null 2>&1 || useradd -m -s /bin/bash "$admin"
usermod -aG sudo,docker "$admin"
install -d -m 700 -o "$admin" -g "$admin" "/home/$admin/.ssh"
touch "/home/$admin/.ssh/authorized_keys"
grep -qxF "$pubkey" "/home/$admin/.ssh/authorized_keys" || echo "$pubkey" >> "/home/$admin/.ssh/authorized_keys"
chown "$admin:$admin" "/home/$admin/.ssh/authorized_keys"; chmod 600 "/home/$admin/.ssh/authorized_keys"
echo "$admin ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$admin"; chmod 440 "/etc/sudoers.d/90-$admin"
visudo -cf "/etc/sudoers.d/90-$admin"

# sshd: first value wins, so this drop-in sorts before cloud-init's 50-cloud-init.conf
cat > /etc/ssh/sshd_config.d/00-eras-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
EOF
sshd -t
systemctl reload ssh

# Firewall (docker-published ports are bound to 127.0.0.1 by deploy.sh, nginx serves 80/443)
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw fail2ban unattended-upgrades >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null

cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl enable --now fail2ban >/dev/null 2>&1; systemctl restart fail2ban

dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true

echo "== done"
echo "sshd: $(sshd -T 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication) ' | tr '\n' ' ')"
ufw status | head -8
echo "NOW test from another terminal: ssh $admin@<server> 'sudo -v && echo ok'  (keep this session open until it works)"
