# Before you submit: checklist

Submissions close **Fri Oct 30, 11:45 PM EDT** (Sat Oct 31, 09:15 IST). Aim to submit by Fri Oct 30, 11 PM IST.
Judging runs Nov 2 to 5, and judges must be able to use the site free and without restriction until it ends.

Work top to bottom. Deploy steps themselves are in [deploy.md](deploy.md).

## 1. The live site

- [ ] https://midrolo.com is up, and every check in deploy.md's "After every deploy" passes.
- [ ] The demo mode banner shows on no page (production has real keys).
- [ ] `/admin`: runs are not paused, and today's Qloo calls and LLM spend have room.

## 2. Production settings

- [ ] `JUDGE_CODE` is set in the server's `.env`. Redeem it once on a throwaway account to prove it works.
- [ ] `PROMO_PRO_UNTIL=2026-11-06` is set, so the promo covers judging.
- [ ] Ask Qloo what daily allowance the hackathon key has. Then set `qloo_daily_call_limit` in `/admin` within it.
      One judge's three full reports can use up to about 90 calls, and the default cap is 100 a day. How high to go
      is your call.
- [ ] The LLM budgets have room: `LLM_DAILY_BUDGET_USD`, `PROMO_BUDGET_USD` and `JUDGE_RESERVE_USD` (5, 10 and 5 at
      launch; editable in `/admin`).
- [ ] The Google OAuth consent screen is published, so any Google account can sign in, not only test users.
- [ ] `BILLING_MODE` is unset or `waitlist`.
- [ ] Dodo is set up in test mode (`DODO_API_KEY`, `DODO_ENVIRONMENT=test_mode`, the webhook secret and the five
      product ids), so a judge sees "Try checkout in test mode" on the pricing page. If it isn't, delete the billing
      line from the Devpost testing instructions.

## 3. Sample reports

- [ ] `config/samples.yml` names real shows by their Podcast Index ids (not the `fake-` ids).
- [ ] `bin/rails samples:generate` ran in production (this spends Qloo and LLM calls: about $0.50 of LLM each).
- [ ] https://midrolo.com/samples lists them, and each page says "Sample report. Not affiliated with the show."
- [ ] Read each sample top to bottom: no odd brands, no "your" addressed to a stranger, nothing that reads as a claim
      about a real listener.

## 4. The repo

- [ ] The GitHub repo is public.
- [ ] GitHub detects AGPL-3.0 and shows it in the About section.
- [ ] The About section links https://midrolo.com.
- [ ] The README renders, Mermaid diagram included.
- [ ] No secrets: `git ls-files | grep -E '(^|/)\.env'` prints only `.env.example`, and no key or `JUDGE_CODE` value
      appears in `git log -p`.
- [ ] No Qloo data: `git ls-files spec/fixtures/private` prints nothing.
- [ ] `docs/devpost.md` still says `<<JUDGE_CODE>>`, not the real code.

## 5. Screenshots

- [ ] Take them on the live site with a demo account: the landing page, a report filling in, the match list, a pitch
      pack and a public media kit.
- [ ] Nothing personal or secret in any of them: no real email in the header, no `/admin`, no keys, no browser
      bookmarks bar.
- [ ] Save them in `docs/screenshots/` and replace the README's placeholder rows.
- [ ] Upload the same images to the Devpost image gallery.

## 6. The Devpost form

- [ ] Paste each section from [devpost.md](devpost.md) into its field.
- [ ] Replace `<<JUDGE_CODE>>` with the real code in Devpost's testing instructions only.
- [ ] Links: the live site and the public repo.
- [ ] Built with: copy the list from devpost.md.
- [ ] Read every field once more for em or en dashes. The spec guards the files in the repo, not what's pasted.
- [ ] A video is optional. Skip it unless there's time.

## 7. The judge's walk, in a private window

- [ ] Open a sample report without signing in.
- [ ] Sign in with Google, open Account and redeem the judge code.
- [ ] Add a show, run a full report and watch the trace fill in.
- [ ] Write a pitch for a match.
- [ ] Edit and preview the media kit.
- [ ] Open Pricing: the waitlist buttons show, and "Try checkout in test mode" if Dodo is set up.
- [ ] Afterwards, check `/admin` for errors and the calls that walk used.

## 8. During judging (Nov 2 to 5)

- [ ] Keep the site up. Check `/admin` and `docker compose ps` once a day.
- [ ] Watch the Qloo calls against the daily cap. If judges run short, raise it only within the key's allowance.
- [ ] Backups stay healthy (deploy.md, Backups).
- [ ] If we're a finalist: rehearse [pitch.md](pitch.md), and be free for prep and the live show on Nov 5.
