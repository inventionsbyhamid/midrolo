# Handoff: from the marketplace merge to judging

Work top to bottom. The details live in [deploy.md](deploy.md) (the Coolify project and the marketplace's first
deploy), [live-smoke.md](live-smoke.md) (the Qloo check) and [judging.md](judging.md) (the judge's walk and the
submission). Midrolo first went live with the sponsor research agent; this list takes it to the marketplace.

## 1. Keys and accounts

Every variable is in [.env.example](../.env.example), with what it does.

- [x] **Qloo, OpenRouter, Podcast Index, Cloudflare R2:** in Coolify on both apps since the first deploy.
- [x] **Encryption keys:** the three `ACTIVE_RECORD_ENCRYPTION_*` values are set on both apps (2026-10-29), made with
      `bin/rails db:encryption:init`. Keep a copy with the backups: losing them makes owner emails, codes and stats
      sessions unreadable.
- [x] **The stats address:** stats@midrolo.com forwards to the team's inbox (a Cloudflare email rule).
- [x] **Spotify stats account:** signed up with the stats address. Its session (`sp_dc`) is kept outside the repo, for
      step 3.
- [ ] **Apple stats account:** an Apple ID for the stats address, for Apple Podcasts Connect invites. Optional for
      judging: Spotify is the one we checked live.
- [ ] **Google OAuth:** the consent screen is published, so any Google account can sign in.
- [ ] **Resend:** midrolo.com verified as a sending domain (request alerts, codes and claim mail use it).
- [ ] **Dodo, in test mode:** `DODO_API_KEY`, `DODO_ENVIRONMENT=test_mode`, `DODO_WEBHOOK_SECRET` and the five product
      ids from `config/plans.yml`. Judges see the waitlist either way.

Production refuses to boot without `QLOO_API_KEY`, `PODCAST_INDEX_KEY`, `PODCAST_INDEX_SECRET`, the encryption keys,
an absolute http(s) `APP_URL` and the rest of the uncommented lines in `.env.example`.

## 2. Merge and deploy

- [ ] The `marketplace` branch has every lane merged, the full suite is green, and RuboCop and Brakeman are clean.
- [ ] The judge's walk (judging.md, section 4) passes on a local run with the Fake adapters.
- [ ] Merge `marketplace` into `main`. Push only when you decide to: it deploys both apps.
- [ ] Follow deploy.md, "The marketplace: first deploy", steps 1 to 11: backup, re-read feeds, the catalog seed,
      sponsor detection, similar shows for the samples, the demo show, the Spotify session.

## 3. Our own show, verified

The Devpost points judges at **AiGM by AiHunt** (feed `https://anchor.fm/s/12d45dac/podcast/rss`, Spotify show
`2nel53b14wqMRDx2toN28f`) to see verified numbers.

- [ ] Add it: `bin/rails "catalog:add[https://anchor.fm/s/12d45dac/podcast/rss]"` in the worker's Terminal.
- [ ] Claim it while signed in as your own account. Its feed lists no owner email, so the claim gives you a token:
      paste the `midrolo-verify=...` line at the end of the show description in Spotify for Creators, save, wait for
      the feed to update (usually within 10 minutes), then press Check my feed. Or turn on "Add email to RSS feed"
      in Spotify for Creators for a while and claim by email.
- [ ] Save the Spotify session at `/admin/service_sessions` and press Test fetch with the show link.
- [ ] On the show's Stats screen, paste `https://open.spotify.com/show/2nel53b14wqMRDx2toN28f` and press "I've invited
      Midrolo" (the stats account already has access). Within a minute it reads Active, and the page shows the
      Verified badge.

## 4. Before judging (Nov 2 to 5)

- [ ] Set `qloo_daily_call_limit` in `/admin` within the key's allowance: a judge's three full reports make about 60
      to 90 calls (120 at most), and a brand search up to 10.
- [ ] Measure one real report and one real brand search: `/admin` shows each run's Qloo calls and LLM cost. Compare
      them with the judge reserve and the daily cap, and raise either if a few judges wouldn't fit.
- [ ] Raise `llm_catalog_daily_usd` if sponsor detection still has episodes waiting.
- [ ] Billing stays on the founding member waitlist (`BILLING_MODE` unset or `waitlist`). Live billing stays refused
      until an admin enters Qloo's cost per call and every paid plan keeps a 60% margin with every cap used.
- [ ] Keep the site up through judging: check `/admin` and the project in Coolify once a day.

## 5. Submission polish

- [ ] Screenshots: the six rows of the Screenshots table in `README.md`. Take them on the live site, save them in
      `docs/screenshots/`, replace the rows, and upload the same images to the Devpost gallery.
- [ ] Open the README on GitHub once and check that the Mermaid diagram under "How it works" draws.
- [ ] Then work through [judging.md](judging.md). Submissions close Fri Oct 30, 11:45 PM EDT.

## Later

- [ ] The share image (`app/assets/images/og.svg`, drawn into og.png by `bin/rails brand:build`) still carries the
      podcaster tagline. Redraw it for "Where independent podcasts get sponsored".
- [ ] A recurring `sponsors:scan` in `config/recurring.yml`, so episodes that waited for budget are picked up daily.
- [ ] Before switching `LLM_AGENT_MODEL` or the provider, add 8 to 10 real shows to `config/eval_shows.yml` and run
      `bin/rails eval:run` with live keys.
- [ ] After the hackathon, deploy.md's "Taking it down" lists everything to remove, on the server and outside it.
