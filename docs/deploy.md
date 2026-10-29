# Deploying Midrolo

midrolo.com runs on ioflood as a Coolify project, `midrolo`, set up like the server's other apps: a web app, a worker
and a Postgres database, built from this repo's `main` branch. This page covers that setup, deploys, the checks after
one, backups and taking it down. To run Midrolo without Coolify, as one Docker Compose stack, see
[self-hosting.md](self-hosting.md).

## Read this first: ioflood is a shared production server

Coolify runs many other apps and databases there. Everything below keeps to these rules:

- **Reach it with `ssh ioflood`** (port 1022, set up in `~/.ssh/config`), through the WireGuard VPN.
- **Touch only the `midrolo` project.** Never change another project's resources, Coolify's own settings or Traefik's
  configuration, and never run `docker system prune` or any other prune on the server.
- **Build on ioflood, never on the Mac.** Coolify builds the image from GitHub.

## What runs

| Resource | What it is |
| --- | --- |
| `midrolo` | The web app: this repo's `Dockerfile` (Thruster in front of Puma, port 80) at https://midrolo.com, with `www` redirected to the apex. Health check `GET /up`. On start it runs `db:prepare` (`bin/docker-entrypoint`). |
| `midrolo-worker` | The same image with `MIDROLO_PROCESS=jobs`, which starts Solid Queue (`bin/jobs`) instead of the web server. No domain, no health check. `RAILS_MAX_THREADS=9`: every job thread in `config/queue.yml` (3 + 3 + 1), plus 2. |
| `midrolo-db` | Postgres 18, not reachable from outside the server. It holds `midrolo_production` and the cache, queue and cable databases, which `db:prepare` creates. |

Each app is capped at 2 CPUs and 2 GB.

## How a request gets in

```
browser ─https─▶ Traefik (Coolify's proxy, ports 80/443, Let's Encrypt)
                   └─ coolify network ─▶ midrolo:80 (Thruster) ─▶ Puma :3000
midrolo, midrolo-worker ─ coolify network ─▶ midrolo-db:5432
```

- Coolify writes the Traefik labels: `midrolo.com` on `https` with a Let's Encrypt certificate, `http` redirected to
  `https`, and `www.midrolo.com` redirected to the apex. DNS is two `A` records, `midrolo.com` and `www`, pointing at
  the server, DNS only (no Cloudflare proxy) and no `AAAA`.
- TLS ends at Traefik, so Rails runs with `assume_ssl` and `force_ssl` (secure cookies, HSTS) and never redirects.
- Rails answers only for `midrolo.com` and `www.midrolo.com`; `/up`, the health check, answers any host.
- The client's IP (`request.remote_ip`, which the rate limits use) comes from X-Forwarded-For, which Traefik and
  Thruster write. A Forwarded or Client-IP header a visitor sends never counts (`config/initializers/client_ip.rb`).
- Every container on the `coolify` network can reach every other one, so the network keeps nothing out. The code does
  (R131): every user-supplied URL (a feed, show artwork) is resolved once, refused if any address is internal
  (private, loopback, link-local, NAT64 and 6to4 ranges included), and fetched from the address that was checked,
  never from a second DNS lookup. Each redirect hop is checked the same way.

## Settings

Each app holds every variable in [`.env.example`](../.env.example) that production uses, set in Coolify as
**runtime only** (Coolify's build variable switch off). The `Dockerfile` refuses to build when a secret would be passed
as a build argument (`# check=error=true`), and the build needs none: assets compile with a dummy secret key. Both
apps hold the same values; the worker adds `MIDROLO_PROCESS=jobs` and `RAILS_MAX_THREADS=9`.

- `DB_HOST` is the database resource's container name, `MIDROLO_DATABASE_PASSWORD` its password (user `midrolo`).
- `APP_URL=https://midrolo.com`; `SECRET_KEY_BASE` was made with `bin/rails secret`.
- The rest are the service keys: Qloo, Podcast Index, OpenRouter, Resend, Google OAuth, Cloudflare R2 (uploads),
  the admin login, `JUDGE_CODE` and `PROMO_PRO_UNTIL`.

Production stops at boot, naming the variable, when a required one is blank (`lib/required_env.rb`). After changing a
variable, redeploy (or restart) both apps.

## Deploys

Pushing to `main` deploys both apps: Coolify's GitHub App starts a build of each. **Deploy** in Coolify does the same
by hand. The web app migrates on start; a worker that starts before a release's migrations have run restarts until
they have.

## Running commands

Use the app's **Terminal** tab in Coolify, or on ioflood:

```bash
docker exec -it "$(docker ps -q --filter label=coolify.projectName=midrolo --filter label=coolify.resourceName=midrolo)" bin/rails console
```

- Make yourself the admin, once you've signed in with Google:
  `bin/rails runner 'User.find_by!(email: "you@example.com").update!(admin: true)'`. /admin and /admin/jobs then
  open for you (with `ADMIN_USERNAME` and `ADMIN_PASSWORD` set, they ask for those too).
- The live Qloo check (8 calls, at most 10): `bin/rails qloo:smoke` ([live-smoke.md](live-smoke.md)).
- The sample reports (Qloo calls plus a few cents of LLM each): `bin/rails samples:generate`.

## After every deploy: checks

1. **Health.** All three resources are running (healthy) in Coolify, and from anywhere:
   `curl -sI https://midrolo.com/up` answers `200`; `curl -sI http://midrolo.com/` and
   `curl -sI https://www.midrolo.com/` redirect to `https://midrolo.com/`.
2. **Content Security Policy.** Open the landing page, a report with its map, and a public kit with the browser's
   console open: nothing may say "Content Security Policy". The map must draw.
3. **The client's IP.** Request `https://midrolo.com/pricing` once plainly and once with
   `-H 'X-Forwarded-For: 203.0.113.9' -H 'Forwarded: for=203.0.113.9'`. In the app's logs, the address after `for` must
   be yours on both lines, never `203.0.113.9` or a Docker address (`10.x`, `172.x`). A request whose `Client-IP`
   disagrees with X-Forwarded-For gets `400`.
4. **Share images.** `bin/rails runner 'p ShareImages::Renderer.text_width("Midrolo", family: "ArchivoWide", weight: 800, size: 100)'`
   prints `447` (the bundled font was found), and `https://midrolo.com/samples/<a sample slug>/og.png` answers
   `200 image/png`.
5. **Jobs.** Run a Snapshot from the site and see it finish; the worker's logs show no errors.
6. **A backup.** The database's Backups tab in Coolify lists a recent successful run.

## Backups

Coolify backs up `midrolo_production` every hour (at :20) and uploads it to the server's existing S3 storage, a
Cloudflare R2 bucket: 12 backups kept on the server (up to 3 days), 48 in R2 (up to 7 days). The cache, queue and cable
databases aren't backed up: `db:prepare` rebuilds them. **Backup Now** and restores are on the database's Backups and
Import Backups tabs in Coolify.

## Taking it down

Take a last backup, then delete the `midrolo` project in Coolify (its apps, the database and its volume). Outside the
server: the DNS records, the uploads R2 bucket and its token, the Google OAuth client, the Resend domain, and the
Coolify API token made for this project.
