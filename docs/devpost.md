# Midrolo: Devpost submission

Paste each section into its Devpost field.

**Name:** Midrolo

**Tagline:** Where independent podcasts get sponsored.

**Built with:** Qloo, OpenRouter, RubyLLM, Ruby on Rails, PostgreSQL, Hotwire, Tailwind CSS, Solid Queue, Python,
Open Podcast connectors, Podcast Index, MapLibre, Dodo Payments, Resend, Cloudflare, Docker

---

## Inspiration

Sponsorship should be the easy part for a small podcast. It isn't, on either side.

**Podcasters can't get found.** Only 39% of podcasters make money from their show, and 48% of the rest say their
audience is too small (RSS.com podcaster survey). Ad networks start far above them: Libsyn Ads reportedly wants about
20,000 downloads an episode. The marketplace built for them is closing: **Audacy Creator Lab (formerly Podcorn)
closes on November 1, 2026**, which Audacy called "a very small part of our overall podcasting business". Even while
it ran, open calls rarely worked: two podcasters on r/podcasting reported one deal from almost 50 proposals, and two
from 115.

**Brands can't buy small shows.** When Ahrefs spent $51,975 on podcast sponsorships, "most shows didn't publish
rates." Acast says a deal takes four to six weeks from proposal to launch, and that "a $2,000 budget spread across 12
shows usually isn't bookable." And the numbers can't be checked: when The Podcast Host compared real downloads with
Rephonic's estimates on 14 shows, they averaged 51.6% accuracy.

So brands guess, podcasters wait, and the shows with the most loyal audiences go unsponsored. What's missing on both
sides is the same thing: evidence of fit, numbers you can trust, and a way to ask.

## What it does

Midrolo is where independent podcasts get sponsored: a public directory of podcasts, a free listing for every
podcaster, and an AI agent on each side that uses Qloo's taste graph to match brands and shows.

**Every show has a page,** built from its own RSS feed: episodes, the people it names, and its **sponsor history
with evidence**. Midrolo reads each episode's notes for sponsor reads, promo codes and offers, and every brand it
finds links to the episode and quotes the show's own sentence. Brand pages turn that around: "Podcasts Notion
sponsors". Search for a show we don't have and it's added from the directory while you watch.

**For brands: "Find podcasts your customers love."** Name your brand and the brand side agent runs seven steps you
watch live:

1. finds the brand on Qloo, with its competitors and the brands its customers also buy;
2. asks Qloo which podcasts people with that taste love;
3. scores the shows in your categories against the same taste;
4. checks sponsor history: which of those shows your competitors already sponsor;
5. checks each show's rate card against your budget, and how its numbers are verified;
6. ranks them out of 100 (taste 50, proof 25, price 15, trust 10), each with why it fits;
7. writes a three line brief.

Then save the shows you like and **request a spot**: a message thread with the show, no commission.

**For podcasters: "Get your show sponsored."** Find your show and claim it, free:

- **Claim** through your RSS feed: instantly when its owner email is your Google address, by email code, or with a
  one line token in your show description (the route for Spotify hosted shows, whose feeds list no email).
- **List** your show: open to sponsors, a rate card suggested from your numbers, the months you're open, who you want
  and what you won't advertise.
- **Verify your numbers with "Invite Midrolo".** No passwords and no screenshots. You add Midrolo's stats account to
  your show, in Spotify for Creators with Analytics access only, or in Apple Podcasts Connect with the read only Analyst
  role. Midrolo reads the numbers with its own account, every day, and your page shows them as "Verified with Spotify
  for Creators" with the date. Streams, listeners, followers and the listeners' age, gender and countries. Numbers
  older than 45 days stop saying verified.
- **Answer requests** in one inbox: accept, decline with a reason, block or report. Brands never see your contact
  details, and nobody hears about a request until the show is claimed.

The podcaster's **sponsor research agent** is still here as the paid toolkit: it builds the audience's taste profile
with Qloo, ranks up to 50 brands that fit, writes the pitch, and now adds **shows with a similar audience** and
**brands that already sponsor shows like yours**.

### Why it needs Qloo, on both sides

Take Qloo away and neither agent can answer its question. Sponsor history says who has paid shows before; verified
numbers say how big a show is. Only taste says who should fit, and Qloo is how both sides get it:

- **Brands to shows.** Qloo's podcast recommendations, with the brand as the signal, are the brand agent's first
  list. Its taste scores rank the rest of the catalog against the same taste. Qloo's brand data names the
  competitors whose sponsorships become proof.
- **Shows to brands.** Qloo's brand recommendations and taste scores, from the show's own entity or comparable
  shows and topics, rank every brand in a podcaster's report. Every brand in a report comes from a Qloo result in
  that run.
- **Shows to shows.** Qloo's similar podcasts give each report "shows with a similar audience", and the brands that
  sponsor those shows become proof for the podcaster.
- **The catalog itself.** Midrolo's directory was seeded from Qloo's podcast lists by genre, each matched to its
  real feed.

The part that isn't obvious is the join. Qloo says who should fit; the feeds prove who already pays shows like this; the
verified numbers say what it's worth. Every Qloo call, and why, is in `docs/how-we-use-qloo.md` in the repo.

### Built during the submission period

The first commit is October 24, 2026. The sponsor research agent, reports, pitches and media kits came first. Then,
in the last two days, the marketplace: the catalog and its feed reader, sponsor detection, the public pages, claiming
and listings, verified Spotify and Apple numbers, the brand agent, request a spot and the inbox.

## How we built it

- **Two agents.** The podcaster's sponsor research agent is a RubyLLM tool loop (any tool calling model through
  OpenRouter) with eight coarse tools, capped at 40 tool calls and 6 minutes. The brand side agent is seven fixed
  steps in Ruby with one call to a cheap model for the brief, so a search costs at most 10 Qloo calls. Both write
  every step to a live trace the user watches.
- **The Qloo client.** One adapter behind a `Taste::Provider` interface, a tolerant mapper for every answer shape we
  met, a shared cache (7 days, 30 for lookups), and a call guard in front of every live request: per minute and daily
  caps, a soft and a hard cap per run, and a capped share for free and trial users.
- **The catalog.** A feed reader with conditional GET, adaptive polling (claimed shows hourly, quiet shows weekly),
  leases with `FOR UPDATE SKIP LOCKED`, per host pacing, and an SSRF guard on every fetch. Artwork is stored once
  per image hash.
- **Sponsor detection.** Patterns first (lead ins, sponsor blocks, promo codes, vanity links), then a cheap model
  confirms candidates. Nothing the model says is trusted: a brand counts only if its name or domain is in the notes,
  and the evidence is always the show's own sentence.
- **Verified stats.** A small Python helper runs Open Podcast's MIT licensed Spotify and Apple connectors, pinned with
  hashes. Rails hands it Midrolo's own session on stdin only, never in arguments, logs or job data. A reading counts
  only when the podcast is claimed by the person who invited Midrolo and the platform's show matches it.
- **Trust labels.** Every number carries a badge with its source and date: from the feed, provided by the show, or
  verified. Spotify and Apple plays per episode are labelled plays, never downloads.
- **Safety.** No contact details on any page, no email to unclaimed shows, daily request limits until a brand
  verifies a work email at its own domain, block and report on every thread, and "Remove this page" everywhere.
- **Everything swappable.** Qloo, Podcast Index, the LLM and billing each sit behind an interface with a Fake twin.
  With no keys the app runs end to end in demo mode, and the tests never touch a live API.
- **The stack.** Rails 8.1, PostgreSQL, Hotwire, Solid Queue, Google sign in, Dodo billing with signed webhooks, an
  admin page, and Cloudflare in front of our own server.

## Challenges we ran into

- **Verified numbers without passwords.** Asking podcasters for their Spotify cookies was never an option. The
  answer was to let them invite Midrolo like a teammate, with the narrowest role each platform offers, and to check
  ownership twice so one show can't borrow another's numbers.
- **Spotify counts a day only after it ends.** Any range ending today answered 500. The helper ends every window
  yesterday and keeps the window's length.
- **Finding sponsors without inventing them.** Show notes are full of patrons, merch, the host's own course and
  "advertise with us". The scan keeps precision first: a wrong sponsor is worse than a missed one.
- **A small call allowance.** A full report makes about 20 to 30 Qloo calls and a brand search up to 10. A shared
  cache, call caps per run and per day, and a lane for trial users keep everyone inside the key's allowance.
- **Small shows aren't on Qloo.** When a show isn't in the graph, the podcaster's agent builds a **proxy** profile
  from comparable shows and topics, and says so. When a brand isn't, its categories become the signal.
- **Keeping an LLM honest.** The save tools reject any brand or number the run didn't produce.

## Accomplishments that we're proud of

- A complete two sided product, not a demo: public pages, claiming, listings, verified numbers, two agents, requests
  and an inbox, billing and admin.
- Verified Spotify and Apple numbers that never ask a podcaster for a password.
- Sponsor history with a quote and an episode behind every brand.
- Honest by default: modeled taste is labelled modeled, every number names its source and date, and plays are never
  called downloads.
- Free for podcasters, for good. No commission on either side.
- Anyone can clone the repo and run the whole flow with no keys.

## What we learned

- **Taste is the missing signal.** Brands and podcasters already have downloads and categories. What neither had was
  who the listeners are as people, and that's what makes a match feel obvious once you see it.
- **Compare isn't for brand and podcast.** In our live probe, compare found no shared tags between a podcast and its
  top brand. So reasons come from the taste tags both entities already carry, at no extra call.
- **Search is fuzzy.** A nonsense query still returns the nearest entity, so we match names ourselves: exact name,
  then the brand's website, then a close name.
- **Verified beats estimated.** A number with a source and a date does more for trust than a bigger number without
  one.

## What's next

- **A commercial Qloo agreement,** then billing opens. Podcasters list free forever. The paid toolkit is plan based
  (Creator at $19 a month, Pro at $49, a one time $49 Sprint), brands get a plan later, and there's no commission.
- **Profitable from day 1.** Billing runs as a founding member waitlist until an admin enters Qloo's cost per call and
  every paid plan keeps at least a 60% margin with every cap used.
- **Deals:** agreed terms, an air window, and proof that the read aired, spotted in the feed.
- **More verified sources:** hosting providers' own analytics, and YouTube.
- **A guide for Creator Lab podcasters** whose feeds may still carry its analytics prefix.

## Testing instructions

- **Live site:** https://midrolo.com
- **No sign in needed:** browse the directory at https://midrolo.com/podcasts, open any show's page (episodes,
  sponsor history with evidence, details), a brand page from a show's sponsors, and the sample reports at
  https://midrolo.com/samples. Search for a show that isn't listed and watch it get added.
- **Sign in** with any Google account. We never post to it.
- **Try the brand side:** press "Find podcasts your customers love", name a real brand and its website, and watch the
  agent's seven steps. Open the results, save a show, and request a spot. To send a request without bothering a real
  show, use the **Midrolo Demo Show**: a fictional listing we run, linked from the home page and labelled Demo
  everywhere.
- **Try the podcaster side:** add any show (it doesn't have to be yours) and run a Snapshot and a full report: watch
  the agent work, then see the similar shows and the brands that already sponsor them. Write a pitch. The listing
  editor and the stats screen work as a draft until you claim a show you own.
- **Verified numbers:** search for **AiGM by AiHunt**, a small show of ours that invited Midrolo on Spotify. Its page
  shows its Spotify numbers with the Verified badge and the date.
- **Free trial, no code or card:** every new account gets Pro features through Nov 6: up to 3 shows, each with a
  Snapshot and a full agent report, plus 60 pitches. Brands get 5 searches a day (20 after verifying a work email).
- **Sample media kit:** open any sample report and press See the sample media kit.
- **Billing** shows the founding member waitlist. Nothing can be bought during judging.

## Known limitations

- **Modeled, not measured.** A taste profile describes people whose tastes match a show's, not its real listeners.
  Verified numbers are the measured part, and only for shows that invite Midrolo.
- **Proxy profiles** for shows Qloo doesn't know are only as good as their seeds. The report names every seed.
- **Sponsor history comes from show notes,** so a read nobody wrote down is missed, and a mention that wasn't paid can
  slip in. Each one shows its evidence so you can judge.
- **Apple Podcasts verification** uses the same invite and connector as Spotify, but we have only checked Spotify
  live.
- **Data gaps** in the hackathon data: some brands and shows aren't on Qloo, and some seeds return few results.
- **What a result does not establish:** that a brand will say yes or what it will pay, that any listener buys from a
  brand, or a show's real age or gender mix. A fit score ranks results within one search or report; it is not a
  forecast.

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
| Technical implementation | Two agents on Qloo, a catalog seeded from Qloo, sponsor detection, verified stats through official accounts, a test suite |
| Design | Public pages, both sides' flows, live agent traces, trust badges on every number |
| Potential impact | Small shows lost their marketplace on November 1; brands can't find or trust them. Free listing, verified numbers and taste matching fix both |
| Quality of idea | Taste from Qloo, joined with sponsor proof from feeds and numbers verified at the source |
| Provenance and user clarity | Agent traces, sources and dates on every number, evidence quotes, "Taste data from Qloo" labels |
| Responsible data handling | No Qloo data in the repo, a private cache, no passwords, no contact details on pages, encrypted owner emails and sessions |
| Reproducibility | Demo mode with no keys, synthetic fixtures, a live smoke test with a fixed call budget |
