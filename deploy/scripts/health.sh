#!/usr/bin/env bash
#
# Health check — is the site actually up, end to end?
#
#     bash deploy/scripts/health.sh          # full check
#     bash deploy/scripts/health.sh --quiet  # only print failures; exit code is the answer
#
# Checks, in order:
#   1. container running + docker HEALTHCHECK status
#   2. nginx answering inside the docker network (/healthz)
#   3. Caddy container running + the debtbook route present in its Caddyfile
#   4. public HTTP → HTTPS redirect
#   5. public HTTPS pages (/, /privacy-policy.html, /support.html)
#   6. TLS certificate expiry
#   7. disk space on the server
#
# Exit code 0 = everything passed, 1 = at least one check failed. Safe to run
# from cron/CI.
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1   # no `set -e` here — a failed check must
                                       # not abort the remaining checks

ENV_FILE="deploy/.env"
[ -f "$ENV_FILE" ] || { echo "❌ $ENV_FILE not found."; exit 1; }
set -a; . "$ENV_FILE"; set +a

HOST="${DEPLOY_SSH_HOST:?set DEPLOY_SSH_HOST in deploy/.env}"
SSH_USER="${DEPLOY_SSH_USER:-deploy}"
SSH_PORT="${DEPLOY_SSH_PORT:-22}"
DOMAIN="${DEPLOY_DOMAIN:-}"
NETWORK="${DEPLOY_NETWORK:-bd-tax-network}"
SITE_CONTAINER="debtbook-legal-site"
SITE_SERVICE="debtbook-site"
CADDY="${CADDY_CONTAINER:-bd-tax-caddy}"
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1

FAILED=0
pass() { [ "$QUIET" = 1 ] || printf '  ✅ %s\n' "$1"; }
warn() { printf '  ⚠️  %s\n' "$1"; }
fail() { printf '  ❌ %s\n' "$1"; FAILED=1; }
section() { [ "$QUIET" = 1 ] || printf '\n▶ %s\n' "$1"; }

# curl prints "000" itself on a connection failure, so `|| echo 000` would
# double it. Normalise empty output instead.
http_code() {
  local c; c="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$1" 2>/dev/null)"
  printf '%s' "${c:-000}"
}
# `docker inspect` on a missing container still emits a blank line on stdout.
docker_state() {
  docker inspect -f "$2" "$1" 2>/dev/null | tr -d '\r\n' | grep . || printf 'missing'
}

export DOCKER_HOST="ssh://${SSH_USER}@${HOST}:${SSH_PORT}"

section "Server ${HOST}"
if ! docker version >/dev/null 2>&1; then
  fail "Docker unreachable over SSH — server down, or key/SSH broken."
  exit 1
fi
pass "docker reachable over ssh"

# ── 1. site container ──
section "Site container"
STATE="$(docker_state "$SITE_CONTAINER" '{{.State.Status}}')"
case "$STATE" in
  running) pass "${SITE_CONTAINER} running" ;;
  missing) fail "${SITE_CONTAINER} does not exist — run: bash deploy/scripts/remote-deploy.sh" ;;
  *)       fail "${SITE_CONTAINER} is '${STATE}'" ;;
esac

if [ "$STATE" = "running" ]; then
  HEALTH="$(docker_state "$SITE_CONTAINER" '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
  case "$HEALTH" in
    healthy)   pass "HEALTHCHECK: healthy" ;;
    starting)  warn "HEALTHCHECK: still starting" ;;
    none)      warn "no HEALTHCHECK in this image — publish a newer one to get it" ;;
    *)         fail "HEALTHCHECK: ${HEALTH}"
               docker inspect -f '{{range .State.Health.Log}}{{.Output}}{{end}}' "$SITE_CONTAINER" 2>/dev/null | tail -3 | sed 's/^/     | /' ;;
  esac

  IMAGE="$(docker inspect -f '{{.Config.Image}}' "$SITE_CONTAINER" 2>/dev/null)"
  UPTIME="$(docker inspect -f '{{.State.StartedAt}}' "$SITE_CONTAINER" 2>/dev/null)"
  [ "$QUIET" = 1 ] || echo "     image: ${IMAGE}   started: ${UPTIME}"
fi

# ── 2. in-network reachability (no host port is published) ──
section "In-network HTTP"
CODE="$(docker run --rm --network "$NETWORK" curlimages/curl:latest \
  -s -o /dev/null -m 8 -w '%{http_code}' "http://${SITE_SERVICE}/healthz" 2>/dev/null)"
CODE="${CODE:-000}"
[ "$CODE" = "200" ] && pass "http://${SITE_SERVICE}/healthz → 200" \
                    || fail "http://${SITE_SERVICE}/healthz → ${CODE} (nginx not answering on ${NETWORK})"

# ── 3. proxy ──
section "Reverse proxy"
CSTATE="$(docker_state "$CADDY" '{{.State.Status}}')"
case "$CSTATE" in
  running) pass "${CADDY} running" ;;
  missing) fail "${CADDY} missing — run: bash deploy/scripts/remote-proxy.sh" ;;
  *)       fail "${CADDY} is '${CSTATE}'" ;;
esac

if [ "$CSTATE" = "running" ]; then
  docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$CADDY" 2>/dev/null | grep -qw "$NETWORK" \
    && pass "${CADDY} attached to ${NETWORK}" \
    || fail "${CADDY} not on ${NETWORK} — it cannot reach ${SITE_SERVICE}"

  if [ -n "$DOMAIN" ]; then
    docker exec "$CADDY" grep -q "$DOMAIN" /etc/caddy/Caddyfile 2>/dev/null \
      && pass "${DOMAIN} present in the live Caddyfile" \
      || fail "${DOMAIN} missing from the Caddyfile — run: bash deploy/scripts/remote-proxy.sh"
  fi
fi

# ── 4-6. public ──
if [ -z "$DOMAIN" ]; then
  warn "DEPLOY_DOMAIN unset — skipping public checks"
else
  section "Public (${DOMAIN})"

  RESOLVED="$(dig +short "$DOMAIN" 2>/dev/null | tail -1)"
  [ "$RESOLVED" = "$HOST" ] && pass "DNS → ${RESOLVED}" \
                            || fail "DNS → '${RESOLVED:-nothing}', expected ${HOST}"

  RCODE="$(http_code "http://${DOMAIN}/")"
  case "$RCODE" in
    301|308) pass "http:// → redirects (${RCODE})" ;;
    200)     warn "http:// serves 200 without redirecting to https" ;;
    *)       fail "http:// → ${RCODE}" ;;
  esac

  for p in / /privacy-policy.html /support.html /healthz; do
    PCODE="$(http_code "https://${DOMAIN}${p}")"
    [ "$PCODE" = "200" ] && pass "https://${DOMAIN}${p} → 200" \
                         || fail "https://${DOMAIN}${p} → ${PCODE}"
  done

  END="$(echo | openssl s_client -servername "$DOMAIN" -connect "${DOMAIN}:443" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
  if [ -n "$END" ]; then
    END_EPOCH="$(date -j -f '%b %e %T %Y %Z' "$END" +%s 2>/dev/null \
              || date -d "$END" +%s 2>/dev/null || echo '')"
    if [ -n "$END_EPOCH" ]; then
      DAYS=$(( (END_EPOCH - $(date +%s)) / 86400 ))
      if   [ "$DAYS" -lt 7 ];  then fail "TLS cert expires in ${DAYS} days (${END}) — Caddy should have renewed"
      elif [ "$DAYS" -lt 21 ]; then warn "TLS cert expires in ${DAYS} days (${END})"
      else pass "TLS cert valid ${DAYS} more days"
      fi
    else
      pass "TLS cert expires ${END}"
    fi
  else
    fail "could not read the TLS certificate"
  fi
fi

# ── 7. server resources ──
section "Server resources"
DISK="$(docker run --rm -v /:/host:ro alpine:latest df -h /host 2>/dev/null | awk 'NR==2{print $5" used, "$4" free"}')"
PCT="$(echo "$DISK" | grep -oE '^[0-9]+' || echo 0)"
if [ -n "$DISK" ]; then
  if   [ "$PCT" -ge 90 ]; then fail "disk ${DISK} — prune: docker system prune -af"
  elif [ "$PCT" -ge 75 ]; then warn "disk ${DISK}"
  else pass "disk ${DISK}"
  fi
fi

echo
if [ "$FAILED" = 0 ]; then
  echo "✅ All checks passed."
else
  echo "❌ Some checks failed (see above)."
fi
exit "$FAILED"
