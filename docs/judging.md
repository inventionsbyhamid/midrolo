# The judge's walk, and the submission checklist

Submissions close **Fri Oct 30, 11:45 PM EDT** (Sat Oct 31, 03:45 UTC; 09:15 IST). Aim to submit by Fri Oct 30,
11 PM IST (17:30 UTC). Judging runs Nov 2 to 5, and judges must be able to use the site free and without restriction
until it ends.

Work top to bottom. Deploy steps themselves are in [deploy.md](deploy.md); the order from keys to judging is in
[handoff.md](handoff.md).

## 1. The live site

- [ ] https://midrolo.com is up, and every check in deploy.md's "After every deploy" passes.
- [ ] The demo mode banner shows on no page (production has real keys).
- [ ] `/admin`: runs are not paused, and today's Qloo calls and LLM spend have room.
- [ ] The catalog is seeded: the Catalog panel in `/admin` shows the shows linked to Qloo (the paced seed,
      `catalog:seed_paced`, reached its target or is still running), and `/podcasts` lists them with artwork.
- [ ] Sponsor detection has run: the Sponsor detection panel in `/admin` shows reads found, and a few podcast pages
      show sponsors with their quotes.
- [ ] The demo show exists (`bin/rails demo:setup`), its page shows "Demo show", and it isn't in the directory.
- [ ] Our own show, **AiGM by AiHunt**, is claimed, its Spotify connection is Active in `/admin/stat_connections`,
      and its page shows its Spotify numbers with the Verified badge. If it doesn't by submission time, delete the
      "Verified numbers" line from the Devpost testing instructions. No connection there waits for review (Approve
      or Reject each).

## 2. Production settings

- [ ] `PROMO_PRO_UNTIL=2026-11-06` is set, so the trial covers judging. Every account is on it (R151): 3 shows,
      each with a Snapshot and a full report. There is no judge code.
- [ ] `qloo_daily_call_limit` in `/admin` fits judging: a judge's three full reports make about 60 to 90 calls (120
      at most), and each brand search up to 10. Trial users share `qloo_free_share` of the day, so raise the share
      too (0.8 leaves a fifth for samples). Stay within the key's allowance.
- [ ] The LLM budgets have room: `LLM_DAILY_BUDGET_USD`, `PROMO_BUDGET_USD` and `JUDGE_RESERVE_USD`, and
      `llm_catalog_daily_usd` for sponsor detection and the brand briefs (editable in `/admin`).
- [ ] The Spotify service session is saved and working (`/admin/service_sessions`, Test fetch).
- [ ] The Google OAuth consent screen is published, so any Google account can sign in, not only test users.
- [ ] `BILLING_MODE` is unset or `waitlist`.

## 3. Sample reports

- [ ] `bin/rails samples:generate` ran in production, then `bin/rails matching:similar_backfill`, so each sample has
      similar shows.
- [ ] https://midrolo.com/samples lists them, and each page says "Sample report. Not affiliated with the show."
- [ ] Read each sample top to bottom: no odd brands, no "your" addressed to a stranger, nothing that reads as a claim
      about a real listener.

## 4. The judge's walk, in a private window

This is build spec section 9, on production. Note anything that breaks, fix it or cut it, and walk again.

**Signed out**

- [ ] The landing page: both calls to action, the Creator Lab line, the directory cards, the demo show's listing.
- [ ] The directory: search a show that's listed, then one that isn't (it shows "Adding this show", then its card).
- [ ] A rich podcast page: episodes, sponsors with quotes and episode links, people, details, "Feed checked".
- [ ] A category page and a brand page ("Podcasts X sponsors").
- [ ] A sample report, and its sample media kit.

**As a brand** (sign in with a new Google account)

- [ ] "Find podcasts your customers love": onboarding asks for the brand's name and website.
- [ ] Run a fit search for a real brand. The seven steps fill in live, then the results with proof and badges.
- [ ] Save a show, then open Saved.
- [ ] Request a spot on the demo show (claimed: the owner account gets the email) and on an unclaimed show (it waits
      for the claim, and no email goes out).

**As a podcaster** (the same account, or another)

- [ ] Add a show, run a Snapshot and a full report. Similar shows and "Brands that already sponsor shows like yours"
      appear.
- [ ] The claim screens for a show you don't own: the token page and the email choice.
- [ ] The listing editor and the Stats screen, as a draft.
- [ ] As the demo show's owner, open the Inbox, reply to the brand's request, and see it arrive on the brand side.

**Admin**

- [ ] Catalog counts, ingest errors, sponsor detection, stats connections, Qloo calls and LLM spend. Nothing alarming.

## 5. The repo

- [ ] The GitHub repo is public.
- [ ] GitHub detects AGPL-3.0 and shows it in the About section.
- [ ] The About section links https://midrolo.com.
- [ ] The README renders, Mermaid diagram included.
- [ ] No secrets: `git ls-files | grep -E '(^|/)\.env'` prints only `.env.example`, and no key, session or
      `JUDGE_CODE` value appears in `git log -p`.
- [ ] No Qloo data: `git ls-files spec/fixtures/private` prints nothing.

## 6. Screenshots

- [ ] Take them on the live site: the landing page, a podcast page with sponsors and verified numbers, a brand's fit
      search filling in, its results, a podcaster's report with similar shows, and the Stats screen.
- [ ] Nothing personal or secret in any of them: no real email in the header, no `/admin`, no keys, no browser
      bookmarks bar.
- [ ] Save them in `docs/screenshots/` and replace the README's placeholder rows.
- [ ] Upload the same images to the Devpost image gallery.

## 7. The Devpost form

- [ ] Paste each section from [devpost.md](devpost.md) into its field.
- [ ] Links: the live site and the public repo.
- [ ] Built with: copy the list from devpost.md.
- [ ] Read every field once more for em or en dashes. The spec guards the files in the repo, not what's pasted.
- [ ] A video is optional. Skip it unless there's time.

## 8. During judging (Nov 2 to 5)

- [ ] Keep the site up. Check `/admin` and the project in Coolify once a day.
- [ ] Watch the Qloo calls against the daily cap. If judges run short, raise it only within the key's allowance.
- [ ] Watch the Spotify service session: an expired one mails the admin and pauses syncs until it's replaced.
- [ ] Answer requests to the demo show, so a judge who sends one sees a reply.
- [ ] Backups keep running (deploy.md, Backups: the database's Backups tab in Coolify).
- [ ] If we're a finalist: rehearse [pitch.md](pitch.md), and be free for prep and the live show on Nov 5.
