# How we use Qloo

Midrolo asks Qloo one question in several ways: **what do people with this show's taste love, more than most people
do?** The answers become the evidence in a sponsor report. Every brand in a report comes from a Qloo result in that
run.

## The problem

Independent podcasters want sponsors but can't show brands who listens. Hosting stats give downloads and countries,
nothing about taste. So hosts guess which brands to pitch, and most pitches get ignored.

An LLM on its own can only guess too ("tech listeners like gadgets"). Qloo's taste graph gives us what a small show
never had: the brands, podcasts and places that this taste loves more than most, how it leans by age and gender, and
where it lives. Without Qloo, Midrolo has no report to show.

## Endpoints we use, and why

Every call is a GET to `https://hackathon.api.qloo.com` with the key in the `X-Api-Key` header. The client is
`app/services/taste/providers/qloo.rb`; `qloo/mapping.rb` reads the answers into our own value objects.

| Endpoint | What we send | What it's for |
| --- | --- | --- |
| `/search` | `query`, `types`, `take` | Find the show, and the shows a host says their listeners love. Confirm a sponsor name found in a feed is a brand (`types=urn:entity:brand`). |
| `/v2/tags` | `filter.query`, `feature.semantic_search=true`, `filter.tag.types` | Turn topics into taste tags, show categories into media genre tags (`urn:tag:genre:media`), and brand categories into brand tags (`urn:tag:genre:brand`). |
| `/v2/insights`, `filter.type=urn:entity:brand` | seed signals, `filter.popularity.max=0.97`, `filter.tags`, `take` | Brand recommendations: one broad pass, plus one pass per brand category. |
| `/v2/insights`, `filter.type=urn:entity:brand` | seed signals, `filter.results.entities` (50 ids at a time) | Score every candidate brand against the same seeds. Qloo has no batch affinity call, so this is how we get one. |
| `/v2/insights`, `filter.type=urn:entity:podcast` | seed signals | Similar podcasts: shown in the profile, and read by the proven sponsor scan. |
| `/v2/insights`, `filter.type=urn:tag` | seed signals | The audience's taste tags. A brand's reason names the tags it shares with them. |
| `/v2/insights`, `filter.type=urn:demographics` | seed signals | Age and gender leans. Qloo answers one block per signal, and we average each bucket. |
| `/v2/insights`, `filter.type=urn:heatmap` | seed signals, `filter.location.query` | Where the taste is strongest, on the documented geohash grid: the country first, then up to 3 metros if that comes back empty. |
| `/v2/analysis/compare` | `a.signal.interests.entities`, `b.signal.interests.entities` | Built, but off by default (see below). |

**Seed signals** are `signal.interests.entities` (the seed shows, people and other entities) and `signal.interests.tags` (the seed
tags), plus `operator.signal.interests.tags=union` when there is more than one tag.

### Compare: built, then turned off

We built `/v2/analysis/compare` to explain each match: the tags a show and a brand share. A live probe showed that a
podcast compared with its own top brand returns no shared tags. Each side comes back with its own tags and no id in
common ([live-smoke.md](live-smoke.md)). So `config/research.yml` sets `match_explainer_compares: 0`, and `explain_matches`
works from the overlap between a brand's own Qloo tags and the audience's taste tags, which we already have. That
costs no extra call. The compare code stays for a later same type use.

## Two kinds of report

| | Free Snapshot | Full agent report |
| --- | --- | --- |
| Who decides | Ruby, with fixed rules | The research agent (Claude, through RubyLLM) |
| Seeds | The show on Qloo, the shows the host listed, their topics, the show's categories | The agent's pick, up to 8 entities and 5 tags, each with its source |
| Qloo data | Taste tags, the map, brand matches | Everything in the table above |
| Reasons | None | One plain sentence per brand |
| LLM cost | $0 | About $0.50 (an estimate, logged per run) |
| Uncached Qloo calls | About 10 | A soft cap of 30 |

The agent makes the judgment calls: which seeds stand for the audience, whether a thin profile needs new seeds, which
brand categories fit the show, which matches to keep and how to explain them. Ruby makes every Qloo call, does the
scoring and the tiers (`config/scoring.yml`), and checks what the agent saves.

## Call discipline

Qloo's hackathon key has a limited allowance, so every live call is counted and most are never made twice.

- **Shared cache.** Every answer is cached in our own database (Solid Cache) and shared by every report. `/search` and
  `/v2/tags` answers keep 30 days, everything else 7. A 400 or 404 is remembered for 1 day, so a bad request costs one
  call a day.
- **Heatmaps are trimmed.** Qloo ignores `take` on heatmaps (8,421 cells for the United States in one probe), so we
  keep and cache only the 200 cells with the most affinity, never the whole answer.
- **A call guard** (`app/services/taste/call_guard.rb`) runs before every live request, retries included: at most 30
  a minute (`QLOO_MAX_PER_MINUTE`) and a daily cap the admin sets (100 by default). Over a cap, no request is sent. If
  the counter can't count, it refuses.
- **Reports wait out the minute cap.** In a background job, a refused minute waits for the next one, at most twice per
  call. The daily cap refuses at once.
- **Free and promo runs share 40% of the day** (`qloo_free_share`), so judges and paying users always keep the rest.
- **A soft cap per report** of 30 uncached calls (`max_taste_calls` in `config/research.yml`). Past it, optional calls
  are skipped. The calls a report can't do without always run.
- **Retries are few.** A 429 is retried once, only when Qloo asks for a wait of 5 seconds or less. A 5xx or a timeout is
  retried once. Any other 4xx never is.
- **A bad key pauses runs.** A 401 counts as an auth failure, and three of them pause new runs until an admin resumes
  them. A 403 means the key can't use that entity type, so that optional step is skipped.
- **Failures are free.** A report that fails, for any reason, is never charged to the user's plan.

### Naming places

Qloo's geohash cells carry no place names. Each cell takes the name of the nearest of 163 metros in
`config/world_metros.yml` when one is within 75 km, preferring the report's own country, so a cell by the Detroit
river reads Detroit on a US report, not Windsor. This makes no call.

## Walkthrough: one report, redacted

This walkthrough is built from the synthetic test fixtures in `spec/fixtures/qloo/`. The show "Widget Hour", the show
"Gadget Gossip" and the brands "Acme Ledger", "Borealis Bank" and "Cobalt Cloud" are made up. Entity ids are masked
as `<podcast 1>`, `<brand 1>` and so on. Tag ids keep Qloo's taxonomy format. No real Qloo response appears here.
Every number below comes from those fixtures, read and scored by the app's own code (`Taste::Providers::Qloo::Mapping`,
`Matching::Score`, `Research::Places`).

**The setup.** The host adds "Widget Hour" (category Business, United States) and enters 1,500 downloads per
episode. They list "Gadget Gossip" as a show their listeners also love.

### 1. Read the show

`read_show_feed`: Podcast Index for the show's details, then its RSS feed for the 15 newest episode titles. No Qloo
call. Feed text reaches the agent wrapped as untrusted content, and the agent is told to treat it as data, never as
instructions.

### 2. Find the seeds

The agent calls `find_on_qloo` with two names and two topics:

```text
GET /search    query=Widget Hour        types=urn:entity:podcast,urn:entity:artist,urn:entity:tv_show,urn:entity:movie,urn:entity:book,urn:entity:brand  take=3
GET /search    query=Gadget Gossip      (same types)  take=3
GET /v2/tags   filter.query=business          feature.semantic_search=true  take=5
GET /v2/tags   filter.query=entrepreneurship  feature.semantic_search=true  take=5
```

Search answers a flat `results` list (`entity_id`, `name`, `types`, `popularity` and `properties`). Search is fuzzy, so
a hit only counts when its name is close to the name we asked for. The agent saves four seeds:

| Seed | Kind | Why | Source shown on the report |
| --- | --- | --- | --- |
| Widget Hour `<podcast 1>` | entity | Its name matches the show's title | Your show on Qloo |
| Gadget Gossip `<podcast 2>` | entity | The host listed it | You listed it |
| `urn:tag:genre:media:business` | tag | Matches a topic | Topic: business |
| `urn:tag:genre:media:entrepreneurship` | tag | Matches a topic | Topic: entrepreneurship |

The show itself is on Qloo, so this is a **direct** profile. Had it not been, the report would say **proxy** and list
the comparable shows and topics it was built from. With fewer than 2 seeds, a report stops and asks the host for
comparable shows instead of showing an empty page.

### 3. Build the audience profile

`build_audience_profile`, with every call carrying the same seed signals:

```text
GET /v2/insights  filter.type=urn:entity:brand    take=20
GET /v2/insights  filter.type=urn:entity:podcast  take=10
GET /v2/insights  filter.type=urn:tag             take=15
GET /v2/insights  filter.type=urn:demographics
GET /v2/insights  filter.type=urn:heatmap         filter.location.query=United States  take=50

  signal.interests.entities=<podcast 1>,<podcast 2>
  signal.interests.tags=urn:tag:genre:media:business,urn:tag:genre:media:entrepreneurship
  operator.signal.interests.tags=union
```

What came back, and what the report shows:

- **Brands:** Acme Ledger, Borealis Bank and Cobalt Cloud. Under 8 brands is a thin profile, so the tool tells the
  agent, which may change its seeds once and rebuild.
- **Taste tags:** Business (score 0.91) and Comedy (0.4).
- **Leans:** the fixture has two blocks, one per signal, and each bucket is averaged. Ages 25 to 34 read "A bit above
  average", 55 and older "Well below average", and gender "Leans a little toward women". Leans are shown in words,
  never as percentages.
- **Map:** two cells, named New York and Los Angeles from the metro table.

### 4. Find and score the candidates

The agent picks one brand category, Finance, and calls `find_sponsor_candidates`:

```text
GET /v2/insights  filter.type=urn:entity:brand  filter.popularity.max=0.97  take=50       (the broad pass)
GET /v2/tags      filter.query=Finance  feature.semantic_search=true  filter.tag.types=urn:tag:genre:brand  take=10
GET /v2/insights  filter.type=urn:entity:brand  filter.tags=urn:tag:genre:brand:finance  take=20
```

**The proven sponsor scan** runs in Ruby with no LLM. It finds Gadget Gossip in Podcast Index, reads its 20 newest
episodes, and matches sponsor reads such as "sponsored by", "brought to you by" and "use code ... at". A made up read
from the week before, "This episode is sponsored by Acme Ledger.", yields the name "Acme Ledger", which is then
confirmed on Qloo:

```text
GET /search  query=Acme Ledger  types=urn:entity:brand  take=3
```

Only a brand with the same name is kept: Acme Ledger `<brand 1>`. A name Qloo can't confirm is dropped.

**Scoring** asks for every candidate's affinity to the same seeds in one call:

```text
GET /v2/insights  filter.type=urn:entity:brand  filter.results.entities=<brand 1>,<brand 2>,<brand 3>  take=3
```

Then Ruby scores each brand out of 100: affinity 55 (relative to the run's highest), proven sponsor 20 (a read in
the last 90 days counts in full, an older one half), shared taste tags 15, category match 10. Shows under 5,000
downloads lose up to 15 points on brands with a popularity over 0.6, so household names don't crowd the list. The tier
comes from popularity alone.

| Brand | Affinity | Proven | Shared tags | Category | Small show penalty | Fit | Tier |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Acme Ledger | 0.87, so 55 | yes, 20 | none, 0 | Finance, 10 | 0 (popularity 0.42) | **85** | Easy yes |
| Borealis Bank | 0.64, so 40.5 | 0 | none, 0 | Finance, 10 | 3.75 (popularity 0.70) | **47** | Realistic |
| Cobalt Cloud | 0.50, so 31.6 | 0 | none, 0 | 0 | 13.1 (popularity 0.95) | **18** | Long shot |

### 5. Explain and save

`explain_matches` makes no call. The brands' own tags (Finance) share none of this audience's taste tags (Business,
Comedy), so no brand gets taste chips and the shared tag weight is 0 for all three. That is a real gap in the fixture
data, and the report shows it as it is.

`save_sponsor_matches` keeps only brands from this run's candidates that the agent was shown, with the scores and
evidence the tools produced. A reason may cite only numbers found in that data. A brand saved without a reason gets
one written from its evidence:

- Acme Ledger: "Acme Ledger already sponsors Gadget Gossip, a show much like this one."
- Borealis Bank: "This audience loves Borealis Bank more than most people do."

### 6. What the host sees

An "At a glance" summary, the leans in words, a map with New York and Los Angeles as top places, and three match
cards: Acme Ledger as an easy yes and a high fit, with a "Sponsors Gadget Gossip" chip; Borealis Bank as realistic;
Cobalt Cloud as a long shot. "How we built this" lists each seed with its source and every step with a short summary
of what was asked and what came back, never the raw answer.

This run made 14 uncached Qloo calls. Another report on the same seeds within a week reads them from the cache.

## Responsible data handling

- **No Qloo data in the repo.** Committed fixtures are synthetic. Recorded responses may only go in the git ignored
  `spec/fixtures/private/`, as Qloo's hackathon guide asks.
- **A private cache.** Answers are cached in our own database, which Qloo allows, and never served raw to the browser.
- **No secrets in logs.** A failed call logs the endpoint, the status and the parameter names, never their values and
  never the key.
- **Summaries, not responses.** The agent trace on a report stores short summaries only.
- **Group, not person.** Reports describe an audience as a group ("people with these tastes"), never one listener.
- **Honest labels.** Leans say "Modeled from Qloo taste data, not measured." Public kits say "Stats as reported by
  the verified owner." Sample reports say "Sample report. Not affiliated with the show."

## Limitations

- **Modeled, not measured.** A profile describes people whose tastes match the show's seeds. It is not the show's
  real audience. We never see listener lists or hosting stats.
- **Proxy profiles.** Many small shows aren't on Qloo. Their profile is built from comparable shows, guests and
  topics, and is only as good as those seeds. The report labels it proxy and names every seed.
- **Data gaps.** The hackathon data has gaps: thin brand lists for some seeds, entity types a key may not use (a 403,
  skipped), brand websites mostly missing, and no shared tags from compare across entity types. Search is fuzzy, so we
  check names ourselves.
- **Proven sponsors come from text.** The scan matches common sponsor read phrases in feed notes. It can miss a read
  that isn't written down, or catch a mention that wasn't paid. Only names Qloo confirms as brands are kept.
- **Fresh within a week.** Cached answers can be up to 7 days old (30 for lookups).

**What a result does not establish:**

- that a brand will say yes, or what it will pay;
- that any listener buys from, or even knows, a brand;
- the show's real size, age mix or gender mix (downloads are what the host enters);
- that a proven sponsor is still spending, or was happy with the results;
- that a fit score forecasts anything: it ranks brands inside one report, and isn't comparable across reports.

## Reproduce it

- **No keys:** the README's local setup runs the whole flow on Fake data, in demo mode.
- **The client's tests:** `bundle exec rspec spec/services/taste spec/services/research` runs against the synthetic
  fixtures, with no network.
- **With a key:** `bin/rails qloo:smoke` checks the live shapes in 8 calls, 10 at most ([live-smoke.md](live-smoke.md)).
