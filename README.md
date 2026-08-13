# Debt Book — website & legal pages

Marketing page, privacy policy, and support page for the **Debt Book** iOS app
([App Store](https://apps.apple.com/app/id6771255586)).

Live at **https://debtbooktracker.com** — static HTML served by nginx in Docker,
behind Caddy (automatic HTTPS) on the same VPS as taxhelperbd.com.

## Pages

| File | URL |
|---|---|
| `index.html` | `/` |
| `privacy-policy.html` | `/privacy-policy.html` (also `/privacy-policy`) |
| `support.html` | `/support.html` |
| `404.html` | any unknown path |
| `robots.txt`, `sitemap.xml` | `/robots.txt`, `/sitemap.xml` |

Assets: `app-icon-v2.png`, `screenshots-v2/*.jpg`.

## Preview locally

```bash
docker compose up -d --build     # http://localhost:8090
docker compose down
```

## Deploy

```bash
bash scripts/docker-publish.sh -y        # build linux/amd64 + push to Docker Hub
bash deploy/scripts/remote-deploy.sh     # server pulls the image, restarts
bash deploy/scripts/health.sh            # verify end to end
```

First deploy also needs the domain routed through Caddy once:

```bash
bash deploy/scripts/remote-proxy.sh
```

Full step-by-step, server layout, and troubleshooting: **[deploy/README.md](deploy/README.md)**.
