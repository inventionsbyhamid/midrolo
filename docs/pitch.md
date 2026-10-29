# Live pitch: Nov 5

For the finalists' live show. Three parts: the pitch, the demo, and answers to the questions we expect. Say only
what's true today: no customers yet, and no measured outcomes.

## The 3 minute pitch

About 280 spoken words plus a 60 second demo. At about 150 words a minute it ends near 2:55. The times below are
where each part starts.

**0:00. The hook** (18 words, about 7 seconds).
"On November 1, the marketplace built for small podcasts shut down. Its podcasters need somewhere to go."

**0:08. The problem** (72 words, about 29 seconds).
"Audacy Creator Lab, the old Podcorn, closed. And it wasn't working anyway: one host sent almost fifty proposals for
one deal. Brands have it worse. Most small shows don't publish rates, a booking takes weeks, and the numbers can't
be checked: one test found download estimates were right about half the time. So brands guess, podcasters wait, and
the shows with the most loyal audiences go unsponsored."

**0:37. What Midrolo does** (64 words, about 26 seconds).
"Midrolo is where independent podcasts get sponsored. Every show has a page built from its own feed, with the sponsors
it has really run. Podcasters claim it free, set their rates, and verify their Spotify and Apple numbers by inviting
Midrolo, with no passwords. Brands type their name, and an agent finds the shows their customers love. Then they
request a spot."

**1:03. The demo** (60 seconds, script below).

**2:03. Why it needs Qloo** (52 words, about 21 seconds).
"Sponsor history says who paid shows before. Verified numbers say how big a show is. Only taste says who should fit,
and that's Qloo. It's on both sides: Qloo ranks podcasts for a brand's customers, and brands for a show's listeners.
Take Qloo away and neither agent has a match to show."

**2:24. The business** (49 words, about 20 seconds).
"Listing is free for podcasters, forever. No commission on either side. Podcasters pay for the AI toolkit, $19 or $49
a month, and brands get a plan next. Billing waits for a commercial deal with Qloo, and the code refuses any plan
under a 60% margin."

**2:44. The close** (16 words, about 7 seconds).
"Small shows have always had the audience. Now brands can see it, and trust it. Midrolo."

## Demo script

About 120 spoken words with clicks in between, ending near 0:56 of the demo's minute. Have this open in tabs before
going live, signed in as a demo account (never a personal email on screen):

1. The landing page.
2. A brand search started a minute earlier, so the trace is filling in.
3. A finished brand search's results.
4. A rich podcast page with sponsor history and the Verified badge (AiGM by AiHunt, or a seeded show with sponsors).
5. A finished podcaster report, scrolled to similar shows.

| Time | Show | Say |
| --- | --- | --- |
| 0:00 | The landing page | "Two sides. Brands find podcasts their customers love. Podcasters list free." |
| 0:06 | The running brand search | "A brand types its name. The agent asks Qloo which podcasts its customers love, then checks who its competitors already sponsor." |
| 0:17 | The results, one card | "Ranked out of 100, with why: shared taste, proof from real sponsor reads, price against the budget, and how the numbers are verified." |
| 0:28 | Request a spot | "One click to ask the show. No commission." |
| 0:33 | The podcast page, sponsors | "Every sponsor we list links to the episode and quotes the show's own notes." |
| 0:41 | The Verified badge | "These are Spotify numbers Midrolo read itself, after the show invited it. The source and the date, on every number." |
| 0:50 | The podcaster report, similar shows | "And for podcasters, the same taste works backwards: shows like yours, and the brands that sponsor them." |

**If something breaks:** the directory and the sample reports need no sign in and no live calls. Go to a rich
podcast page, then a sample report.

**Before the show:** check /admin for today's Qloo calls against the daily cap, that runs aren't paused, that the
Spotify session works, and that the LLM budgets have room.

## Q&A

### Business model: how do you make money?

- Listing, claiming, verifying and answering brands are free for podcasters, for good. No commission on either side.
- Podcasters pay for the AI toolkit: Creator $19 a month ($190 a year), Pro $49 a month ($490 a year), and a one time
  $49 Sprint for 30 days of Pro. Free is a Snapshot a month.
- Brands search free during the trial. A brand plan comes next, for full searches, saved lists and briefs to many
  shows at once.
- Billing is built and covered by tests. Today it's a founding member waitlist: we don't charge until Qloo's
  commercial price is known, and the code refuses live billing until every paid plan keeps at least 60% margin with
  every cap used.
- Hosting is on our own server, so fixed costs are close to zero.

### Qloo dependency: what if Qloo changes terms or turns off your key?

- Qloo is the matching, and we say so. Sponsor history and verified numbers would still work without it, but nobody
  could tell who fits.
- The hackathon key ends after the event. Selling needs a commercial agreement, which is why billing waits for one.
- We're a cheap customer to serve: every answer is cached and shared, a brand search makes at most 10 calls, a report
  at most 40, and page views never call Qloo.
- The Qloo client sits behind an interface, so the code can move to another access method Qloo offers without
  touching the rest of the app.

### Accuracy: how do you know the matches are any good?

- Honestly: we haven't measured outcomes yet. There are no paying users. The first numbers we'd track are request
  reply rate and booked spots.
- What we can show today: taste scores come from Qloo in that run, scoring is plain math with published weights,
  sponsor history quotes the show's own notes, and verified numbers come from Spotify itself.
- We don't overclaim. Taste is modeled, not measured, and labelled so. Plays are never called downloads. A verified
  number older than 45 days stops saying verified.
- A fit score ranks results inside one search. It doesn't promise a yes.

### Competition: who else does this?

- Audacy Creator Lab (formerly Podcorn) closed on November 1, 2026. Station, an AI sponsor matcher, has paused.
- Podchaser and Rephonic sell data, and their download numbers are estimates. Rephonic's were about half right in
  one test. Podchaser puts sponsor history behind its $300 a month tier; ours is free and public.
- Ad networks and curated marketplaces start around 5,000 to 20,000 downloads an episode. Midrolo is for the shows
  below that.
- What's hard to copy: Qloo taste on both sides, joined with sponsor proof from feeds and numbers verified at the
  source.

### More questions we might get

- **How do verified numbers work without a password?** The podcaster invites Midrolo's stats account to their show in
  Spotify for Creators, with Analytics access only, or in Apple Podcasts Connect as an Analyst. We read the numbers
  with our own account, and only count them if the inviter owns the show.
- **Isn't building pages for shows that didn't ask a problem?** Each page shows only what the show's own feed
  publishes, never contact details. Any page can be removed, and unclaimed shows are never emailed: a brand's request
  waits until the show claims its page.
- **How do you stop brands spamming podcasters?** Daily request limits until a brand verifies a work email at its own
  domain, block and report on every thread, and no brand text copied into our emails.
- **What does it cost you to run?** About $0.50 of LLM per full podcaster report (our estimate, logged per run), a
  fraction of a cent for a brand search's brief (our estimate), and about $5 to $10 to scan a thousand shows for
  sponsors.
- **What about listener privacy?** We never see a listener. Qloo describes people with a show's taste as a group, and
  Spotify's age, gender and country breakdowns are shares, never people.
- **What surprised you about Qloo's API?** In our live probe, a podcast and its own top brand shared no compare tags,
  so we explain matches from the tags both entities already carry. And search is fuzzy, so we match names ourselves.
