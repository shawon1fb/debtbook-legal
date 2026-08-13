#!/usr/bin/env bash
#
# Provision the VPS — reads deploy/.env, no IP/password typing.
# Runs provision-vps.sh ON the server by piping it in over SSH.
#
#     bash deploy/scripts/provision.sh
#
# Connects as root (the only user on a fresh box) using the root password from
# deploy/.env, and installs Docker + the `deploy` user + swap + firewall.
# After this, deploys use the `deploy` user + SSH key (see remote-deploy.sh).
#
# deploy/.env keys used:
#   DEPLOY_SSH_HOST            server IP            (required)
#   DEPLOY_SSH_PORT            ssh port             (default 22)
#   DEPLOY_SSH_USER            user to create       (default deploy)
#   DEPLOY_PROVISION_USER      who to log in as     (default root)
#   DEPLOY_ROOT_PASSWORD       root password        (falls back to DEPLOY_SSH_PASSWORD)
set -euo pipefail

cd "$(dirname "$0")/../.."   # repo root

ENV_FILE="deploy/.env"
[ -f "$ENV_FILE" ] || { echo "❌ $ENV_FILE not found — cp deploy/.env.example $ENV_FILE first."; exit 1; }
set -a; . "$ENV_FILE"; set +a

HOST="${DEPLOY_SSH_HOST:?set DEPLOY_SSH_HOST in deploy/.env}"
PORT="${DEPLOY_SSH_PORT:-22}"
USER="${DEPLOY_PROVISION_USER:-root}"
PASS="${DEPLOY_ROOT_PASSWORD:-${DEPLOY_SSH_PASSWORD:-}}"
TARGET="${USER}@${HOST}"

DEPLOY_USER_NAME="${DEPLOY_SSH_USER:-deploy}"   # the non-root user to create
SSH_OPTS=(-p "$PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
SCRIPT="deploy/scripts/provision-vps.sh"

# Ensure a local SSH key exists, then hand its PUBLIC half to the server so the
# `deploy` user can be reached by key right after provisioning (it is created
# password-less, so a key is the only way in).
PUBKEY_FILE=""
for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
  [ -f "$k" ] && { PUBKEY_FILE="$k"; break; }
done
if [ -z "$PUBKEY_FILE" ]; then
  echo "▶ No SSH key on this machine — generating ~/.ssh/id_ed25519"
  ssh-keygen -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -q
  PUBKEY_FILE="$HOME/.ssh/id_ed25519.pub"
fi
PUBKEY_B64="$(base64 < "$PUBKEY_FILE" | tr -d '\n')"
REMOTE_ENV="DEPLOY_USER='${DEPLOY_USER_NAME}' DEPLOY_PUBKEY_B64='${PUBKEY_B64}'"

echo "▶ Provisioning ${TARGET}:${PORT}  (will create user '${DEPLOY_USER_NAME}' + install your key)"

# Reachability first — a dead box and a bad key fail very differently, and the
# SSH errors don't make that obvious.
if ! nc -z -G 6 -w 6 "$HOST" "$PORT" 2>/dev/null; then
  echo "❌ ${HOST}:${PORT} is not answering (TCP connect timed out/refused)."
  echo "   This is a network problem, not an auth problem. Check, in order:"
  echo "     1. Is the VM powered on and finished building? (provider panel)"
  echo "     2. Cloud firewall / security group — allow 22, 80, 443 inbound."
  echo "     3. Use the panel's VNC console: ip a / systemctl status ssh / ufw status"
  echo "     4. Non-standard SSH port? set DEPLOY_SSH_PORT in deploy/.env"
  echo "   Probe by hand:  nc -vz ${HOST} ${PORT}   ping -c3 ${HOST}"
  exit 1
fi

# Key-based first; fall back to password via sshpass (root login on a fresh box).
if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$TARGET" true 2>/dev/null; then
  ssh "${SSH_OPTS[@]}" "$TARGET" "${REMOTE_ENV} bash -s" < "$SCRIPT"
elif [ -n "$PASS" ]; then
  command -v sshpass >/dev/null 2>&1 || { echo "❌ need 'sshpass' to use the password (brew install hudochenkov/sshpass/sshpass | apt install sshpass)"; exit 1; }
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$TARGET" "${REMOTE_ENV} bash -s" < "$SCRIPT"
else
  echo "❌ ${TARGET} answers on :${PORT}, but no SSH key is authorised there and"
  echo "   DEPLOY_ROOT_PASSWORD is empty in deploy/.env — set it (fresh-box root"
  echo "   password), or run: ssh-copy-id -p ${PORT} ${TARGET}"
  exit 1
fi

echo
echo "✅ Provisioned ${HOST}. Next:"
echo "   bash scripts/docker-publish.sh          # build + push the image"
echo "   bash deploy/scripts/remote-deploy.sh    # server pulls it"
echo "   bash deploy/scripts/remote-proxy.sh     # HTTPS via Caddy"
