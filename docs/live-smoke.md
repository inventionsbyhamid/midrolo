# Live smoke test (Qloo)

Run this once a real Qloo key is in hand, before trusting live reports. It checks the shapes our client parses
(`Taste::Providers::Qloo`) against what the hackathon server really sends. Source: the Qloo params check of
2026-10-25 (`.superpowers/sdd/2026-10-24-midrolo-implementation-plan/qloo-params-check.md`), whose mismatches M1 to M7
the client now handles.

## The quick way: `rake qloo:smoke`

With `QLOO_API_KEY` in the environment (loaded from wherever the key is kept, never typed on the command line or
echoed):

```bash
bin/rails qloo:smoke    # development; in production, run it in the app container, where QLOO_API_KEY is set
```

`Taste::Smoke` runs checks 1 to 8 below (search plus the miss variant, brand tags, brand recommendations, union,
demographics, heatmap, taste tags, compare) through `Taste::Providers::Qloo`: 9 live calls, a hard budget of 10
counting retries, and every call counts toward the admin's daily cap. It reads past the response cache and saves
nothing. Per call it prints the endpoint, HTTP status, result count, which parsing paths matched (flat or
`properties`, the heatmap's lat/lon keys, the demographics block count), at most 3 names, and PASS or FAIL. It
refuses to run without `QLOO_API_KEY`, or outside development and production.

The curl commands below are the same checks by hand, with the variants the rake task leaves out.

Rules: the key stays in an environment variable and is never printed, logged or committed. Save no raw responses in
the repo; real responses may only go in the git-ignored `spec/fixtures/private/`, and Qloo's guide doesn't allow its
data in public repositories.

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

**6. Country-wide heatmap with the locality boundary**
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

**8. Compare a podcast and a brand**
```bash
Q /v2/analysis/compare --data-urlencode "a.signal.interests.entities=$POD_ID" --data-urlencode "b.signal.interests.entities=$BRAND_ID" --data-urlencode 'take=10'
```
- **Good:** HTTP 200, `results.tags[]` with `tag_id`, `name`, `subtype`, `popularity` and `query.score`, and no `success` key. A 404 here confirms M1 for compare.

This is 8 calls, plus about 5 cheap variants: well under one report's budget of 60 (R31).

Once these pass, the committed fixtures in `spec/fixtures/qloo/` stay synthetic. Real responses, if kept at all, go only in the git-ignored `spec/fixtures/private/`: the hackathon guide (HG) doesn't allow Qloo data in public repositories.
