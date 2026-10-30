# Live smoke test (Qloo)

Run this once a real Qloo key is in hand, before trusting live reports. It checks the shapes our client parses
(`Taste::Providers::Qloo`) against what the hackathon server really sends. Source: our check of the request
parameters against Qloo's API docs on 2026-10-25, whose mismatches M1 to M7 the client now handles.

## The quick way: `rake qloo:smoke`

With `QLOO_API_KEY` in the environment (loaded from wherever the key is kept, never typed on the command line or
echoed):

```bash
bin/rails qloo:smoke    # development; in production, run it in the app container, where QLOO_API_KEY is set
```

`Taste::Smoke` runs 8 checks through `Taste::Providers::Qloo`: the podcast search and its miss variant, brand tags,
brand recommendations, union, demographics, the heatmap and taste tags (no compare: R105, see the results below). That
is 8 live calls, a hard budget of 10 counting retries, and every call counts toward the admin's daily cap. It reads
past the response cache and saves nothing. Per call it prints the endpoint, HTTP status, result count, which parsing
paths matched (flat or `properties`, the heatmap's lat/lon keys, the demographics block count), at most 3 names, and
PASS or FAIL. It refuses to run without `QLOO_API_KEY`, or outside development and production, and aborts before the
next call when the budget is spent, the call guard refuses or Qloo rejects the key (401).

To check only some things, name them (R107); the podcast search the others need is added for you, so a rerun spends
only what it checks:

```bash
STEPS=search_miss,heatmap bin/rails qloo:smoke    # 3 live calls: search_podcast, search_miss, heatmap
```

The steps are `search_podcast`, `search_miss`, `brand_tags`, `brand_recs`, `union`, `demographics`, `heatmap` and
`taste_tags`.

The curl commands below are the same checks by hand, with the variants the rake task leaves out.

Rules: the key stays in an environment variable and is never printed, logged or committed. Save no raw responses in
the repo; real responses may only go in the git-ignored `spec/fixtures/private/`, and Qloo's guide doesn't allow its
data in public repositories.

## How the call counters behave

`Taste::CallGuard` counts live calls in `Rails.cache` (Solid Cache in development and production), keyed by UTC minute
and UTC day, plus the capped lane's day (free and promo users, R108).

- **Bounded race.** Solid Cache makes each increment atomic on an existing row, but the first increment of a new key
  (the first call of a minute or a day) can race: two processes that both find no row each write a 1, and one of those
  counts is lost. The overshoot is at most the number of callers racing at that moment, less one, so with the job
  threads and a web process it is a call or two over a cap, once per new minute or day, never more.
- **Development and production count apart.** Each environment has its own cache database (and namespace), so each
  enforces `qloo_daily_call_limit` on its own, while both use the one Qloo key and its one allowance. With 100 a day
  in each, the key can see up to 200. Keep development's limit low (or count its calls in) when setting production's.
- **A background job waits out the minute cap** (R109), at most twice per call; the daily cap and the capped share
  refuse at once, and outside a job the minute cap refuses at once too.

## Live smoke checklist (run these as soon as the key arrives)

Shell setup. The key stays in an env var and is never printed.

```bash
Q() { curl -sS --get -w '\nHTTP %{http_code}\n' -H "X-Api-Key: $QLOO_API_KEY" "https://hackathon.api.qloo.com$1" "${@:2}"; }
```

**1. Search for a podcast (and a miss)**
```bash
Q /search --data-urlencode 'query=SmartLess' --data-urlencode 'types=urn:entity:podcast' --data-urlencode 'take=5'
```
- **Good:** HTTP 200; `results` is a flat array; `entity_id`, `name`, `types` or `subtype` containing `urn:entity:podcast`, `popularity`, `properties`. Save the result as `POD_ID`.
- **Variants:** rerun with the user's own small-show title (UNVERIFIED 2), and with `query=zzqxv nonexistent show` to see whether a miss is 200 with `[]` or 404 (M1).

**2. Tag lookup scoped to brands**
```bash
Q /v2/tags --data-urlencode 'filter.query=food and beverage' --data-urlencode 'filter.tag.types=urn:tag:genre:brand' --data-urlencode 'feature.semantic_search=true' --data-urlencode 'take=5'
```
- **Good:** `results.tags[]` where every `id` starts with `urn:tag:genre:brand:`, `type` is `urn:tag:genre:brand`, and `urn:tag:genre:brand:food_and_beverage` is near the top (M4).
- **Variant:** rerun without `filter.tag.types` and check whether a brand tag still shows up in the top 10.

**3. Brand recommendations from a podcast, then affinity_for**
```bash
Q /v2/insights --data-urlencode 'filter.type=urn:entity:brand' --data-urlencode "signal.interests.entities=$POD_ID" --data-urlencode 'filter.popularity.max=0.97' --data-urlencode 'take=5'
```
- **Good:** `results.entities[]` with `entity_id`, `subtype=urn:entity:brand`, `query.affinity` between 0 and 1, `popularity`, and `tags[]` with `urn:tag:genre:brand:*` ids.
- **Record exactly where these sit:** the image (`properties.image.url` or flat `url`?), `description`, and `official_site` (M6, UNVERIFIED 3). Save one result as `BRAND_ID`.
- **Variant:** add `--data-urlencode "filter.results.entities=<id1>,<id2>"` with `take=2`. You should get exactly those two back, each with a `query.affinity`.

**4. Union check for multiple tag signals**
```bash
Q /v2/insights --data-urlencode 'filter.type=urn:entity:brand' --data-urlencode 'signal.interests.tags=urn:tag:genre:media:business,urn:tag:genre:media:comedy' --data-urlencode 'operator.signal.interests.tags=union' --data-urlencode 'take=10'
```
- **Good:** 10 brands.
- **Variant:** run the same call without `operator.signal.interests.tags`.
  - If you get fewer results or a different order, the param is honoured and R15 stands.
  - If the results are identical, it's ignored for brand. That's harmless.

**5. Demographics with a podcast signal plus a tag**
```bash
Q /v2/insights --data-urlencode 'filter.type=urn:demographics' --data-urlencode "signal.interests.entities=$POD_ID" --data-urlencode 'signal.interests.tags=urn:tag:genre:media:business'
```
- **Good:** HTTP 200, not 403 (M7). `results.demographics` has **2** blocks, one with `entity_id=$POD_ID` and one with the tag (M3). Each block has the 6 age buckets and `male`/`female`.

**6. Country-wide heatmap with the locality boundary** (superseded: this answers 502; the client now asks without the
boundary param, see the results below)
```bash
Q /v2/insights --data-urlencode 'filter.type=urn:heatmap' --data-urlencode 'filter.location.query=United States' --data-urlencode "signal.interests.entities=$POD_ID" --data-urlencode 'output.heatmap.boundary=urn:entity:locality' --data-urlencode 'take=10'
```
- **Good:** HTTP 200 and a non-empty `results.heatmap`. Record the exact keys of `results.heatmap[0]`: `location.latitude`/`longitude` or `lat`/`lon`/`lng`, plus any `name` (M5).
- **If you get 400:** the country isn't a locality, so the metro fallback must handle it (M2).
- **Variant:** rerun without the boundary param. The default geohash grid should match HEAT.

**7. Taste tags for a podcast**
```bash
Q /v2/insights --data-urlencode 'filter.type=urn:tag' --data-urlencode "signal.interests.entities=$POD_ID" --data-urlencode 'take=10'
```
- **Good:** HTTP 200, not 403. `results.tags[]` with `tag_id`, `name`, `subtype` and `query.affinity`. Note how much of it is keyword or Wikipedia noise; that decides whether to add `filter.tag.types`.

**8. Compare a podcast and a brand** (reports no longer call compare: a podcast and a brand share no compare tags, see
the results below)
```bash
Q /v2/analysis/compare --data-urlencode "a.signal.interests.entities=$POD_ID" --data-urlencode "b.signal.interests.entities=$BRAND_ID" --data-urlencode 'take=10'
```
- **Good:** HTTP 200, `results.tags[]` with `tag_id`, `name`, `subtype`, `popularity` and `query.score`, and no `success` key. A 404 here confirms M1 for compare.

This is 8 calls, plus about 5 cheap variants: well under one report's budget of 30 (R105).

Once these pass, the committed fixtures in `spec/fixtures/qloo/` stay synthetic. Real responses, if kept at all, go only in the git-ignored `spec/fixtures/private/`: the hackathon guide (HG) doesn't allow Qloo data in public repositories.

## Results 2026-10-25

Run by the controller with the real key, shapes, statuses, counts and timings only (no names, ids or bodies kept).
24 live calls that day: 21 before the fixes, 3 in the rerun after them.

**`rake qloo:smoke`, before the review:** 10 of 10 calls, 6 passed, 2 failed, aborted before compare.

| Check | Status | What came back |
|---|---|---|
| Podcast search | 200 | `results` a flat list; image at `properties.image.url`; tags flat; `types` present |
| Brand tags, `filter.tag.types=urn:tag:genre:brand` | 200 | the filter works; `food_and_beverage` present |
| Brand recommendations | 200 | `query.affinity` from 0 to 1; `properties.description`; `official_site` mostly absent |
| Union of two tags | 200 | brands came back |
| Demographics (podcast and tag) | 200 | 2 blocks, 6 age buckets, 2 genders |
| Taste tags | 200 | `tag_id`, `query.affinity`, `subtype` |
| Search miss (nonsense query) | 200 | 5 results: search is fuzzy, it answers the nearest shows |
| Heatmap, `output.heatmap.boundary=urn:entity:locality` | 502, twice | the retry used the 10th call |

**Probes, budgets of 6, 3 and 3:** 11 calls.

| Probe | Status | What came back |
|---|---|---|
| Heatmap without the boundary param | 200 | the documented geohash shape: `location.latitude`, `location.longitude`, `location.geohash`, `query.affinity`, `query.popularity`. `take` is ignored: 8,421 points for the United States in 4.6 s, 1,023 for New York in 2.1 s |
| Compare, a podcast against its top brand | 200 | `results.tags` empty, plus `results.a` (24 tags) and `results.b` (40 tags), each side's own tags with `query.count` only and no score; no tag id in common |

**What changed (fix round 1 of Task Q1):**

- R105: no compare calls; every brand is explained from the tags it shares with the audience; the research cap is 30.
- R106: the heatmap uses the geohash output, keeps and caches only the 200 points with the most affinity, and names
  places from the nearest of 163 metros (`config/world_metros.yml`, within 75 km).
- R107: the smoke's miss check passes when no result's name is close to the query; the proven scan's lookup takes 3
  hits and keeps the same-name one; `STEPS=` reruns only some checks.
- R110: a 400 or 404 is remembered for a day, so an unplaceable location costs one call a day.

**Rerun to confirm:** `STEPS=search_podcast,search_miss,heatmap bin/rails qloo:smoke`, 3 live calls (4 at most, with
one retry).

**Rerun after the fixes:** `STEPS=search_podcast,search_miss,heatmap`: 3 passed, with 3 live calls. The heatmap's
8,421 geohash points were cut to the 200 with the most affinity (R106). That made 24 live calls that day.
