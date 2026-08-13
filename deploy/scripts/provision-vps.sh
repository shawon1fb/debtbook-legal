#!/usr/bin/env bash
#
# Runs ON the server (piped in by deploy/scripts/provision.sh — don't run it
# from your Mac). Fresh Ubuntu/Debian box → ready to receive deploys:
#
#   1. apt update + base packages
#   2. Docker Engine + compose plugin (official get.docker.com script)
#   3. a non-root `deploy` user in the docker group, with your SSH key
#   4. 2 GB swap file if the box has none (small VPS OOM guard)
#   5. ufw: allow SSH + 80 + 443, deny the rest
#
# Idempotent — safe to re-run. Root login stays as-is; nothing is locked out.
#
# Env in:
#   DEPLOY_USER        user to create        (default deploy)
#   DEPLOY_PUBKEY_B64  base64 of your id_*.pub (required — it's the only way in
#                      for the new user, which is created without a password)
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
PUBKEY_B64="${DEPLOY_PUBKEY_B64:?DEPLOY_PUBKEY_B64 not passed in}"
PUBKEY="$(printf '%s' "$PUBKEY_B64" | base64 -d)"

[ "$(id -u)" = "0" ] || { echo "❌ must run as root"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

echo "── 1/5 base packages ──"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg ufw >/dev/null

echo "── 2/5 docker ──"
if command -v docker >/dev/null 2>&1; then
  echo "   already installed: $(docker --version)"
else
  curl -fsSL https://get.docker.com | sh >/dev/null
  echo "   installed: $(docker --version)"
fi
systemctl enable --now docker >/dev/null 2>&1 || true
docker compose version >/dev/null 2>&1 || apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 || true

echo "── 3/5 user '${DEPLOY_USER}' ──"
if id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  echo "   exists"
else
  # No password — key-only login by design.
  useradd -m -s /bin/bash "$DEPLOY_USER"
  echo "   created"
fi
usermod -aG docker "$DEPLOY_USER"

HOME_DIR="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "${HOME_DIR}/.ssh"
AUTH="${HOME_DIR}/.ssh/authorized_keys"
touch "$AUTH"
grep -qxF "$PUBKEY" "$AUTH" || printf '%s\n' "$PUBKEY" >> "$AUTH"
chmod 600 "$AUTH"; chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTH"
echo "   ssh key installed → ${AUTH}"

echo "── 4/5 swap ──"
if [ "$(swapon --show --noheadings | wc -l)" -gt 0 ]; then
  echo "   already present"
else
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "   2G swapfile added"
fi

echo "── 5/5 firewall ──"
ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null
ufw allow 80/tcp  >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null
echo "   $(ufw status | head -1)"
# NOTE: Docker writes its own iptables rules, so a container's published port is
# reachable even if ufw would deny it. Only publish ports you mean to expose —
# the site container publishes none; Caddy publishes 80/443.

echo
echo "✅ Server ready."
echo "   docker : $(docker --version)"
echo "   user   : ${DEPLOY_USER} (docker group, key-only login)"
