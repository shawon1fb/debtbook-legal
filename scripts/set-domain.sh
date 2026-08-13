#!/usr/bin/env bash
#
# Rewrite the site's absolute URLs to the custom domain.
#
#     scripts/set-domain.sh                       # → https://debtbooktracker.com
#     scripts/set-domain.sh https://example.com   # → any other origin
#
# The pages were built for GitHub Pages, where everything lived under
# https://shawon1fb.github.io/debtbook-legal/. On the custom domain the site is
# served from the root, so canonical/og:url/sitemap/robots must drop that path —
# otherwise Google keeps indexing the old origin and the two compete.
#
# Only absolute URLs change; relative links (privacy-policy.html, app-icon-v2.png)
# already work at the root. Run it, eyeball `git diff`, commit.
set -euo pipefail

cd "$(dirname "$0")/.."

OLD="https://shawon1fb.github.io/debtbook-legal"
NEW="${1:-https://debtbooktracker.com}"
NEW="${NEW%/}"

FILES=(index.html privacy-policy.html support.html robots.txt sitemap.xml)

for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  # ".../debtbook-legal/x" → ".../x", and the bare ".../debtbook-legal" → root.
  sed -i.bak -e "s|${OLD}/|${NEW}/|g" -e "s|${OLD}|${NEW}/|g" "$f"
  rm -f "${f}.bak"
done

echo "▶ ${OLD}  →  ${NEW}"
grep -rno "${NEW}[^\"' ]*" "${FILES[@]}" 2>/dev/null | sed 's/^/  /' || true

REMAINING="$(grep -rl 'shawon1fb.github.io' "${FILES[@]}" 2>/dev/null || true)"
[ -n "$REMAINING" ] && echo "⚠️  still referencing github.io: ${REMAINING}"

echo
echo "Review with: git diff"
