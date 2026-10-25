# Live pitch: Nov 5

For the finalists' live show. Three parts: the pitch, the demo, and answers to the questions we expect. Say only
what's true today: no customers yet, no measured listener data.

## The 3 minute pitch

About 270 spoken words plus a 60 second demo. At about 150 words a minute it ends near 2:50, leaving a few seconds
of slack. The times below are where each part starts.

**0:00. The hook** (17 words, about 7 seconds).
"Most podcasts will never land a sponsor. Not because nobody listens. Because they can't prove *who* listens."

**0:07. The problem** (69 words, about 28 seconds).
"An independent host has downloads and a country chart. Nothing about taste. So they guess which brands to pitch, and
get told they're not big enough. One host put it this way: 'We'll spend months reaching out, sending media kits and
then maybe get one sponsor for one episode.' The tools that help start around $99 a month. And Podcorn, a marketplace
for small shows, closed on November 1."

**0:35. What Midrolo does** (62 words, about 25 seconds).
"Midrolo is a sponsor research agent for one show. You type your show's name. The agent asks Qloo's taste graph what
people with your show's taste love more than most: brands, podcasts, places. It ranks the brands that fit, and reads
similar shows' feeds to find brands *already sponsoring* shows like yours. Then it writes the pitch and builds a media
kit."

**1:00. The demo** (60 seconds, script below).

**2:00. Why it needs Qloo** (50 words, about 20 seconds).
"Take Qloo away and there's nothing left. An LLM alone can only guess that tech listeners like gadgets. Every brand in
a Midrolo report comes from a Qloo result in that run, and the server refuses to save one that didn't. The AI plans
and explains. Qloo is the evidence."

**2:20. The business** (53 words, about 21 seconds).
"Subscriptions, no commission: Creator at $19 a month, Pro at $49. One $25 midroll covers a month of Creator. Billing
waits on a founding member waitlist until we agree terms with Qloo, and the code refuses live payments until every
plan keeps at least 60% margin at full use. Profitable from day 1."

**2:41. The close** (20 words, about 8 seconds).
"Small shows have always had the audience. Now they have the evidence. Midrolo: find sponsors who already love your
listeners."

## Demo script

About 120 spoken words with clicks in between, ending near 0:56 of the demo's minute. Have this open in tabs before
going live, signed in as a demo account (never a personal email on screen):

1. The landing page.
2. A finished full report for a well known show (a sample report works).
3. A report run started a minute earlier, so the trace is filling in.
4. A pitch already written for the top match.
5. The media kit preview.

| Time | Show | Say |
| --- | --- | --- |
| 0:00 | The running report's trace | "This is the agent working. Each step says what it asked Qloo and what came back." |
| 0:08 | The finished report, At a glance | "Three lines on who this audience is and who to pitch first." |
| 0:15 | Leans and the map | "Age and gender as leans, never percentages, because it's modeled, not measured. And where this taste lives." |
| 0:23 | The match list, a proven sponsor | "Ranked brands, each with a reach tier. This one already sponsors a show like this one, found in that show's own feed." |
| 0:32 | Write my pitch | "One click: the email, three ad read angles, an offer priced from the rate card, and a follow up." |
| 0:41 | The media kit preview | "And a media kit the host can send, published only once they prove they own the show." |
| 0:50 | "How we built this" | "Every report shows its own working: the seeds, where each came from, and every step." |

**If something breaks:** the sample reports at /samples need no sign in and no live calls. Go straight to tab 2.

**Before the show:** check /admin for today's Qloo calls against the daily cap, that runs aren't paused, and that the
LLM budget has room.

## Q&A

### Business model: how do you make money?

- Monthly or yearly subscriptions, no commission: Creator $19 a month ($190 a year), Pro $49 a month ($490 a year),
  and a one time $49 Sprint for 30 days of Pro. Free is a Snapshot a month.
- Billing is built and covered by tests, with a test mode checkout. Today it's a founding member waitlist: we don't
  charge until Qloo's commercial price is known.
- The go live check is in code: live billing is refused until Qloo's cost per call is entered and every paid plan keeps
  at least 60% margin with every cap used. The free tier uses no AI, so free users cost no LLM spend.
- Hosting is on our own server, so fixed costs are close to zero.

### Qloo dependency: what if Qloo changes terms or turns off your key?

- Qloo is the core, and we say so. Without it there's no product. That's the point of the build.
- The hackathon key ends after the event. Selling needs a commercial agreement, which is why billing waits for one.
- We're a cheap customer to serve: every answer is cached and shared across users, a report has a soft cap of 30
  uncached calls, and lookups keep for 30 days.
- The Qloo client sits behind an interface, so the code can move to another access method Qloo offers without
  touching the rest of the app.

### Accuracy: how do you know the matches are any good?

- Honestly: we haven't measured outcomes yet. There are no paying users. The first number we'd track is pitch reply
  rate.
- What we can show today: every brand comes from Qloo data in that run, scoring is plain math with published weights,
  and proven sponsors are real reads found in real feeds, confirmed on Qloo.
- We don't overclaim. The audience is modeled, not measured. Leans are words, not percentages. A report says when a
  profile is a proxy built from comparable shows, and lists every seed.
- A fit score ranks brands for one show. It doesn't promise a yes.

### Competition: who else does this?

- Rephonic starts at $99 a month and is aimed at PR and guest booking. Podchaser's sponsor data comes with its $300
  a month tier.
- Marketplaces for small shows keep closing: Podcorn closed on November 1, 2026, and Station, an AI sponsor matcher,
  has paused.
- A ChatGPT media kit is easy to copy. What isn't: Qloo taste data as evidence, plus which brands already sponsor
  similar shows. That's our edge, at a price a small show can pay.

### More questions we might get

- **Why not just ask ChatGPT?** It can only guess. It has no taste graph and can't tell you who sponsors similar shows
  this month.
- **What does a report cost you?** About $0.50 of LLM per full report (our estimate, logged per run) plus about 20 to
  30 Qloo calls, never more than 40. A Snapshot has no LLM cost.
- **What about listener privacy?** We never see a listener. Qloo describes people with a show's taste as a group, and
  we never present it as data about any one person.
- **How big is the market?** Our estimate is 20,000 to 30,000 shows with 1,000 to 50,000 downloads per episode, about
  half in the US, plus many smaller shows that want their first sponsor.
- **What surprised you about Qloo's API?** In our live probe, a podcast and its own top brand shared no compare tags,
  so compare is off by default and we explain matches from the tags a brand shares with the audience instead. And
  the heatmap answers thousands of cells whatever you ask for, so we keep the top 200.
