# Deploying debtbooktracker.com — step by step

Static site (nginx in Docker) behind Caddy on the **same VPS that already serves
taxhelperbd.com** (`165.99.219.35`).

The image is built on your Mac, pushed to Docker Hub, and pulled by the server.
Nothing is built on the server and no site files are copied to its disk.

```
  your Mac                     Docker Hub                    VPS 165.99.219.35
  ────────                     ──────────                    ─────────────────
  docker buildx  ──push──▶  shawon1fb/                        ┌──────────────────────────┐
  (linux/amd64)             debtbook-legal-site   ──pull──▶   │ bd-tax-caddy  :80 :443   │
                                                              │   ├─ taxhelperbd.com     │
  remote-deploy.sh ─ ssh ──────────────────────────────────▶  │   │    → bd-tax-site:80  │
  (DOCKER_HOST=ssh://deploy@…)                                │   └─ debtbooktracker.com │
                                                              │        → debtbook-site:80│
                                                              │ docker net: bd-tax-network│
                                                              └──────────────────────────┘
```

**One proxy, two sites.** Only one process can bind ports 80/443, so this repo
does *not* start its own Caddy on that server. `remote-proxy.sh` merges a
`debtbooktracker.com { … }` block into the Caddyfile of the existing
`bd-tax-caddy` container (between `# >>> debtbook-legal` markers) and runs
`caddy reload` — no restart, no downtime for taxhelperbd.com, existing
certificates untouched. On a fresh server with no Caddy it starts its own
(`debtbook-caddy`) from `deploy/Caddyfile` instead.

---

## 0. One-time prerequisites

| What | Check |
|---|---|
| Docker Desktop running on your Mac | `docker version` |
| Logged in to Docker Hub | `docker login` |
| SSH key works on the server | `ssh deploy@165.99.219.35 true` |
| `deploy/.env` filled in | `cat deploy/.env` |
| DNS: `debtbooktracker.com` A record → `165.99.219.35` | `dig +short debtbooktracker.com` |

```bash
cp deploy/.env.example deploy/.env   # already done if the file exists
```

`deploy/.env` is gitignored — it holds server credentials. Key values:

```ini
DEPLOY_SSH_HOST=165.99.219.35
DEPLOY_SSH_USER=deploy
DEPLOY_DOMAIN=debtbooktracker.com
DEPLOY_IMAGE_REPO=shawon1fb/debtbook-legal-site
DEPLOY_NETWORK=bd-tax-network      # must match the network bd-tax-caddy is on
CADDY_CONTAINER=bd-tax-caddy       # the proxy to merge into
```

### DNS

At the registrar of `debtbooktracker.com`:

| Type | Name | Value | TTL |
|---|---|---|---|
| A | `@` | `165.99.219.35` | 300 |
| A | `www` | `165.99.219.35` | 300 | *(optional — only if you want www)* |

Wait until `dig +short debtbooktracker.com` prints `165.99.219.35`. Caddy issues
the certificate over HTTP-01, so it **fails until DNS resolves**.

If you add `www`, uncomment the `www.` block in `deploy/caddy-site.snippet` and
re-run step 3.

### Fresh server only (skip for 165.99.219.35 — already provisioned)

```bash
# Set DEPLOY_ROOT_PASSWORD in deploy/.env first, then:
bash deploy/scripts/provision.sh
```

Installs Docker + compose, creates the key-only `deploy` user, adds 2 GB swap,
opens 22/80/443 in ufw. Idempotent.

---

## 1. Build and push the image

```bash
bash scripts/docker-publish.sh          # asks for confirmation
bash scripts/docker-publish.sh -y       # no prompt
bash scripts/docker-publish.sh 0.1.0    # explicit version
```

- Looks up the highest `x.y.z` tag on Docker Hub and bumps the patch.
- Cross-builds `linux/amd64` (the VPS is x86_64, your Mac is ARM).
- Pushes three tags: `<version>`, `<git-sha>`, `latest`.
- Writes the new version back into `deploy/.env` as `DEPLOY_TAG`.

## 2. Deploy it on the server

```bash
bash deploy/scripts/remote-deploy.sh            # uses DEPLOY_TAG from deploy/.env
bash deploy/scripts/remote-deploy.sh 0.0.3      # pin a tag / roll back
```

What it does: talks to the server's Docker daemon over `DOCKER_HOST=ssh://…`,
creates `bd-tax-network` if missing, `docker compose -f docker-compose.prod.yml
pull && up -d`, waits for the container HEALTHCHECK, then curls
`http://debtbook-site/` from a throwaway container **on the same docker
network** (the site publishes no host port — the proxy is the only way in).
Success is appended to `.deploy-history`.

## 3. Route the domain through Caddy (first deploy, or when the block changes)

```bash
bash deploy/scripts/remote-proxy.sh
```

- Attaches `bd-tax-caddy` to `bd-tax-network` if it isn't already.
- Ships `deploy/caddy-site.snippet` with `__DOMAIN__` replaced by
  `DEPLOY_DOMAIN` → `~/debtbook-caddy/site.caddy` on the server.
- Backs up the live Caddyfile (`Caddyfile.bak.<epoch>`), removes any previous
  debtbook block, appends the new one.
- `caddy validate` → on failure the backup is restored and the script exits 1.
- `caddy reload` — zero downtime; taxhelperbd.com is not interrupted.

Other actions:

```bash
bash deploy/scripts/remote-proxy.sh show    # print the live Caddyfile
bash deploy/scripts/remote-proxy.sh down    # remove only the debtbook block + reload
```

Certificate issuance takes ~30 s after the reload. Watch it:

```bash
DOCKER_HOST=ssh://deploy@165.99.219.35:22 docker logs -f bd-tax-caddy
```

## 4. Verify

```bash
bash deploy/scripts/health.sh
```

Checks container + HEALTHCHECK, in-network `/healthz`, Caddy running and on the
right network, the domain present in the live Caddyfile, DNS, HTTP→HTTPS
redirect, all public pages, TLS expiry, disk usage. Exit code 0 = all good, so
it works in cron/CI.

Manual spot check:

```bash
curl -I https://debtbooktracker.com/
curl -I https://debtbooktracker.com/privacy-policy.html
curl -I https://debtbooktracker.com/support.html
curl -s https://debtbooktracker.com/healthz
```

---

## Routine update (content change → live)

```bash
# 1. edit index.html / privacy-policy.html / support.html / screenshots
bash scripts/docker-publish.sh -y        # build + push, bumps the version
bash deploy/scripts/remote-deploy.sh     # pull + restart on the server
bash deploy/scripts/health.sh            # confirm
```

Step 3 (proxy) is **not** needed again unless the domain or the Caddy block
changes.

### Local preview before publishing

```bash
docker compose up -d --build   # → http://localhost:8090
docker compose down
```

Port 8090 so it can run beside bd-tax-calculator-site (8089).

### Rollback

```bash
tail .deploy-history                          # previous tags with timestamps
bash deploy/scripts/remote-deploy.sh 0.0.2    # redeploy an older image
```

---

## Files in this repo

| Path | Purpose |
|---|---|
| `Dockerfile` | nginx:alpine + the static files + HEALTHCHECK |
| `nginx.conf` | gzip, `/healthz`, branded 404, extensionless URLs, `/debtbook-legal/*` → `/*` redirect, image caching |
| `docker-compose.yml` | local build on port 8090 |
| `docker-compose.prod.yml` | server: pulled image, no host port, external network |
| `scripts/docker-publish.sh` | build + push to Docker Hub, bump `DEPLOY_TAG` |
| `scripts/set-domain.sh` | rewrite `shawon1fb.github.io/debtbook-legal` URLs → the custom domain |
| `deploy/.env` | server credentials + domain + image tag (gitignored) |
| `deploy/caddy-site.snippet` | the site block merged into the shared proxy |
| `deploy/Caddyfile` | standalone proxy config (fresh-server fallback only) |
| `deploy/scripts/provision.sh` | provision a fresh VPS (runs `provision-vps.sh` over SSH) |
| `deploy/scripts/remote-deploy.sh` | pull + restart the site container |
| `deploy/scripts/remote-proxy.sh` | add/refresh/remove the domain in Caddy |
| `deploy/scripts/health.sh` | end-to-end health check |

## Names on the server

| Thing | Value |
|---|---|
| Docker image | `shawon1fb/debtbook-legal-site` |
| Container | `debtbook-legal-site` |
| Compose service / DNS name Caddy proxies to | `debtbook-site` |
| Shared docker network | `bd-tax-network` |
| Proxy container | `bd-tax-caddy` (shared with taxhelperbd.com) |
| Caddyfile on the server | `/home/deploy/bd-tax-caddy/Caddyfile` |

---

## Troubleshooting

**502 from Caddy** — the site container is down or not on the shared network:
```bash
bash deploy/scripts/health.sh
bash deploy/scripts/remote-deploy.sh
```

**Certificate never issues** — DNS is the usual cause:
```bash
dig +short debtbooktracker.com          # must be 165.99.219.35
DOCKER_HOST=ssh://deploy@165.99.219.35:22 docker logs --tail=100 bd-tax-caddy
```
Also confirm ports 80/443 are open at the provider's firewall. Let's Encrypt
rate-limits ~5 failures/hour per host — fix DNS before retrying repeatedly.

**taxhelperbd.com broke after a proxy change** — restore the backup:
```bash
ssh deploy@165.99.219.35 'ls -t ~/bd-tax-caddy/Caddyfile.bak.* | head'
ssh deploy@165.99.219.35 'cp ~/bd-tax-caddy/Caddyfile.bak.<epoch> ~/bd-tax-caddy/Caddyfile'
DOCKER_HOST=ssh://deploy@165.99.219.35:22 docker exec bd-tax-caddy \
  caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
```

**`docker compose pull` fails: manifest unknown** — that tag was never pushed.
Check `DEPLOY_TAG` in `deploy/.env` against Docker Hub.

**Wrong architecture (`exec format error`)** — the image was built for arm64.
Republish with `PLATFORM=linux/amd64` (the default in `docker-publish.sh`).

**Disk full on the server**:
```bash
DOCKER_HOST=ssh://deploy@165.99.219.35:22 docker system prune -af
```

## Note on GitHub Pages

The site is also published at `shawon1fb.github.io/debtbook-legal`. Two live
copies compete in search, so once `debtbooktracker.com` serves traffic either
turn Pages off in the repo settings, or leave it and accept that the canonical
tags (already rewritten by `scripts/set-domain.sh`) point at the custom domain.
nginx redirects `/debtbook-legal/*` → `/*` so old links keep working.
