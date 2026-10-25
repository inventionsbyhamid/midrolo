# Live pitch: Nov 5

For the finalists' live show. Three parts: the pitch (3 minutes, about 400 spoken words), the demo, and answers to
the questions we expect. Say only what's true today: no customers yet, no measured listener data.

## The 3 minute pitch

**0:00. The hook.**
"Most podcasts will never land a sponsor. Not because nobody listens. Because they can't prove *who* listens."

**0:15. The problem.**
"An independent host has downloads and a country chart. Nothing about taste. So they guess which brands to pitch,
send the same media kit to everyone, and get told they're not big enough. One host put it this way: 'We'll spend
months reaching out, then maybe get one sponsor for one episode.'
The tools that help start around $99 a month and are built for big shows. And Podcorn, a marketplace for small
shows, shuts down on November 1."

**0:45. What Midrolo does.**
"Midrolo is a sponsor research agent for one show. You type your show's name. The agent asks Qloo's taste graph what
people with your show's taste love more than most: brands, podcasts, places. It ranks the brands that fit, and it
reads the feeds of similar shows to find brands *already sponsoring* shows like yours. Then it writes the pitch and
builds a media kit with the evidence."

**1:10. The demo** (about 60 seconds, script below).

**2:10. Why it needs Qloo.**
"Take Qloo away and there's nothing left. An LLM alone can only guess that tech listeners like gadgets. Every brand
in a Midrolo report comes from a Qloo result in that run, and the server refuses to save one that didn't. The AI
plans the research and explains it. Qloo is the evidence."

**2:30. The business.**
"Subscriptions, no commission. Free gets a Snapshot. Creator is $19 a month, Pro is $49. Our rate card never prices a
midroll under $25, so one sponsor spot covers a month. Billing is built, and it's held on a founding member waitlist
until we agree commercial terms with Qloo. The code won't take a live payment until every plan keeps at least a 60%
margin at full use. Profitable from day 1, by design."

**2:50. The close.**
"Small shows have always had the audience. Now they have the evidence. Midrolo: find sponsors who already love your
listeners."

## Demo script

Have this open in tabs before going live, signed in as a demo account (never a personal email on screen):

1. The landing page.
2. A finished full report for a well known show (a sample report works).
3. A report run started a minute earlier, so the trace is filling in.
4. A pitch already written for the top match.
5. The media kit preview.

| Time | Show | Say |
| --- | --- | --- |
| 0:00 | The running report's trace | "This is the agent working. Each step says what it asked Qloo and what came back." |
| 0:10 | The finished report, At a glance | "Three lines on who this audience is and who to pitch first." |
| 0:20 | Leans and the map | "Age and gender as leans, never percentages, because it's modeled, not measured. And where this taste lives." |
| 0:30 | The match list, a proven sponsor | "Ranked brands, each with a reach tier. This one already sponsors a show like this one, found in that show's own feed." |
| 0:40 | Write my pitch | "One click: the email, three ad read angles, an offer priced from the rate card, and a follow up." |
| 0:50 | The media kit preview | "And a media kit the host can send, published only once they prove they own the show." |
| 1:00 | "How we built this" | "Every report shows its own working: the seeds, where each came from, and every step." |

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

- SponsorUnited is enterprise only. Rephonic starts at $99 a month, and Podchaser's sponsor data comes with its $300
  a month tier.
- Marketplaces for small shows keep closing: Podcorn shuts down Nov 1, and Station, an AI sponsor matcher, has paused.
- A ChatGPT media kit is easy to copy. What isn't: Qloo taste data as evidence, plus which brands already sponsor
  similar shows. That's our edge, at a price a small show can pay.

### More questions we might get

- **Why not just ask ChatGPT?** It can only guess. It has no taste graph and can't tell you who sponsors similar shows
  this month.
- **What does a report cost you?** About $0.50 of LLM per full report (our estimate, logged per run) plus up to about
  30 Qloo calls. A Snapshot has no LLM cost.
- **What about listener privacy?** We never see a listener. Qloo describes people with a show's taste as a group, and
  we never present it as data about any one person.
- **How big is the market?** Our estimate is 20,000 to 30,000 shows with 1,000 to 50,000 downloads per episode, about
  half in the US, plus many smaller shows that want their first sponsor.
- **What surprised you about Qloo's API?** Compare across a podcast and a brand shares no tags, so we explain matches
  from the tags a brand shares with the audience instead. And the heatmap answers thousands of cells whatever you ask
  for, so we keep the top 200.
