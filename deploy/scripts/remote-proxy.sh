#!/usr/bin/env bash
#
# Put HTTPS in front of the site — driven from the dev machine.
#
#     bash deploy/scripts/remote-proxy.sh          # add/refresh the debtbook route
#     bash deploy/scripts/remote-proxy.sh reload   # same thing (alias)
#     bash deploy/scripts/remote-proxy.sh down     # remove the debtbook route
#     bash deploy/scripts/remote-proxy.sh show     # print the server's live Caddyfile
#
# TWO MODES — the script picks one automatically:
#
#   A. SHARED (this server). A Caddy container ($CADDY_CONTAINER, default
#      bd-tax-caddy) already owns ports 80/443 for taxhelperbd.com. Only one
#      process can bind those ports, so instead of starting a second proxy this
#      script MERGES deploy/caddy-site.snippet into that container's Caddyfile,
#      between the markers below, and runs `caddy reload` — no restart, no
#      dropped connections, existing certificates untouched. Re-running replaces
#      the block, so it is idempotent. A timestamped .bak is kept server-side.
#
#   B. STANDALONE (fresh box, no Caddy running). Ships deploy/Caddyfile and
#      starts its own container named debtbook-caddy.
#
# deploy/.env keys used:
#   DEPLOY_SSH_HOST / _USER / _PORT   how to reach the box
#   DEPLOY_DOMAIN                     domain to serve, e.g. debtbooktracker.com (required)
#   DEPLOY_ACME_EMAIL                 email for Let's Encrypt notices (optional)
#   DEPLOY_NETWORK                    docker network shared with the site container
#   CADDY_CONTAINER                   existing proxy container to merge into
#
# BEFORE running: point DEPLOY_DOMAIN's A record at the server IP. Caddy issues
# the certificate over HTTP-01, so DNS must already resolve.
set -euo pipefail

cd "$(dirname "$0")/../.."

ENV_FILE="deploy/.env"
[ -f "$ENV_FILE" ] || { echo "❌ $ENV_FILE not found — cp deploy/.env.example $ENV_FILE first."; exit 1; }
set -a; . "$ENV_FILE"; set +a

HOST="${DEPLOY_SSH_HOST:?set DEPLOY_SSH_HOST in deploy/.env}"
SSH_USER="${DEPLOY_SSH_USER:-deploy}"
SSH_PORT="${DEPLOY_SSH_PORT:-22}"
DOMAIN="${DEPLOY_DOMAIN:?set DEPLOY_DOMAIN in deploy/.env (e.g. debtbooktracker.com)}"
EMAIL="${DEPLOY_ACME_EMAIL:-}"
NETWORK="${DEPLOY_NETWORK:-bd-tax-network}"
SHARED_CADDY="${CADDY_CONTAINER:-bd-tax-caddy}"
OWN_CADDY="debtbook-caddy"
SITE_CONTAINER="debtbook-legal-site"
SITE_SERVICE="debtbook-site"          # what the Caddy block proxies to
ACTION="${1:-up}"

MARK_BEGIN="# >>> debtbook-legal"
MARK_END="# <<< debtbook-legal <<<"

SSH_TARGET="${SSH_USER}@${HOST}"
SSH_OPTS=(-p "$SSH_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

export DOCKER_HOST="ssh://${SSH_TARGET}:${SSH_PORT}"
docker version >/dev/null 2>&1 || { echo "❌ Can't reach Docker on the server. Provision first: bash deploy/scripts/provision.sh"; exit 1; }

docker network inspect "$NETWORK" >/dev/null 2>&1 || {
  echo "▶ Network ${NETWORK} missing — creating it"
  docker network create "$NETWORK" >/dev/null
}

running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }

# Which proxy is in charge? Prefer the shared one named in deploy/.env.
PROXY=""
if running "$SHARED_CADDY"; then PROXY="$SHARED_CADDY"
elif running "$OWN_CADDY";   then PROXY="$OWN_CADDY"
fi

# Host path of the Caddyfile bind-mounted into the proxy container.
caddyfile_path() {
  docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' "$1" 2>/dev/null | tr -d '\r\n'
}

# ── show ──────────────────────────────────────────────────────────────────
if [ "$ACTION" = "show" ]; then
  [ -n "$PROXY" ] || { echo "❌ No Caddy container running on ${HOST}."; exit 1; }
  CF="$(caddyfile_path "$PROXY")"
  echo "▶ ${PROXY}:${CF}"
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "cat '${CF}'"
  exit 0
fi

# ── down ──────────────────────────────────────────────────────────────────
if [ "$ACTION" = "down" ]; then
  if [ "$PROXY" = "$OWN_CADDY" ]; then
    docker rm -f "$OWN_CADDY" >/dev/null 2>&1 || true
    echo "✅ ${OWN_CADDY} removed."
    exit 0
  fi
  [ -n "$PROXY" ] || { echo "Nothing to do — no Caddy running."; exit 0; }
  CF="$(caddyfile_path "$PROXY")"
  [ -n "$CF" ] || { echo "❌ ${PROXY} has no Caddyfile bind mount — remove the block by hand."; exit 1; }
  echo "▶ Removing the debtbook block from ${PROXY}:${CF}"
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
    "CF='${CF}' B='${MARK_BEGIN}' E='${MARK_END}' bash -s" <<'REMOTE'
set -euo pipefail
cp "$CF" "${CF}.bak.$(date +%s)"
awk -v b="$B" -v e="$E" '
  index($0, b) == 1 { skip = 1 }
  skip == 0 { print }
  index($0, e) == 1 { skip = 0 }
' "$CF" > "${CF}.new"
mv "${CF}.new" "$CF"
REMOTE
  docker exec "$PROXY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
  echo "✅ Route for ${DOMAIN} removed and ${PROXY} reloaded."
  exit 0
fi

# ── B. STANDALONE: no proxy on the box yet ────────────────────────────────
if [ -z "$PROXY" ]; then
  BUSY="$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E ':(80|443)->' || true)"
  [ -n "$BUSY" ] && { echo "⚠️  Ports 80/443 already used by:"; echo "$BUSY"; echo "   Set CADDY_CONTAINER in deploy/.env to that container and re-run."; exit 1; }

  REMOTE_HOME="$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'echo "$HOME"')"
  REMOTE_DIR="${REMOTE_HOME}/debtbook-caddy"
  echo "▶ No Caddy on ${HOST} — starting ${OWN_CADDY} (standalone mode)"
  echo "▶ Shipping deploy/Caddyfile → ${SSH_TARGET}:${REMOTE_DIR}/"
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "mkdir -p '${REMOTE_DIR}'"
  scp -P "$SSH_PORT" -o StrictHostKeyChecking=accept-new -q deploy/Caddyfile "${SSH_TARGET}:${REMOTE_DIR}/Caddyfile"

  docker rm -f "$OWN_CADDY" >/dev/null 2>&1 || true
  docker run -d --name "$OWN_CADDY" \
    --restart unless-stopped \
    --network "$NETWORK" \
    -p 80:80 -p 443:443 \
    -e DEPLOY_DOMAIN="$DOMAIN" \
    ${EMAIL:+-e DEPLOY_ACME_EMAIL="$EMAIL"} \
    -v caddy_data:/data -v caddy_config:/config \
    -v "${REMOTE_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro" \
    caddy:2 caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
  PROXY="$OWN_CADDY"
else
  # ── A. SHARED: merge the site block into the running proxy's Caddyfile ──
  CF="$(caddyfile_path "$PROXY")"
  [ -n "$CF" ] || { echo "❌ ${PROXY} has no /etc/caddy/Caddyfile bind mount — can't merge. Add the block by hand."; exit 1; }

  # The proxy must share the site's network to resolve ${SITE_SERVICE}.
  if ! docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$PROXY" | grep -qw "$NETWORK"; then
    echo "▶ Attaching ${PROXY} to ${NETWORK}"
    docker network connect "$NETWORK" "$PROXY"
  fi

  TMP="$(mktemp -t debtbook-caddy)"
  sed "s|__DOMAIN__|${DOMAIN}|g" deploy/caddy-site.snippet > "$TMP"

  REMOTE_HOME="$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'echo "$HOME"')"
  REMOTE_DIR="${REMOTE_HOME}/debtbook-caddy"
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "mkdir -p '${REMOTE_DIR}'"
  scp -P "$SSH_PORT" -o StrictHostKeyChecking=accept-new -q "$TMP" "${SSH_TARGET}:${REMOTE_DIR}/site.caddy"
  rm -f "$TMP"

  echo "▶ Merging ${DOMAIN} block into ${PROXY}:${CF}"
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
    "CF='${CF}' SNIP='${REMOTE_DIR}/site.caddy' B='${MARK_BEGIN}' E='${MARK_END}' bash -s" <<'REMOTE'
set -euo pipefail
BAK="${CF}.bak.$(date +%s)"
cp "$CF" "$BAK"
echo "$BAK" > "$(dirname "$SNIP")/.last-backup"
# Drop any previous debtbook block, then append the fresh one.
awk -v b="$B" -v e="$E" '
  index($0, b) == 1 { skip = 1 }
  skip == 0 { print }
  index($0, e) == 1 { skip = 0 }
' "$CF" > "${CF}.new"
printf '\n' >> "${CF}.new"
cat "$SNIP" >> "${CF}.new"
mv "${CF}.new" "$CF"
REMOTE

  # Validate inside the container; restore the backup if the merge broke it.
  if ! docker exec "$PROXY" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
    echo "❌ Merged Caddyfile is invalid — restoring the backup."
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
      "cp \"\$(cat '${REMOTE_DIR}/.last-backup')\" '${CF}'"
    docker exec "$PROXY" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile || true
    exit 1
  fi

  echo "▶ Reloading ${PROXY} (zero downtime)"
  docker exec "$PROXY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
fi

running "$SITE_CONTAINER" \
  || echo "⚠️  Site container not running — Caddy will 502 until: bash deploy/scripts/remote-deploy.sh"

RESOLVED="$(dig +short "$DOMAIN" 2>/dev/null | tail -1 || true)"
if [ "$RESOLVED" != "$HOST" ]; then
  echo "⚠️  DNS: ${DOMAIN} → '${RESOLVED:-nothing}', expected ${HOST}."
  echo "   Caddy cannot issue a certificate until the A record points here."
fi

echo
echo "✅ Done. In ~30 s Caddy fetches the certificate, then:"
echo "   https://${DOMAIN}"
echo "   https://${DOMAIN}/privacy-policy.html   https://${DOMAIN}/support.html"
echo "Watch it:  DOCKER_HOST=ssh://${SSH_TARGET}:${SSH_PORT} docker logs -f ${PROXY}"
echo "Live config:  bash deploy/scripts/remote-proxy.sh show"
