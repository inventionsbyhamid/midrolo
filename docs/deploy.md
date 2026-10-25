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
| Services and containers | `midrolo-web` (Thruster and Puma), `midrolo-jobs` (Solid Queue), `midrolo-db` (Postgres 16), `midrolo-backup` |
| DNS aliases | the same four names: compose makes each service's name an alias on every network it joins, so `midrolo-web` is one on the shared `coolify` network too |
| Images | `midrolo-app:latest` (web and jobs), `midrolo-backup:latest` (pulls `postgres:16`) |
| Network | `midrolo-net`, this stack's own bridge; `midrolo-web` also joins the existing external `coolify` network |
| Volumes | `midrolo-db` (the database), `midrolo-backup-state` (whether the last backup failed) |
| Traefik | routers `midrolo-http`, `midrolo-https`, `midrolo-www`; service `midrolo-web`; middlewares `midrolo-https-redirect`, `midrolo-www-redirect` (labels on `midrolo-web`, gone when it is) |
| Files | `/root/midrolo` (the code and `.env`) |
| Outside the server | DNS records for midrolo.com and www, two R2 buckets and their two tokens, the Google OAuth client, the Resend domain |

Every `docker compose` command below runs in `/root/midrolo` and names these services: `midrolo-web`, `midrolo-jobs`,
`midrolo-db`, `midrolo-backup`.

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
  addresses (`config/initializers/client_ip.rb`). A Forwarded or Client-IP header a visitor sends never counts.
- The database is on `midrolo-net` only, so no other stack can reach it. `midrolo-web` is also on `coolify`, which
  other stacks' web containers share, so network placement does not keep it off their ports. The code does (R131):
  every user-supplied URL (a feed, show artwork) is resolved once, refused if any address is internal (private,
  loopback, link-local, NAT64 and 6to4 ranges included), and fetched from the address that was checked, never from a
  second DNS lookup, so a rebinding DNS answer can't move the request. Each redirect hop is checked the same way.

## First deploy

### 1. DNS

At Cloudflare, for midrolo.com:

- `A midrolo.com → 107.167.86.146`
- `A www.midrolo.com → 107.167.86.146` (or a `CNAME` to midrolo.com), for the redirect and its certificate.

Add no `AAAA` record unless the IPv6 check below passes. Start with **DNS only** (grey cloud): Traefik gets Let's
Encrypt certificates over plain HTTP-01, and Rails sees the client's real address directly. Turning the proxy on later
works too: set SSL/TLS to **Full (strict)**, and the app reads CF-Connecting-IP (check it after, as below).

### 2. Check the proxy and the names (read only)

The labels assume Coolify's defaults: entrypoints `http` and `https`, certificate resolver `letsencrypt`, network
`coolify`. Confirm them against a site that already works, and check that nothing on the `coolify` network already
answers to a `midrolo-*` name, without changing anything:

```bash
ssh ioflood
docker network ls --filter name=^coolify$
docker ps --format '{{.Names}}' | grep -i storyquest
docker inspect <that container> --format '{{json .Config.Labels}}' | tr ',' '\n' | grep -E 'entrypoints|certresolver|docker.network'

# Before the first deploy, both of these must print nothing.
docker network inspect coolify --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' | grep -i midrolo
docker network inspect coolify --format '{{range $id, $c := .Containers}}{{$id}}{{"\n"}}{{end}}' \
  | xargs -r docker inspect --format '{{.Name}} {{json .NetworkSettings.Networks.coolify.Aliases}}' \
  | grep -i midrolo
```

The first lists the containers on `coolify`, the second their aliases (compose's service names among them). If either prints anything, stop:
another container already uses a `midrolo-*` name there. If the labels' names differ, change them in `compose.yml`
to match before going on.

### 3. Outside services

- **Cloudflare R2:** two buckets, one for uploads (`R2_BUCKET`) and one for backups (`R2_BACKUP_BUCKET`), and two API
  tokens: the app's (`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`) with Object Read and Write on the uploads bucket
  only, and the backup container's (`BACKUP_R2_ACCESS_KEY_ID`, `BACKUP_R2_SECRET_ACCESS_KEY`) with Object Read and
  Write on the backup bucket only. Then the app can't reach the backups, and the backups can't reach the uploads.
  Neither bucket needs public access.
- **Google OAuth client:** authorized redirect URI `https://midrolo.com/users/auth/google_oauth2/callback`.
- **Resend:** verify the domain midrolo.com (its DNS records) so mail can come from `hello@midrolo.com`.
- **Dodo** (only when billing leaves waitlist mode): webhook URL `https://midrolo.com/webhooks/dodo`.

### 4. Send the code

From the Mac, in the repository (the same filters as `bin/remote-rspec`: of the `.env*` files only `.env.example`,
which holds no values, is sent; keys never leave the Mac; and `--delete` leaves the server's own `.env` alone because
it's excluded):

```bash
rsync -az --delete \
  --exclude=/.git --exclude=/.claude/ --exclude=/.superpowers/ --exclude=/.bundle/ --exclude=/.kamal/ \
  --exclude=/tmp/ --exclude=/log/ --exclude=/storage/ --exclude=/coverage/ --exclude=/node_modules/ \
  --exclude=/vendor/bundle/ --exclude=/public/assets/ --exclude='/app/assets/builds/*' \
  --include=/.env.example --exclude='.env*' --exclude=/config/master.key --exclude='/config/credentials/*.key' \
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

`.env.example` says what each variable does. The uncommented ones are required. Production refuses to start, naming
each one that's missing or, for `APP_URL`, not an absolute `https://` address (`lib/required_env.rb`), and compose
refuses to start the backup container without its own:

- `APP_URL=https://midrolo.com`, `SECRET_KEY_BASE`, `MIDROLO_DATABASE_PASSWORD`
- `RESEND_API_KEY`
- `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET` (the app's token and bucket)
- `R2_BACKUP_BUCKET`, `BACKUP_R2_ACCESS_KEY_ID`, `BACKUP_R2_SECRET_ACCESS_KEY` (the backups' bucket and token)
- `QLOO_API_KEY`, `PODCAST_INDEX_KEY`, `PODCAST_INDEX_SECRET` (production has no demo data)

Then uncomment and fill what you use: `ANTHROPIC_API_KEY` (reports and pitches), `GOOGLE_CLIENT_ID` and
`GOOGLE_CLIENT_SECRET` (sign in), `ADMIN_USERNAME` and `ADMIN_PASSWORD` (/admin), `ADMIN_EMAIL` (error mail),
`JUDGE_CODE`, `PROMO_PRO_UNTIL=2026-11-06`, and the `DODO_*` keys when billing goes beyond the waitlist. Leave the rest
commented out: a variable set to nothing is an empty string, not unset.

### 6. Build and start

```bash
cd /root/midrolo
docker compose up -d --build
docker compose exec midrolo-web bin/rails db:prepare   # the container already ran it on start; this confirms it
docker compose ps                                      # all four healthy (midrolo-web can take two minutes at first)
```

The `midrolo-web` container's entrypoint runs `db:prepare` before the server starts (it creates the four databases:
primary, cache, queue and cable), `midrolo-jobs` waits for `midrolo-web` to be healthy, and `midrolo-backup` for the
database. `midrolo-jobs` runs the image `midrolo-web` builds (`pull_policy: never`, so it is never fetched from a
registry); if compose ever reports `midrolo-app:latest` missing, run `docker compose build midrolo-web` first.

### 7. Make yourself the admin

Sign in at https://midrolo.com once with Google, then:

```bash
docker compose exec midrolo-web bin/rails runner 'User.find_by!(email: "you@example.com").update!(admin: true)'
```

/admin and /admin/jobs then ask for `ADMIN_USERNAME` and `ADMIN_PASSWORD` too (unset, they're a 404).

### 8. Generate the sample reports

Once the API keys are in `.env` (this spends Qloo and LLM calls):

```bash
docker compose exec midrolo-web bin/rails samples:generate
```

## After every deploy: checks

1. **Health.** `docker compose ps` shows all four `healthy`, and from anywhere:
   `curl -sI https://midrolo.com/up` answers `200`; `curl -sI http://midrolo.com/` and `curl -sI https://www.midrolo.com/`
   answer `301`/`308` to `https://midrolo.com/`.
2. **Content Security Policy.** Open the landing page, a report with its map, and a public kit with the browser's
   console open: nothing may say "Content Security Policy". The map must draw.
3. **The client's IP.** From your own machine, note your address (`curl -s https://ifconfig.me`), then:

   ```bash
   # 1. A plain request, and one carrying every header a visitor might forge.
   curl -s -o /dev/null https://midrolo.com/pricing
   curl -s -o /dev/null https://midrolo.com/about \
     -H 'X-Forwarded-For: 203.0.113.9' -H 'CF-Connecting-IP: 203.0.113.9' -H 'Forwarded: for=203.0.113.9'
   # 2. A Client-IP that disagrees with X-Forwarded-For: prints 400.
   curl -s -o /dev/null -w '%{http_code}\n' https://midrolo.com/pricing -H 'Client-IP: 203.0.113.9'
   ```

   Then on ioflood, `docker compose logs --tail 50 midrolo-web | grep -E 'Started GET "/(pricing|about)"'`: the address
   after `for` must be yours on both lines, never `203.0.113.9`, `172.x`, `127.0.0.1` or a Cloudflare address.

   **IPv6.** If midrolo.com has an `AAAA` record, repeat the plain request with `curl -6` from a machine with IPv6 and
   look for your IPv6 address in the log. If IPv6 visitors show up as a Docker network's gateway instead (a private
   address such as `172.x`, the same for all of them), they share one rate-limit bucket: remove the `AAAA` record, so browsers reach
   the site over IPv4, or turn Cloudflare's proxy on, which reaches the server over IPv4 and names the client in
   CF-Connecting-IP. (Enabling IPv6 in Docker is a server-wide change, not this stack's to make.) With no `AAAA` record,
   `curl -6` can't connect, and every visitor arrives over IPv4.
4. **Share images.** `docker compose exec midrolo-web bin/rails runner 'p ShareImages::Renderer.text_width("Midrolo", family: "ArchivoWide", weight: 800, size: 100)'`
   prints `447` (the bundled font was found; anything else means a fallback font). Then
   `curl -s -o og.png -w '%{http_code} %{content_type}\n' https://midrolo.com/samples/<a sample slug>/og.png` says
   `200 image/png`, and the image shows the card with its text.
5. **Jobs.** Run a Snapshot from the site and see it finish; `docker compose logs --tail 50 midrolo-jobs` shows no
   errors.
6. **A backup upload.** `docker compose exec midrolo-backup backup` prints `backup: uploaded midrolo-....sql.gz`, and
   `docker compose exec midrolo-backup backup list` lists it.

## Updates

```bash
# on the Mac: the rsync above, then
ssh ioflood 'cd /root/midrolo && docker compose up -d --build'
```

Compose rebuilds the images and recreates `midrolo-web` and `midrolo-jobs` (a short restart). Migrations run in the
`midrolo-web` container's entrypoint. Run the checks above.

Logs: `docker compose logs -f midrolo-web` (or `midrolo-jobs`, `midrolo-db`, `midrolo-backup`). A Rails console:
`docker compose exec midrolo-web bin/rails console`.

## Backups

The `midrolo-backup` container runs `bin/backup` at 03:00 UTC every night: `pg_dump` of the primary database (users,
shows, reports, kits; the cache, queue and cable databases are rebuilt by `db:prepare`), gzipped and streamed to
`R2_BACKUP_BUCKET` as `midrolo/midrolo-<UTC time>.sql.gz`, then backups older than 14 days are deleted. It uses its
own R2 token, scoped to the backup bucket. A failed run uploads nothing and deletes nothing.

```bash
docker compose exec midrolo-backup backup          # back up now
docker compose exec midrolo-backup backup list     # what's in R2
```

### When a backup fails

A failed run is recorded on the `midrolo-backup-state` volume and stays recorded, through restarts and redeploys,
until a later backup succeeds (the next night's, or one run by hand). Meanwhile the container is `unhealthy`:

```bash
docker compose ps midrolo-backup                     # STATUS says (unhealthy)
docker compose exec midrolo-backup backup health     # says which backup failed, and when
docker compose logs --tail 100 midrolo-backup        # why: pg_dump's or aws's own error
```

Fix the cause (often a token or bucket setting in `.env`, then `docker compose up -d midrolo-backup`), then run
`docker compose exec midrolo-backup backup`: when it succeeds, the container is healthy again.

### Restore

`bin/backup restore NAME [DATABASE]` downloads the whole backup first and checks it: a complete gzip file
(`gzip -t`) holding a complete dump (pg_dump's closing line). Only then does it load it into the database, which must
exist and be empty, in one transaction that stops at the first error. So a restore that fails, whether at the
download, the check or any statement, leaves the database as it was. The download is deleted either way. (Tested end
to end against PostgreSQL 16: dump, upload, restore into a fresh database, same tables and rows.)

To check a backup without touching live data, restore it into a scratch database:

```bash
docker compose exec midrolo-db createdb -U midrolo midrolo_restore_check
docker compose exec midrolo-backup backup restore midrolo-2026-11-01T030000Z.sql.gz midrolo_restore_check
docker compose exec midrolo-db psql -U midrolo -d midrolo_restore_check -c 'select count(*) from users'
docker compose exec midrolo-db dropdb -U midrolo midrolo_restore_check
```

To replace the live database with a backup:

```bash
docker compose stop midrolo-web midrolo-jobs
docker compose exec midrolo-db dropdb -U midrolo midrolo_production
docker compose exec midrolo-db createdb -U midrolo midrolo_production
docker compose exec midrolo-backup backup restore midrolo-2026-11-01T030000Z.sql.gz
docker compose start midrolo-web midrolo-jobs
```

Between the `dropdb` and a successful restore, the live database is empty: if the restore fails, fix the cause and
run it again (or restore an older backup) before starting `midrolo-web` and `midrolo-jobs`.

## Taking it down

`docker compose down` in `/root/midrolo` stops and removes the four containers and `midrolo-net`, and keeps the
volumes. Removing the data too is `docker volume rm midrolo-db midrolo-backup-state` (it cannot be undone: take a
backup first), then `docker image rm midrolo-app:latest midrolo-backup:latest` and `rm -rf /root/midrolo`. Outside the
server: the DNS records, the R2 buckets and both tokens, the Google OAuth client and the Resend domain.
