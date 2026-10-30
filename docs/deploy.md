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
| `midrolo-worker` | The same image with `MIDROLO_PROCESS=jobs`, which starts Solid Queue (`bin/jobs`) instead of the web server. No domain, no health check. `RAILS_MAX_THREADS=13`: every job thread in `config/queue.yml` (3 + 3 + 1 + 2 + 1 + 1), plus 2. |
| `midrolo-db` | Postgres 18, not reachable from outside the server. It holds `midrolo_production` and the cache, queue and cable databases, which `db:prepare` creates. |

Each app is capped at 2 CPUs and 2 GB.

## How a request gets in

```
browser ─https─▶ Cloudflare (proxy on) ─https─▶ Traefik (Coolify's proxy, ports 80/443, Let's Encrypt)
                   └─ coolify network ─▶ midrolo:80 (Thruster) ─▶ Puma :3000
midrolo, midrolo-worker ─ coolify network ─▶ midrolo-db:5432
```

- Coolify writes the Traefik labels: `midrolo.com` on `https` with a Let's Encrypt certificate, `http` redirected to
  `https`, and `www.midrolo.com` redirected to the apex. DNS is two `A` records, `midrolo.com` and `www`, pointing at
  the server, with no `AAAA`.
- **Cloudflare's proxy is on** (orange cloud, since 2026-10-29). Pages are dynamic and never cached at the edge.
  Catalog artwork, served through Active Storage's proxy with a long, public, immutable Cache-Control, is cached at
  the edge (`cf-cache-status: HIT` on a second request). A removed show's artwork may stay in Cloudflare's cache for
  up to its TTL; the data sources page says so, and an urgent takedown gets a manual purge in Cloudflare.
- Rails reads the client from CF-Connecting-IP, but only when the nearest hop that isn't our own proxy is a
  Cloudflare address, which a visitor can't fake (`config/initializers/client_ip.rb`, cloudflare-rails).
- TLS ends at Traefik, so Rails runs with `assume_ssl` and `force_ssl` (secure cookies, HSTS) and never redirects.
- Rails answers only for `midrolo.com` and `www.midrolo.com`; `/up`, the health check, answers any host.
- The client's IP (`request.remote_ip`, which the rate limits use) comes from X-Forwarded-For, which Traefik and
  Thruster write. A Forwarded or Client-IP header a visitor sends never counts (`config/initializers/client_ip.rb`).
- **Rate limits.** Every request counts against 60 a minute per IP (`ApplicationController`), with tighter limits on
  forms, searches and report starts. Search engine crawlers past the 60 keep reading pages (GET and HEAD only) once
  DNS confirms them (`VerifiedCrawler`): a Googlebot, Bingbot or Applebot user agent is only a reason to look; the
  IP's reverse name must be in googlebot.com, google.com, search.msn.com or applebot.apple.com and resolve back to
  the same IP. The answer is cached per IP for a day (15 minutes when it fails), and nothing is looked up below the
  limit. A user agent alone never counts, and crawlers' writes and directory searches keep every limit.
- Every container on the `coolify` network can reach every other one, so the network keeps nothing out. The code does
  (R131): every user-supplied URL (a feed, show artwork) is resolved once, refused if any address is internal
  (private, loopback, link-local, NAT64 and 6to4 ranges included), and fetched from the address that was checked,
  never from a second DNS lookup. Each redirect hop is checked the same way.

## Settings

Each app holds every variable in [`.env.example`](../.env.example) that production uses, set in Coolify as
**runtime only** (Coolify's build variable switch off). The `Dockerfile` refuses to build when a secret would be passed
as a build argument (`# check=error=true`), and the build needs none: assets compile with a dummy secret key. Both
apps hold the same values; the worker adds `MIDROLO_PROCESS=jobs` and `RAILS_MAX_THREADS=13`.

- `DB_HOST` is the database resource's container name, `MIDROLO_DATABASE_PASSWORD` its password (user `midrolo`).
- `APP_URL=https://midrolo.com`; `SECRET_KEY_BASE` was made with `bin/rails secret`.
- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` and
  `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` were made with `bin/rails db:encryption:init`. They encrypt feed owner
  emails, verification addresses and stats credentials: keep them with the backups, since changing one makes what it
  encrypted unreadable.
- The rest are the service keys: Qloo, Podcast Index, OpenRouter, Resend, Google OAuth, Cloudflare R2 (uploads),
  the admin login and `PROMO_PRO_UNTIL` (the hackathon trial's last day).
- Optional for the marketplace: `MIDROLO_SPOTIFY_EMAIL` and `MIDROLO_APPLE_EMAIL` (the stats address podcasters
  invite; unset means stats@midrolo.com), `LLM_CHEAP_MODEL` (sponsor checks and brand briefs) and
  `LLM_CATALOG_DAILY_USD` (their own daily cap; `/admin` overrides it).

Production stops at boot, naming the variable, when a required one is blank (`lib/required_env.rb`). After changing a
variable, redeploy (or restart) both apps.

## The stats helper (Spotify and Apple Podcasts)

"Invite Midrolo" reads verified Spotify and Apple Podcasts numbers through `bin/platform-stats`, a small Python
program (`script/platform_stats.py`) that `Stats::PlatformFetch` runs with the request on stdin. It uses
openpodcast's MIT licensed connectors, `spotifyconnector` 0.8.3 and `appleconnector` 0.4.1, pinned with every
package's hashes in `requirements-stats.txt`.

- **No settings.** The helper reads no environment variables and no files. Midrolo's service sessions (Spotify
  `sp_dc`, Apple `myacinfo` and `itctx`) are pasted by an admin in /admin, stored encrypted in the database, and handed
  to the helper on stdin for each fetch. They never go in job arguments, logs or the helper's output.
- **In the image.** The `Dockerfile` installs bookworm's `python3` (3.11) and builds `/opt/stats-venv` in the build
  stage, then copies it into the final image without pip (about 35 MB in all). `bin/platform-stats` uses that venv.
- **Time.** The helper stops itself after 50 seconds; Rails waits 60. Spotify windows end yesterday at the latest,
  because Spotify hasn't counted today yet.
- **Check it.** `bin/platform-stats --self-test` (in the app's Terminal) prints `{"ok":true,"self_test":true}`, offline.
  `bin/platform-stats --help` documents every request and result key.
- **Develop and test.** `python3 -m venv ~/.venvs/midrolo-stats`, then
  `~/.venvs/midrolo-stats/bin/pip install -r requirements-stats.txt`. Run the tests with
  `~/.venvs/midrolo-stats/bin/python -m unittest discover -s test/python`, and the helper with
  `PLATFORM_STATS_PYTHON=~/.venvs/midrolo-stats/bin/python bin/platform-stats`. CI runs both on Python 3.11.
- **Upgrading a connector.** Change its pin and hashes (from `https://pypi.org/pypi/<name>/<version>/json`) and
  `PINNED` in the script. The helper replaces the connectors' HTTP loop, so read their changes first, then run the
  tests and a live fetch from /admin.

### Service sessions: Midrolo's own Spotify and Apple accounts

Podcasters invite the stats address (stats@midrolo.com, which forwards to the team's inbox) to their show. The helper
then signs in as that account with its saved session.

- **Accept each invite** from the email Spotify or Apple sends to the stats address. `/admin/stat_connections` lists
  the pending invites oldest first, with how long each has waited. Midrolo checks a pending invite every 15 minutes
  for 2 hours, then hourly for a day, then every 6 hours, for 14 days; the first fetch that works makes it Active.
- **Save the session** at `/admin/service_sessions` (Spotify needs `sp_dc`; `sp_key` is optional; Apple takes
  `myacinfo` and `itctx`). The form is never prefilled and never shows a saved value. Or, in the worker's Terminal,
  `bin/rails "stats:session[spotify]" < file`, which reads JSON or `KEY=value` lines from stdin and prints only the
  key names. Then press **Test fetch** with a connection or a Spotify show link.
- **Rate limits (Stats::Throttle, per platform).** Midrolo stays a light, polite client of its own accounts: one
  helper run at a time, at least 30 seconds apart plus up to 15 random seconds, at most 40 runs an hour and 300 a day.
  A rate-limited answer starts a cooldown (the platform's Retry-After, else an hour, doubling on repeats up to 24
  hours); 5 failed runs in a row pause the platform for an hour. Syncs that must wait are rescheduled, never dropped.
  The Spotify token is reused for its hour, so the account signs in at most once an hour. Each show syncs once a day
  at its own minute; the 12-month audience call runs at most weekly. `/admin/service_sessions` shows runs this hour
  and today, the next allowed run and any cooldown, and edits the four limits (STATS_MIN_GAP_SECONDS,
  STATS_GAP_JITTER_SECONDS, STATS_RUNS_PER_HOUR, STATS_RUNS_PER_DAY).
- **When a session expires,** syncs pause, the session shows Expired, and one email goes to the admins. Save a new
  session and syncs resume on their own.
- **Connections held for review.** A platform show that matches a podcast by name only, while another catalog
  podcast has the same name, could be a clone pointing at a real show, so nothing counts until an admin looks. It
  waits under "Doesn't match" in `/admin/stat_connections` with "Midrolo will check it by hand" (the owner's Stats
  screen says "Being checked"). Open the platform show and the podcast's page and compare them, then press
  **Approve** (it syncs at once and turns Active) or **Reject** (it is disconnected, any numbers from that platform
  come off the podcast's page, the owner's Stats screen says it was checked by hand, and the platform show is free
  for another page to connect).

## Payments

Billing goes through one adapter per payment provider (`app/services/billing/provider.rb`); nothing else in the app
names a vendor. Production runs Dodo Payments, in Midrolo's own Dodo business, in **test mode**: `BILLING_MODE` is
unset, so everyone sees the founding member waitlist, and only admins (and accounts an admin flags as judges) see
"Try checkout in test mode" (test card 4242 4242 4242 4242).

- **Test mode settings:** `DODO_API_KEY` (a `dodo_test_` key), `DODO_ENVIRONMENT=test_mode`, `DODO_WEBHOOK_SECRET`
  (the test webhook to `https://midrolo.com/webhooks/dodo`, which is enabled) and the five `DODO_PRODUCT_*` test ids.
- **Going live:** the live catalog and its webhook already exist in Dodo, the webhook switched off. Swap in the live
  key, `DODO_ENVIRONMENT=live_mode`, the live webhook's secret and the live product ids; switch the live webhook on in
  Dodo; set `BILLING_MODE=live`; redeploy. Live mode still waits for the go-live check (R94: Qloo's price per call
  set in `/admin`, and every paid plan keeping a 60% margin), and shows the waitlist until it passes.

### Switching payment provider

1. Add an adapter in `app/services/billing/providers/` with the interface `provider.rb` documents: checkout, the
   customer portal, webhook verification and parsing into `Billing::Event`, plus `configured?`, `environment`,
   `setup`, `live_setup` and `fees`. `spec/services/billing/provider_spec.rb` checks every registered adapter has them.
2. Register it in `Billing::Provider::ADAPTERS` (and `REAL`), and add its product ids under its name in
   `config/plans.yml` `product_ids`.
3. Set `BILLING_PROVIDER` and the new provider's keys, create its products and point its webhook at
   `https://midrolo.com/webhooks/<name>`.
4. Update who takes the payment in the privacy and terms pages, and the Content Security Policy if its checkout or
   portal loads on midrolo.com rather than on its own domain.

Existing subscriptions keep their `provider` and stay with the old provider until they end.

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

## The marketplace: first deploy

The marketplace adds the catalog, sponsor detection, verified stats, brand searches and conversations. Its first
deploy needs these steps once, in order. Commands run in the **worker's** Terminal (they queue work for it).

1. **Back up the database** (Backups, below) and check the file exists.
2. **Encryption keys** are set on both apps (Settings, above). Production refuses to boot without them.
3. **Deploy** (push to `main`) and watch both apps come up. The migrations move each show onto a podcast record.
4. **Read every existing feed again**, which refills owner emails and feed facts:
   `bin/rails catalog:refresh`.
5. **Seed the catalog.** First set `qloo_daily_call_limit` to 500 in `/admin` (the seed reads 21 genre tags, 50 shows
   a call, and needs roughly 60 to 150 calls for 1,000 shows, on top of reports and brand searches). Then
   `bin/rails "catalog:seed_paced[1000,6]"`: one Qloo page at a time, spread over 6 hours (about one page every 9
   minutes to start), each page's directory searches about one a second. Running it again while it runs starts
   nothing. `bin/rails catalog:seed_stop` stops it after the page it is on; running it again picks up where it
   stopped (also after Qloo's daily cap stopped it: raise the cap first). Watch the Paced seed block in `/admin`'s
   Catalog panel (Running, the next page, pages read, linked so far) and the catalog and artwork queues in
   `/admin/jobs`. The one shot `catalog:seed[1000]` still exists for development; production uses the paced seed.

   **Popular shows** (no Qloo calls): `bin/rails "catalog:seed_charts[us,200]"` adds the shows on Apple's Top
   Podcasts chart that the catalog doesn't have yet, so the directory has names people know beside the mid-size
   shows above. Arguments: store country (default `us`), how many (1 to 200, default 200), and an Apple genre id for
   one genre's chart (default all, for example `catalog:seed_charts[us,100,1318]` for Technology). Each show is looked
   up by its Apple id in the directory, else through Apple's lookup for its feed URL, about one lookup a second (a
   full chart takes 4 to 10 minutes); new shows are read at the seed's low priority. It prints one line: charted,
   added, already in the catalog, skipped (removed or suppressed) and failed, and names each failure. Safe to run
   again: shows already in the catalog cost nothing.
6. **Sponsor detection.** New episodes are scanned as they're read. For the backfill, raise `llm_catalog_daily_usd`
   in `/admin` (about $5 to $10 covers 1,000 shows), then `bin/rails sponsors:scan` (200 podcasts a run), again if
   episodes are still waiting. Strong pattern reads are saved even when the budget runs out. After that the daily
   sponsors sweep (`sweep_sponsors` in `config/recurring.yml`, every day at 4:10am, up to 100 podcasts) picks up
   episodes that waited for the budget; nothing to set up.
7. **Similar shows for the samples:** `bin/rails matching:similar_backfill` (one Qloo call per sample report).
8. **The demo show:** `bin/rails demo:setup`. `DEMO_OWNER_EMAIL` picks the owner account; unset means the first admin.
   It prints the page's address.
9. **Add a show by hand** when you need one: `bin/rails "catalog:add[<feed URL, Apple link or name>]"`. Spotify links
   are refused; use the show's RSS feed.
10. **Verified stats:** save the Spotify session (above), then `bin/rails stats:backfill_provided` turns owners' typed
    downloads into "provided by the show" numbers. Look at `/admin/stat_connections` now and then for connections
    held for review (Service sessions, above): **Approve** or **Reject** each.
11. **Check `/admin`:** catalog counts and feed errors, sponsor detection, stats connections, Qloo calls and LLM
    spend.

## After every deploy: checks

1. **Health.** All three resources are running (healthy) in Coolify, and from anywhere:
   `curl -sI https://midrolo.com/up` answers `200`; `curl -sI http://midrolo.com/` and
   `curl -sI https://www.midrolo.com/` redirect to `https://midrolo.com/`.
2. **Content Security Policy.** Open the landing page, a report with its map, and a public kit with the browser's
   console open: nothing may say "Content Security Policy". The map must draw.
3. **The client's IP.** Request `https://midrolo.com/pricing` once plainly and once with
   `-H 'X-Forwarded-For: 203.0.113.9' -H 'CF-Connecting-IP: 203.0.113.9' -H 'Forwarded: for=203.0.113.9'`. In the
   app's logs, the address after `for` must be yours on both lines, never `203.0.113.9`, a Cloudflare address or a
   Docker address (`10.x`, `172.x`). A request whose `Client-IP` disagrees with X-Forwarded-For gets `400`.
4. **Share images.** `bin/rails runner 'p ShareImages::Renderer.text_width("Midrolo", family: "ArchivoWide", weight: 800, size: 100)'`
   prints `447` (the bundled font was found), and `https://midrolo.com/samples/<a sample slug>/og.png` answers
   `200 image/png`.
5. **Jobs.** Run a Snapshot from the site and see it finish; the worker's logs show no errors.
6. **A backup.** The database's Backups tab in Coolify lists a recent successful run.
7. **The stats helper.** `bin/platform-stats --self-test` in the app's Terminal prints `{"ok":true,"self_test":true}`.
8. **The marketplace.** `/podcasts`, a podcast page, a brand page and `/sitemap.xml` answer 200. A podcast's artwork
   answers `cf-cache-status: HIT` on its second request. `/admin` shows no new feed errors in a row and a working
   Spotify session.

## Backups

Coolify backs up `midrolo_production` every hour (at :20) and uploads it to the server's existing S3 storage, a
Cloudflare R2 bucket: 12 backups kept on the server (up to 3 days), 48 in R2 (up to 7 days). The cache, queue and cable
databases aren't backed up: `db:prepare` rebuilds them. **Backup Now** and restores are on the database's Backups and
Import Backups tabs in Coolify.

## Taking it down

Take a last backup, then delete the `midrolo` project in Coolify (its apps, the database and its volume). Outside the
server: the DNS records and the Cloudflare proxy settings, the uploads R2 bucket and its token, the Google OAuth
client, the Resend domain, the Coolify API token made for this project, the stats address's forwarding rule, and the
Spotify and Apple accounts behind it (remove Midrolo from every show team that invited it first, or let podcasters
know).
