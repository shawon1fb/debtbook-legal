#!/usr/bin/env bash
#
# Build, tag, and push the static-site image to Docker Hub.
#
#   scripts/docker-publish.sh [VERSION] [-y]
#
# VERSION: if omitted, the highest x.y.z tag already on Docker Hub is looked up
# and its patch is bumped by one. Pass an explicit VERSION to override. Three
# tags are pushed: <version>, <git-sha>, latest.
# After a successful push, deploy/.env DEPLOY_TAG is updated to the new version.
#
# Overridable via env:
#   DOCKER_USER  Docker Hub user/org   (default: shawon1fb)
#   IMAGE_NAME   repository name        (default: debtbook-legal-site)
#   REGISTRY     registry host          (default: empty = Docker Hub / docker.io)
#   PLATFORM     target arch            (default: linux/amd64 — the x86_64 VPS)
#
# Cross-builds linux/amd64 via buildx so an Apple-Silicon Mac produces an image
# that runs on the x86_64 server.
set -euo pipefail

DOCKER_USER="${DOCKER_USER:-shawon1fb}"
IMAGE_NAME="${IMAGE_NAME:-debtbook-legal-site}"
REGISTRY="${REGISTRY:-}"
PLATFORM="${PLATFORM:-linux/amd64}"

cd "$(dirname "$0")/.."

# Highest x.y.z tag currently on Docker Hub (prints nothing if none / not Hub).
hub_highest_version() {
  [ -z "$REGISTRY" ] || return 0
  curl -fsSL "https://hub.docker.com/v2/repositories/${DOCKER_USER}/${IMAGE_NAME}/tags?page_size=100" 2>/dev/null \
    | python3 -c '
import sys, json, re
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
vs = []
for t in data.get("results", []):
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", (t.get("name") or "").strip())
    if m:
        vs.append(tuple(int(x) for x in m.groups()))
if vs:
    a, b, c = max(vs)
    print(f"{a}.{b}.{c}")
'
}

YES=0; VERSION_ARG=""
for a in "$@"; do
  case "$a" in
    -y|--yes) YES=1 ;;
    *) VERSION_ARG="$a" ;;
  esac
done

CURRENT="$(hub_highest_version || true)"
if [ -n "$VERSION_ARG" ]; then
  VERSION="$VERSION_ARG"; SRC="explicit"
elif [ -n "$CURRENT" ]; then
  IFS=. read -r va vb vc <<EOF
$CURRENT
EOF
  VERSION="${va}.${vb}.$((vc + 1))"; SRC="auto: Hub ${CURRENT} + 1"
else
  VERSION="0.0.1"; SRC="auto: no semver tags on Hub"
fi
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"

if [ -n "$REGISTRY" ]; then
  IMAGE="${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}"
else
  IMAGE="${DOCKER_USER}/${IMAGE_NAME}"
fi

echo "────────────────────────────────────────────"
echo "  Image:    ${IMAGE}"
echo "  On Hub:   ${CURRENT:-<none>}"
echo "  BUILDING: ${VERSION}   (${SRC})"
echo "  Tags:     ${VERSION}, ${SHA}, latest"
echo "  Platform: ${PLATFORM}"
echo "────────────────────────────────────────────"

if [ "$YES" != 1 ] && [ -t 0 ]; then
  printf "Build & push %s? [y/N] " "${IMAGE}:${VERSION}"
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "aborted."; exit 1 ;; esac
fi

if ! docker info 2>/dev/null | grep -qi 'Username:'; then
  echo "→ Not logged in — running: docker login ${REGISTRY:-docker.io}"
  docker login ${REGISTRY:+"$REGISTRY"}
fi

docker buildx build \
  --platform "${PLATFORM}" \
  --file Dockerfile \
  -t "${IMAGE}:${VERSION}" \
  -t "${IMAGE}:${SHA}" \
  -t "${IMAGE}:latest" \
  --push \
  .

echo
echo "✅ Pushed ${IMAGE}:${VERSION}  (+ ${SHA}, latest)"

if [ -f deploy/.env ] && grep -qE '^DEPLOY_TAG=' deploy/.env; then
  sed -i.bak -E "s|^DEPLOY_TAG=.*|DEPLOY_TAG=${VERSION}|" deploy/.env && rm -f deploy/.env.bak
  echo "   deploy/.env updated → DEPLOY_TAG=${VERSION}"
fi

echo
echo "── Deploy it ──"
echo "  bash deploy/scripts/remote-deploy.sh           # uses DEPLOY_TAG=${VERSION}"
echo "  # rollback: bash deploy/scripts/remote-deploy.sh <old-version>"
