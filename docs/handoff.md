# Handoff: from keys to judging

Work top to bottom. The details live in [deploy.md](deploy.md) (the Coolify project), [live-smoke.md](live-smoke.md) (the
Qloo check) and [judging.md](judging.md) (the submission). The build is done: a fresh clone runs in demo mode with no
keys (checked on 2026-10-26: sign in, add a show, Snapshot, promo full report, pitch, kit upload and preview, samples,
mail).

## 1. Collect the keys

Every variable is in [.env.example](../.env.example), with what it does.

- [x] **Qloo:** the key is in hand. Ask Qloo for its daily call allowance now; step 5 needs it.
- [x] **OpenRouter:** `OPENROUTER_API_KEY`, for full reports and pitches (the model is `LLM_AGENT_MODEL` and
      `LLM_PITCH_MODEL`). Midrolo has its own key with a credit limit; keep the account topped up.
- [x] **Podcast Index:** `PODCAST_INDEX_KEY`, `PODCAST_INDEX_SECRET`.
- [ ] **Google OAuth:** `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`. Redirect URI
      `https://midrolo.com/users/auth/google_oauth2/callback`. Publish the consent screen so any account can sign in.
- [ ] **Resend:** `RESEND_API_KEY`, with midrolo.com verified as a sending domain.
- [x] **Cloudflare R2:** `R2_ACCOUNT_ID`, and the uploads bucket `R2_BUCKET` with the app's token
      `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`, Object Read and Write on that bucket only. (Database backups go
      through Coolify, so the backup bucket and token are for [self-hosting.md](self-hosting.md) only.)
- [ ] **Dodo, in test mode** (for the judges' test checkout): `DODO_API_KEY`, `DODO_ENVIRONMENT=test_mode`,
      `DODO_WEBHOOK_SECRET` (webhook URL `https://midrolo.com/webhooks/dodo`), and five products, one per price key
      in `config/plans.yml`:

  | Price key | Product | Variable |
  | --- | --- | --- |
  | `creator_monthly` | Creator, $19 a month | `DODO_PRODUCT_CREATOR_MONTHLY` |
  | `creator_yearly` | Creator, $190 a year | `DODO_PRODUCT_CREATOR_YEARLY` |
  | `pro_monthly` | Pro, $49 a month | `DODO_PRODUCT_PRO_MONTHLY` |
  | `pro_yearly` | Pro, $490 a year | `DODO_PRODUCT_PRO_YEARLY` |
  | `sprint` | Sprint, $49 once (Pro for 30 days) | `DODO_PRODUCT_SPRINT` |

- [x] **Your own values:** `ADMIN_EMAIL` (optional), `JUDGE_CODE` (never in the repo:
      `docs/devpost.md` keeps `<<JUDGE_CODE>>`), `PROMO_PRO_UNTIL=2026-11-06`.
- [x] **In Coolify** (deploy.md, Settings): every value above on both apps, runtime only, plus `SECRET_KEY_BASE`,
      `APP_URL=https://midrolo.com`, `DB_HOST` and `MIDROLO_DATABASE_PASSWORD` (the database resource's). Google and
      Resend go in when they arrive (Resend holds a placeholder so production boots), then redeploy both apps.

Production refuses to boot without `QLOO_API_KEY`, `PODCAST_INDEX_KEY`, `PODCAST_INDEX_SECRET`, an absolute http(s)
`APP_URL` and the rest of the uncommented lines in `.env.example`.

## 2. Before the first deploy, in the repo

- [x] `config/samples.yml`: each sample's `directory_id` is the field to change. Replace `fake-1`, `fake-2` and
      `fake-3` with the Podcast Index feed ids of three public shows. A feed id is the number in the show's
      podcastindex.org URL (`https://podcastindex.org/podcast/<id>`), or the `feed.id` that the API's
      `/podcasts/byfeedurl` lookup returns for its RSS URL. The `fake-` ids exist only in the demo catalog, so
      `samples:generate` with live keys needs real ones.
- [ ] Commit. Push and create anything on GitHub or GitLab only when you decide to.

## 3. Deploy ([deploy.md](deploy.md))

- [x] DNS at Cloudflare: `A midrolo.com` and `A www.midrolo.com` to the server, DNS only (grey cloud), no `AAAA`.
- [x] The Coolify project `midrolo`: the `midrolo` web app, `midrolo-worker` and the `midrolo-db` Postgres, with
      hourly backups to R2. Pushing to `main` deploys both apps.
- [ ] Sign in once with Google, then set your admin flag (deploy.md, Running commands).

## 4. After the deploy

- [ ] Live Qloo smoke: `bin/rails qloo:smoke` in the app's terminal. 8 calls, at most 10
      ([live-smoke.md](live-smoke.md)).
- [ ] Samples: `bin/rails samples:generate` (Qloo calls plus a few cents of LLM each). Read each sample at https://midrolo.com/samples.
- [ ] deploy.md's "After every deploy" checks:
  - health: `/up` answers 200, and http and www redirect to `https://midrolo.com/`;
  - the browser console shows no Content Security Policy errors, and the map draws;
  - `remote_ip` in the log is your own address;
  - a share image renders (`text_width` prints 447, `og.png` answers `200 image/png`);
  - a Snapshot finishes;
  - the database's Backups tab in Coolify shows a recent successful backup.

## 5. Before judging (Nov 2 to 5)

- [ ] Ask Qloo for the key's daily allowance, then set `qloo_daily_call_limit` in `/admin` within it. How high to
      go is your decision. For context: the default is 100 a day, and a judge's three agent reports make about 60 to
      90 calls, 120 at most (40 a report, R130). Development counts its calls apart, against the same key
      (live-smoke.md).
- [ ] Measure one real report before judging (R136). Run one full agent report on production keys (a sample from
      step 4 counts), then note its LLM cost and its Qloo calls: `/admin` shows both per done full report. Compare
      them with the judge reserve (`JUDGE_RESERVE_USD`, $5 at launch), which every judge's three reports draw on, and
      with the daily Qloo cap (`qloo_daily_call_limit`), which a day's judge reports share with every other run. If a
      few judges' reports wouldn't fit, raise either in `/admin` (the cap within Qloo's allowance).
- [ ] Billing stays on the founding member waitlist (`BILLING_MODE` unset or `waitlist`). Live billing stays refused
      until the go-live guard (R94) passes with a real Qloo price: an admin enters Qloo's cost per call, and every
      paid plan keeps a 60% margin with every cap used (`app/services/billing/margins.rb`).
- [ ] The Devpost testing instructions say billing is in test mode for judges. That line holds only if production
      has the Dodo keys in test mode (step 1). Set them, or cut the line from `docs/devpost.md` before submitting.
- [ ] Keep the site up through judging: check `/admin` and the project in Coolify once a day. Last year's winning demo
      is dead now; ours must stay up.

## 6. Submission polish

- [ ] Screenshots are placeholders until the deploy: the five rows of the Screenshots table in `README.md` (landing
      page, a report filling in live, sponsor matches, pitch pack, public media kit). Take them on the live site,
      save them in `docs/screenshots/`, replace the rows, and upload the same images to the Devpost gallery, which
      `docs/devpost.md` points judges to.
- [ ] Open the README on GitHub once and check that the Mermaid diagram under "How it works" draws.
- [ ] Then work through [judging.md](judging.md), the submission checklist. Submissions close Fri Oct 30, 11:45 PM
      EDT.

## Later

- [ ] R40: before switching `LLM_AGENT_MODEL` or the provider, add 8 to 10 real shows to `config/eval_shows.yml` and
      run `bin/rails eval:run` with live keys.
- [ ] After the hackathon, deploy.md's "Taking it down" lists everything to remove, on the server and outside it.
