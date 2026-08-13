#!/usr/bin/env bash
#
# Deploy the site — pulls the image from Docker Hub onto the server.
# Nothing is built here; publish first with `scripts/docker-publish.sh`.
#
#     bash deploy/scripts/remote-deploy.sh            # uses DEPLOY_TAG from deploy/.env
#     bash deploy/scripts/remote-deploy.sh 0.0.2      # override the tag (rollback too)
#
# Reads deploy/.env (SSH credentials + DEPLOY_TAG), connects to the server's
# Docker daemon over an SSH context, pulls the image, and recreates the
# container. Nothing is written to the server's disk.
#
# Prerequisites (one-time, on the server):
#   - Docker + key-based SSH for the deploy user (deploy/scripts/provision.sh).
#   - Caddy routing the domain here — bash deploy/scripts/remote-proxy.sh.
# The DEPLOY_NETWORK docker network is created here if missing; the container
# joins it so Caddy can reach it by service name (debtbook-site).
set -euo pipefail

cd "$(dirname "$0")/../.."   # repo root (debtbook-legal/)

ENV_FILE="deploy/.env"
[ -f "$ENV_FILE" ] || { echo "❌ $ENV_FILE not found — cp deploy/.env.example $ENV_FILE and fill it in."; exit 1; }
set -a; . "$ENV_FILE"; set +a

HOST="${DEPLOY_SSH_HOST:?set DEPLOY_SSH_HOST in deploy/.env}"
SSH_USER="${DEPLOY_SSH_USER:-deploy}"
SSH_PORT="${DEPLOY_SSH_PORT:-22}"
IMAGE_REPO="${DEPLOY_IMAGE_REPO:-shawon1fb/debtbook-legal-site}"
TAG="${1:-${DEPLOY_TAG:-latest}}"
TARGET="${SSH_USER}@${HOST}"
NETWORK="${DEPLOY_NETWORK:-bd-tax-network}"
SERVICE="debtbook-site"
CONTAINER="debtbook-legal-site"

export SITE_IMAGE="${IMAGE_REPO}:${TAG}"
export SITE_NETWORK="${NETWORK}"

SSH_OPTS=(-p "$SSH_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8)

echo "▶ Target : ${TARGET}:${SSH_PORT}"
echo "▶ Image  : ${SITE_IMAGE}"
echo "▶ Network: ${NETWORK}"

# ── 1. Key-based SSH must already work ──
if ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$TARGET" true 2>/dev/null; then
  echo "❌ Can't SSH to ${TARGET} with a key."
  echo "   Fresh box? run: bash deploy/scripts/provision.sh"
  echo "   Key not installed? run: ssh-copy-id -p ${SSH_PORT} ${TARGET}"
  exit 1
fi
echo "✓ SSH OK (${TARGET})"

# ── 2. Point Docker at the remote daemon over SSH ──
export DOCKER_HOST="ssh://${TARGET}:${SSH_PORT}"
docker version >/dev/null 2>&1 || { echo "❌ Docker not reachable on ${TARGET}."; exit 1; }

if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "▶ Network '${NETWORK}' missing — creating it"
  docker network create "$NETWORK" >/dev/null
fi

if docker compose version >/dev/null 2>&1; then DC="docker compose"; else DC="docker-compose"; fi
COMPOSE="$DC -f docker-compose.prod.yml"

# ── 3. Pull the published image + recreate the container ──
echo "▶ Pulling ${SITE_IMAGE} on server"
$COMPOSE pull "$SERVICE"

echo "▶ Starting ${SERVICE}"
$COMPOSE up -d --no-build "$SERVICE"

# ── 4. Verify — no host port is published (proxy-only, by design), so check
#      from another container on the same Docker network. ──
echo "⏳ Verifying (container health + in-network curl)..."

for _ in $(seq 1 15); do
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null || echo none)"
  case "$health" in healthy|none) break ;; esac
  sleep 2
done
echo "   HEALTHCHECK: ${health:-unknown}"

ok=0; code=000
for _ in $(seq 1 10); do
  code="$(docker run --rm --network "$NETWORK" curlimages/curl:latest \
    -s -o /dev/null -m 5 -w '%{http_code}' "http://${SERVICE}:80/" 2>/dev/null || echo 000)"
  [ "$code" = "200" ] && { ok=1; break; }
  sleep 2
done

if [ "$ok" = 1 ]; then
  echo "✅ Live: ${SITE_IMAGE}  (HTTP ${code})"
  printf '%s %s\n' "$(date -u +%FT%TZ)" "${TAG}" >> .deploy-history
else
  echo "❌ In-network check failed (HTTP ${code}) — recent logs:"
  $COMPOSE logs --tail=50 "$SERVICE" || true
  echo "Rollback: bash deploy/scripts/remote-deploy.sh <previous-tag>"
  exit 1
fi

$COMPOSE ps
docker image prune -f >/dev/null 2>&1 || true

echo
echo "Public check (needs the domain routed to this container in Caddy):"
echo "  curl -I ${DEPLOY_PUBLIC_URL:-https://debtbooktracker.com}/"
echo "Rollback if needed: bash deploy/scripts/remote-deploy.sh <previous-tag>"
