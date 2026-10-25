# Midrolo: Devpost submission

Paste each section into its Devpost field. Replace `<<JUDGE_CODE>>` with the real code before submitting, and never
commit the real code to this file.

**Name:** Midrolo

**Tagline:** Find sponsors who already love your listeners.

**Built with:** Qloo, Claude, RubyLLM, Ruby on Rails, PostgreSQL, Hotwire, Tailwind CSS, Solid Queue, MapLibre,
Podcast Index, Dodo Payments, Resend, Cloudflare R2, Docker

---

## Inspiration

Independent podcasters want sponsors, but they can't show a brand who listens. Hosting stats give downloads and
countries, nothing about taste. So hosts guess which brands to pitch and send the same media kit to all of them.

In their own words, on r/podcasting:

- "I get not so subtle hints that I'm not really big enough."
- "We'll spend months reaching out, sending media kits and then maybe get one sponsor for one episode."
- "Sponsorship pricing seems like a mysterious formula."

The tools that help are built for big shows and start around $99 a month. The marketplaces built for small shows keep
closing: Podcorn closed on November 1, 2026.

What small shows lack is evidence of fit. Qloo has it.

## What it does

Midrolo is a sponsor research agent for one show.

1. **Add your show.** Search by name, or paste an RSS or Apple Podcasts link.
2. **The agent researches it,** live on screen. Each step shows what it asked and what came back.
3. **You get a report:**
   - what people with your show's taste love more than most: brands, podcasts and taste tags;
   - age and gender leans, modeled from Qloo taste data;
   - a map of where that taste is strongest;
   - up to 50 brands ranked by fit, each with a reach tier (easy yes, realistic, long shot) and a one line reason;
   - **proven sponsors**: brands already sponsoring similar shows, found in those shows' own feeds.
4. **Write the pitch.** One click gives an email, three ad read angles, an offer priced from your rate card and a
   follow up. Copy it or open it in Gmail. Midrolo never emails brands for you.
5. **Publish a media kit.** A public page with your taste profile, leans, map and rate card, once you prove you own
   the show.
6. **Track it.** A pipeline from saved to pitched, replied, won or lost.

A free **Snapshot** uses Qloo only, with no AI: taste tags, the map and your top 5 brand matches.

### Why it needs Qloo

Take Qloo away and there is no report. Qloo supplies every brand, taste tag, lean and place. The agent decides what to
ask and explains the answers, and the server rejects any brand that didn't come from a Qloo result in that run.

We make six kinds of Qloo call across three endpoints: `/search`, `/v2/tags`, and four uses of `/v2/insights`: brand
and podcast recommendations, taste tags (`urn:tag`), demographics (`urn:demographics`) and the heatmap
(`urn:heatmap`). We also built `/v2/analysis/compare`, then turned it off by default (see What we learned). Every
call, and why, is in `docs/how-we-use-qloo.md` in the repo, with a redacted request to result walkthrough of one
report.

## How we built it

- **The agent.** A RubyLLM agent (Claude Opus 5.5 by default, set by config) with eight coarse tools: read the feed,
  find seeds on Qloo, save seeds, build the audience profile, find sponsor candidates, explain matches, save matches,
  save the summary. The research tools do the Qloo, directory and feed calls in Ruby and return short summaries. The agent is capped at 40
  tool calls and 6 minutes.
- **The Qloo client.** One adapter behind a `Taste::Provider` interface, with a tolerant mapper for every answer shape
  we met, a shared cache, and a call guard in front of every live request.
- **The proven sponsor scan.** Plain Ruby, no LLM: read similar shows' recent episodes, match sponsor read phrases,
  and keep only names Qloo confirms as brands.
- **Scoring** is plain Ruby with weights in config: affinity 55, proven sponsor 20, shared taste tags 15, category 10.
  Popularity sets the tier. Same data, same score.
- **Provenance.** The save tools accept only brands the run showed the model, and reasons may cite only numbers in the
  data. Feed text reaches the model marked as untrusted.
- **Everything swappable.** Qloo, Podcast Index, the LLM and billing each sit behind an interface with a Fake twin. With
  no keys the app runs end to end in demo mode, and the tests never touch a live API.
- **The product around it.** Rails 8.1, PostgreSQL, Hotwire, Solid Queue, Google sign in, a media kit editor, owner
  verification, a pipeline, Dodo billing with signed webhooks, and an admin page. It runs on our own server with Docker
  Compose.

## Challenges we ran into

- **Building before the key arrived.** We wrote the Qloo client against synthetic fixtures modeled on the docs, then
  checked every shape with a live smoke test once the key came. The client now reads fields flat or nested, and several
  coordinate spellings.
- **A small call allowance.** A full report makes about 20 to 30 Qloo calls (40 at most), and the key's allowance is
  limited. We added a shared cache, a per minute and daily call guard, a per report cap, and a lane that holds free and
  promo users to 40% of the day, so judges and paying users keep most of each day's calls.
- **Small shows aren't on Qloo.** When a show isn't in the graph, the agent builds a **proxy** profile from comparable
  shows and topics, and the report says so. With too little to go on, it asks the host for comparable shows instead of
  showing an empty page.
- **Keeping an LLM honest.** An agent will happily name a brand it never saw. Server side checks now reject any brand,
  or number, the run didn't produce before it is saved.

## Accomplishments that we're proud of

- A complete product, not a demo: sign in, onboarding, a live report, pitch packs, a verified media kit, a pipeline,
  billing and admin.
- Every brand in a report traces back to a Qloo result in that run, and the report shows its own working.
- Honest by default: modeled data is labeled as modeled, proxy profiles say so, and leans are words, never percentages.
- Profitable by construction: the code refuses live billing until the numbers work (see What's next).
- Anyone can clone the repo and run the whole flow with no keys.

## What we learned

- **One probe turned compare off.** In our live probe, a podcast and its own top brand shared no compare tags: each
  side came back with its own tags and nothing in common. So compare is off by default, and we explain a match by the
  tags a brand shares with the audience's taste tags, which we already have, at no extra call.
- **Use the documented shape.** An undocumented heatmap parameter answered 502. The documented geohash grid works, but
  ignores `take`: 8,421 cells for the United States. We keep the top 200 and name them from a table of 163 metros.
- **Search is fuzzy.** A nonsense query still returns the nearest shows, so we match names ourselves.
- **Coarse tools beat chatty ones.** Bundling Qloo calls inside each tool keeps the agent focused on judgment, and keeps
  both LLM and Qloo costs predictable.

## What's next

- **A commercial Qloo agreement,** then billing opens. The business model is plan based subscriptions with no
  commission: Free (a Snapshot a month), Creator at $19 a month or $190 a year, Pro at $49 a month or $490 a year, and
  a one time $49 Sprint (Pro for 30 days).
- **Profitable from day 1.** Qloo has no public commercial price yet, so billing runs as a founding member waitlist.
  Live billing stays refused until an admin enters Qloo's cost per call and every paid plan keeps at least a 60%
  margin with every cap used. Free Snapshots use no AI, so free users cost no LLM spend.
- **An eval set of real shows** to tune seeds and scoring before any model change.
- **Plans for producers and small networks** with several shows.

## Testing instructions

- **Live site:** https://midrolo.com
- **No sign in needed:** the sample reports at https://midrolo.com/samples. Each is labeled "Sample report. Not
  affiliated with the show."
- **Sign in** with any Google account. We never post to it.
- **Judge code:** open https://midrolo.com/account, enter `<<JUDGE_CODE>>` under Judge code and press Unlock. That
  gives Pro features with 3 full agent reports and unlimited pitches, free.
- **Try the flow:** add a show, run a full report and watch the agent work, open a brand and press Write my pitch, then
  edit and preview the media kit. Publishing a kit needs proof of ownership (a code sent to the owner email in the
  show's RSS feed), so use the preview if the show isn't yours.
- **Billing is in test mode for judges.** Everyone else sees the founding member waitlist. With the judge code entered,
  the pricing page also shows Try checkout in test mode. Use Dodo's test card. Nothing is charged.
- **Without the code,** any signed in account can run a free Snapshot, and until Nov 6 one full report while the
  promo budget lasts.

## Known limitations

- **Modeled, not measured.** A report describes people whose tastes match the show's, not the show's real listeners.
- **Proxy profiles** for shows Qloo doesn't know are only as good as their seeds. The report names every seed.
- **Data gaps** in the hackathon data: some seeds return few brands, and brand websites are mostly missing.
- **Proven sponsors come from feed text,** so a read nobody wrote down is missed.
- **What a result does not establish:** that a brand will say yes or what it will pay, that any listener buys from a
  brand, or the show's real size, age or gender mix. A fit score ranks brands within one report; it is not a forecast.

## For the judges: where each item lives

| Qloo kit submission item | Where |
| --- | --- |
| The problem | Inspiration, above |
| Qloo workflows and endpoints, and why | Why it needs Qloo, above, and `docs/how-we-use-qloo.md` |
| A redacted request to result walkthrough, with entity and tag choices | `docs/how-we-use-qloo.md`, Walkthrough |
| Screenshots with no credentials or personal data | The image gallery |
| Setup from a clean environment | `README.md`, Local setup (no keys needed) |
| Known limitations, and what a result does not establish | Known limitations, above, and `docs/how-we-use-qloo.md` |

| Judging consideration | What to look at |
| --- | --- |
| Usefulness | A sponsor list, pitch and media kit for one show, in one sitting |
| Technical execution | Six kinds of Qloo call across three endpoints, an agent with coarse tools, deterministic scoring, a test suite |
| Provenance and user clarity | The live trace, "How we built this" on every report, seeds with sources, brands checked against the run |
| Responsible data handling | No Qloo data in the repo, a private cache, leans as words, honest labels |
| Reproducibility | Demo mode with no keys, synthetic fixtures, a live smoke test with a fixed call budget |
