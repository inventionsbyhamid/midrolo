# Deploying to ioflood

Midrolo runs on ioflood as one Docker Compose stack, `compose.yml`, behind the Coolify proxy (Traefik) that already
serves the server's other sites. This page covers the first deploy, updates, checks, backups and restores.

## Read this first: ioflood is a shared production server

Coolify and several other apps and databases run there. Everything below keeps to these rules:

- **Reach it with `ssh ioflood`** (port 1022, set up in `~/.ssh/config`). It only works with the VPN on.
- **Build and run on ioflood, never on the Mac.** The Mac only syncs the code across.
- **Touch only the midrolo stack.** Every name it creates starts with `midrolo-` (below). Never stop, restart, change
  or remove another stack's containers, networks or volumes, and never edit Traefik's or Coolify's own configuration.
  Never run `docker system prune`, `docker volume prune`, `docker network prune` or `docker compose down` outside
  `/root/midrolo`.
- **No host ports.** Traefik reaches the web container over the existing `coolify` network. Nothing in the stack
  publishes a port on the server, and nothing should be added that does.

What the stack creates, and nothing else:

| Kind | Names |
| --- | --- |
| Containers | `midrolo-web` (Thruster and Puma), `midrolo-jobs` (Solid Queue), `midrolo-db` (Postgres 16), `midrolo-backup` |
| Images | `midrolo-app:latest` (web and jobs), `midrolo-backup:latest` (pulls `postgres:16`) |
| Network | `midrolo-net`, this stack's own bridge; `midrolo-web` also joins the existing external `coolify` network |
| Volume | `midrolo-db` (the database) |
| Traefik | routers `midrolo-http`, `midrolo-https`, `midrolo-www`; service `midrolo-web`; middlewares `midrolo-https-redirect`, `midrolo-www-redirect` (labels on `midrolo-web`, gone when it is) |
| Files | `/root/midrolo` (the code and `.env`) |
| Outside the server | DNS records for midrolo.com and www, two R2 buckets, the Google OAuth client, the Resend domain |

The test lane (`bin/remote-rspec`, `docs/testing.md`) is separate: it uses `midrolo-ci*` names and
`/root/midrolo-ci/`.

## How a request gets in

```
browser ─https─▶ Traefik (Coolify's proxy, ports 80/443, Let's Encrypt)
                   └─ coolify network ─▶ midrolo-web:80 (Thruster) ─▶ Puma :3000
midrolo-web, midrolo-jobs, midrolo-backup ─ midrolo-net ─▶ midrolo-db:5432
```

- Traefik finds `midrolo-web` by its labels: `Host(midrolo.com)` on the `https` entrypoint with a `letsencrypt`
  certificate, `http` redirected to `https`, and `www.midrolo.com` redirected to the apex.
- TLS ends at Traefik, so Rails runs with `assume_ssl` and `force_ssl` (secure cookies, HSTS) and never redirects.
- Rails answers only for `midrolo.com` and `www.midrolo.com`; `/up`, the health check, answers any host.
- The client's IP (`request.remote_ip`, which the rate limits use) comes from X-Forwarded-For, which Traefik and
  Thruster write. With Cloudflare's proxy on, it comes from CF-Connecting-IP, believed only from Cloudflare's own
  addresses (`config/initializers/client_ip.rb`).
- The database is on `midrolo-net` only, so no other stack can reach it. `midrolo-web` is also on `coolify`, which
  other stacks' web containers share: the feed fetcher's SSRF guard is what keeps it off their ports (R13).

## First deploy

### 1. DNS

At Cloudflare, for midrolo.com:

- `A midrolo.com → 107.167.86.146`
- `A www.midrolo.com → 107.167.86.146` (or a `CNAME` to midrolo.com), for the redirect and its certificate.

Start with **DNS only** (grey cloud): Traefik gets Let's Encrypt certificates over plain HTTP-01, and Rails sees the
client's real address directly. Turning the proxy on later works too: set SSL/TLS to **Full (strict)**, and the app
reads CF-Connecting-IP (check it after, as below).

### 2. Check the proxy's names (read only)

The labels assume Coolify's defaults: entrypoints `http` and `https`, certificate resolver `letsencrypt`, network
`coolify`. Confirm them against a site that already works, without changing anything:

```bash
ssh ioflood
docker network ls --filter name=^coolify$
docker ps --format '{{.Names}}' | grep -i storyquest
docker inspect <that container> --format '{{json .Config.Labels}}' | tr ',' '\n' | grep -E 'entrypoints|certresolver|docker.network'
```

If they differ, change the labels in `compose.yml` to match before going on.

### 3. Outside services

- **Cloudflare R2:** two buckets, one for uploads (`R2_BUCKET`) and one for backups (`R2_BACKUP_BUCKET`), and one API
  token with Object Read and Write on both. Neither bucket needs public access.
- **Google OAuth client:** authorized redirect URI `https://midrolo.com/users/auth/google_oauth2/callback`.
- **Resend:** verify the domain midrolo.com (its DNS records) so mail can come from `hello@midrolo.com`.
- **Dodo** (only when billing leaves waitlist mode): webhook URL `https://midrolo.com/webhooks/dodo`.

### 4. Send the code

From the Mac, in the repository (the same excludes as `bin/remote-rspec`; `.env*` and keys never leave the Mac, and
`--delete` leaves the server's own `.env` alone because it's excluded):

```bash
rsync -az --delete \
  --exclude=/.git --exclude=/.claude/ --exclude=/.superpowers/ --exclude=/.bundle/ --exclude=/.kamal/ \
  --exclude=/tmp/ --exclude=/log/ --exclude=/storage/ --exclude=/coverage/ --exclude=/node_modules/ \
  --exclude=/vendor/bundle/ --exclude=/public/assets/ --exclude='/app/assets/builds/*' \
  --exclude='.env*' --exclude=/config/master.key --exclude='/config/credentials/*.key' \
  --exclude=/spec/fixtures/private/ --exclude=.DS_Store \
  ./ ioflood:/root/midrolo/
```

### 5. Create `.env` on the server

```bash
ssh ioflood
cd /root/midrolo
cp .env.example .env && chmod 600 .env
openssl rand -hex 64      # paste as SECRET_KEY_BASE
openssl rand -hex 24      # paste as MIDROLO_DATABASE_PASSWORD
nano .env
```

`.env.example` says what each variable does. The uncommented ones are required, and production refuses to start,
naming each one that's missing (`lib/required_env.rb`):

- `APP_URL=https://midrolo.com`, `SECRET_KEY_BASE`, `MIDROLO_DATABASE_PASSWORD`
- `RESEND_API_KEY`
- `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`, `R2_BACKUP_BUCKET`
- `QLOO_API_KEY`, `PODCAST_INDEX_KEY`, `PODCAST_INDEX_SECRET` (production has no demo data)

Then uncomment and fill what you use: `ANTHROPIC_API_KEY` (reports and pitches), `GOOGLE_CLIENT_ID` and
`GOOGLE_CLIENT_SECRET` (sign in), `ADMIN_USERNAME` and `ADMIN_PASSWORD` (/admin), `ADMIN_EMAIL` (error mail),
`JUDGE_CODE`, `PROMO_PRO_UNTIL=2026-11-06`, and the `DODO_*` keys when billing goes beyond the waitlist. Leave the rest
commented out: a variable set to nothing is an empty string, not unset.

### 6. Build and start

```bash
cd /root/midrolo
docker compose up -d --build
docker compose exec web bin/rails db:prepare     # the web container already ran it on start; this confirms it
docker compose ps                                # all four healthy (web can take two minutes the first time)
```

The web container's entrypoint runs `db:prepare` before the server starts (it creates the four databases: primary,
cache, queue and cable), the jobs container waits for web to be healthy, and the backup container for the database.
The jobs container runs the image web builds (`pull_policy: never`, so it is never fetched from a registry); if
compose ever reports `midrolo-app:latest` missing, run `docker compose build web` first.

### 7. Make yourself the admin

Sign in at https://midrolo.com once with Google, then:

```bash
docker compose exec web bin/rails runner 'User.find_by!(email: "you@example.com").update!(admin: true)'
```

/admin and /admin/jobs then ask for `ADMIN_USERNAME` and `ADMIN_PASSWORD` too (unset, they're a 404).

### 8. Generate the sample reports

Once the API keys are in `.env` (this spends Qloo and LLM calls):

```bash
docker compose exec web bin/rails samples:generate
```

## After every deploy: checks

1. **Health.** `docker compose ps` shows all four `healthy`, and from anywhere:
   `curl -sI https://midrolo.com/up` answers `200`; `curl -sI http://midrolo.com/` and `curl -sI https://www.midrolo.com/`
   answer `301`/`308` to `https://midrolo.com/`.
2. **Content Security Policy.** Open the landing page, a report with its map, and a public kit with the browser's
   console open: nothing may say "Content Security Policy". The map must draw.
3. **The client's IP.** Load any page, then `docker compose logs --tail 50 web | grep 'Started GET'`: the address after
   `for` must be yours (compare with `curl -s https://ifconfig.me` on your machine), not `172.x`, `127.0.0.1` or a
   Cloudflare address.
4. **Share images.** `docker compose exec web bin/rails runner 'p ShareImages::Renderer.text_width("Midrolo", family: "ArchivoWide", weight: 800, size: 100)'`
   prints `447` (the bundled font was found; anything else means a fallback font). Then
   `curl -s -o og.png -w '%{http_code} %{content_type}\n' https://midrolo.com/samples/<a sample slug>/og.png` says
   `200 image/png`, and the image shows the card with its text.
5. **Jobs.** Run a Snapshot from the site and see it finish; `docker compose logs --tail 50 jobs` shows no errors.
6. **A backup upload.** `docker compose exec backup backup` prints `backup: uploaded midrolo-....sql.gz`, and
   `docker compose exec backup backup list` lists it.

## Updates

```bash
# on the Mac: the rsync above, then
ssh ioflood 'cd /root/midrolo && docker compose up -d --build'
```

Compose rebuilds the image and recreates web and jobs (a short restart). Migrations run in the web container's
entrypoint. Run the checks above.

Logs: `docker compose logs -f web` (or `jobs`, `db`, `backup`). A Rails console:
`docker compose exec web bin/rails console`.

## Backups

The backup container runs `bin/backup` at 03:00 UTC every night: `pg_dump` of the primary database (users, shows,
reports, kits; the cache, queue and cable databases are rebuilt by `db:prepare`), gzipped and streamed to
`R2_BACKUP_BUCKET` as `midrolo/midrolo-<UTC time>.sql.gz`, then backups older than 14 days are deleted. A failed run
uploads nothing, deletes nothing and turns the container `unhealthy` until the next good run.

```bash
docker compose exec backup backup          # back up now
docker compose exec backup backup list     # what's in R2
```

### Restore

`bin/backup restore NAME [DATABASE]` loads a backup into an existing, empty database in one transaction that stops at
the first error, so a failed restore changes nothing. (This command was tested end to end against PostgreSQL 16:
dump, upload, restore into a fresh database, same tables and rows.)

To check a backup without touching live data, restore it into a scratch database:

```bash
docker compose exec db createdb -U midrolo midrolo_restore_check
docker compose exec backup backup restore midrolo-2026-11-01T030000Z.sql.gz midrolo_restore_check
docker compose exec db psql -U midrolo -d midrolo_restore_check -c 'select count(*) from users'
docker compose exec db dropdb -U midrolo midrolo_restore_check
```

To replace the live database with a backup:

```bash
docker compose stop web jobs
docker compose exec db dropdb -U midrolo midrolo_production
docker compose exec db createdb -U midrolo midrolo_production
docker compose exec backup backup restore midrolo-2026-11-01T030000Z.sql.gz
docker compose start web jobs
```

## Taking it down

`docker compose down` in `/root/midrolo` stops and removes the four containers and `midrolo-net`, and keeps the
database volume. Removing the data too is `docker volume rm midrolo-db` (it cannot be undone: take a backup first),
then `docker image rm midrolo-app:latest midrolo-backup:latest` and `rm -rf /root/midrolo`. Outside the server: the DNS
records, the R2 buckets and token, the Google OAuth client and the Resend domain.
