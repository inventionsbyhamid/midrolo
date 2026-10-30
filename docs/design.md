# Midrolo — Podcast Sponsor Matcher: Design

**Status:** draft for approval · **Date:** 2026-10-24 · **Hackathon:** Qloo Agentic Hackathon. Deadline **Oct 30, 11:45 PM EDT** (Oct 31, 03:45 UTC).

**Name: Midrolo**, the user's pick 2026-10-24, from "mid-roll", the best-paid podcast ad slot. midrolo.com and midrolo.fm were both unregistered on 2026-10-24. Where this doc says "the app", it means Midrolo. Code uses the constant `APP_NAME`, so renaming it is one line.

---

## 1. Intent: what this is and why

Independent podcasters want sponsors, but they can't prove who their listeners are. Hosting stats show downloads and countries, nothing about taste. So they guess which brands to pitch and send generic media kits. Most get ignored, or get told they're "not big enough." The tools that would help are built for big shows: Rephonic and Podchaser start at $99 to $300 a month. The marketplaces built for small shows keep dying. **Podcorn shuts down on Nov 1, 2026**, and Station, an AI sponsor matcher, has paused.

The app is an **AI agent that does a sponsorship sales team's research for one show, in about two minutes**:
- It works out what people who like the show also love, across brands, music, TV and other podcasts, using Qloo's taste graph.
- It finds the brands that fit, including brands that **already sponsor similar shows**.
- It explains *why* each brand fits, using real data.
- It writes the pitch and builds a media kit that proves the fit.

**Why it needs Qloo:** an LLM on its own can only guess ("tech listeners like gadgets"). Qloo supplies cross-category taste data: brands, artists, shows and places that this audience over-indexes on, plus where those people are. That data is exactly what small shows lack and can't get anywhere else.

**The two goals, in order:**
1. Win or place in the Qloo hackathon. The top 3 pitch live on Nov 5.
2. Sell it as a real product afterwards.

The user's call is to build it **production-ready, not as a demo**: Google login, landing page, background jobs, Cloudflare R2, PostgreSQL, and real billing.

## 2. Who it's for

- **Primary:** independent podcasters with roughly **500–50,000 downloads per episode** who want their first or next sponsors. That's about 20–30k shows worldwide, around half in the US. Most use Buzzsprout, Transistor or Captivate and spend $15–50 a month on tools.
- **Also served:** shows with 100–500 downloads (the "too small" crowd). The free tier and flat-fee pricing advice cover them.
- **Later (not v1):** producers and small networks running several shows, and brands searching for podcasts.

## 3. Goals, non-goals, anti-goals

**Goals (v1, by the deadline)**
1. Type a show's name and get a full **Sponsor Report** in about 2–3 minutes, with live agent progress on screen.
2. The report includes:
   - an audience taste profile
   - age and gender leans
   - a map of where this taste concentrates
   - about 30–50 ranked brand matches, each with a fit score, a plain reason and evidence
   - a "proven podcast sponsor" badge for brands seen sponsoring similar shows
3. One-click **pitch pack** per brand: a short email, 3 ad-read angles, a suggested offer and a follow-up email.
4. A public **media kit** page per show, with a suggested rate card and print-to-PDF.
5. A simple **pipeline** per match (saved → pitched → replied → won/lost), with notes.
6. A production-grade app: Google sign-in, landing page, pricing, working subscriptions, background jobs, R2 storage, deployed on our own server behind Cloudflare.
7. A hackathon submission that passes Stage 1 easily and scores well on all four criteria (see §13).

**Non-goals (v1)**
- Sending emails to brands on the user's behalf (no Gmail API). We give "Open in Gmail" and copy buttons.
- Finding brand contact emails (Hunter-style lookups). We say who to look for and where.
- Verified download stats through hosting-provider APIs. Downloads are self-reported.
- Team seats, white-label kits, the Producer plan, a brand-side marketplace, or commission checkout.
- Mobile apps and non-English UI.

**Anti-goals (failure even if it "works")**
- **A ChatGPT media-kit wrapper.** If a match or reason could be produced without Qloo data, it doesn't belong in the report.
- **Claims we can't back.** We never say "your listeners are 25–34." We say "people with your show's taste lean 25–34 (modeled from Qloo taste data)." Every brand shown must come from a tool result in that run.
- **Spam.** No bulk sending. We don't encourage blasting 50 brands.
- **Judges hitting a paywall** or a broken flow during judging.
- **Anything that risks the other production apps on our server.**
- **Negative unit economics.** No plan may cost more to serve than it earns, even at maximum use.

## 4. Constraints

- **Time:** other deadlines run until Oct 27. Qloo work gets full attention from Oct 27 evening, but foundation work can start as soon as this doc is approved (§14).
- **Qloo key:** requested through a form and issued by hand, which can take days. Until it arrives we build against **synthetic fixtures** modeled on Qloo's API docs, then switch to live.
- **Qloo after the hackathon:** hackathon keys are switched off after the event, and commercial pricing isn't published. Selling the product needs a commercial agreement with Qloo. This is the biggest business risk (§15).
- **Hackathon rules:**
  - A live hosted demo.
  - A **public repo with an OSI license** shown in the GitHub About section.
  - Judges get free, unrestricted access until Nov 5.
  - **Qloo response data must not be committed to the public repo.**
- **Shared server:** our server also runs other production apps, so we use an isolated stack with resource caps.

## 5. The product: screens and flows

### 5.1 Public
- **Landing page (`/`).** Hero: "Find sponsors who already love your listeners." The problem in the hosts' own words, how it works in 3 steps, a live sample report, a comparison with the old way (guessing, generic kits, marketplaces that shut down), pricing, an FAQ (including "where does the data come from" and "what this doesn't prove") and a footer with Podcast Index attribution.
- **Sample reports (`/samples/:slug`).** 2–3 fully run reports on real, well-known indie shows, viewable without login. Each is labeled "Sample — not affiliated with the show." This is the path for judges who don't sign in.
- **Media kit (`/k/:slug`).** The public page a podcaster sends to brands (§5.6).
- **Blog (`/blog`, R148).** The SEO growth channel: guides for the questions independent podcasters search, each ending in a free Snapshot. Posts are Markdown files in `content/blog` with front matter, so a post ships like code; each gets its own share image, article tags, JSON-LD, a sitemap entry and a place in the Atom feed. The blog is linked from the header, footer and sitemap only once a post is published.
- Pricing, privacy, terms and a contact page.

### 5.2 Sign-in
- Google only (Devise + OmniAuth). After the first sign-in the user goes straight to "Add your show".

### 5.3 Add a show (onboarding)
1. **Search.** Type a show name. Results come from Podcast Index, showing artwork, title, host and episode count. Pick the right one. A pasted RSS or Apple URL also works.
2. **Optional details** (each improves results, none is required):
   - 30-day downloads per episode, for pricing
   - audience country (default US)
   - up to 5 "shows your listeners also love"
   - topics
   - a contact email
3. **Run.** This creates a report and starts the agent job.

### 5.4 The report page, filling in live
- **Agent progress rail** (Turbo Streams): readable steps like "Reading your last 15 episodes…", "Found 4 comparable shows on Qloo…", "Checking who sponsors Show X…". Each step expands to show what was asked and what came back. This makes the agent visible to judges and builds trust with users.
- **Taste profile banner.** A note saying whether we found the show itself on Qloo (*direct*) or built the profile from comparable shows and topics (*proxy*). For a proxy profile it lists the seeds and where each came from, e.g. "guest mentioned in episode 112".
- **Sections**, each appearing as soon as it's ready:
  1. **Your audience at a glance.** A 2–3 sentence summary, top taste tags, and the brands, artists, TV shows and podcasts this audience over-indexes on. Each item shows its image, with affinity as a bar.
  2. **Leans.** Age and gender as relative leans (over- or under-index), clearly labeled as modeled.
  3. **Where your kind of listener lives.** A heatmap with a top-metros list, used for regional brands and local sponsors.
  4. **Sponsor matches.** A ranked list or cards. Each match has:
     - logo, name, category
     - **fit score** (0–100) and a **reachability tier**: *Niche, easy yes* / *Mid-size, realistic* / *Big brand, long shot*
     - a one-line reason grounded in shared taste tags and entities
     - evidence chips: "shares 6 taste tags", "your audience's affinity 0.82", "**sponsored *Show X* in Sept**"
   - Filters: category, tier, proven sponsors only. Sort by fit or tier.
  5. Each match has a **"Write my pitch"** button, which opens the pitch pack (§5.5), and a **pipeline status** dropdown with notes.
- **Re-run report** button, limited by plan.

### 5.5 Pitch pack (per brand, generated when asked)
- **Subject line and email body** (100–150 words): personal, cites 2–3 concrete data points, and ends with a low-friction ask.
- **3 ad-read angles**, i.e. how the host could talk about this brand naturally on their show.
- **Suggested offer**, using the rate rule (§5.7). Example: "4-episode mid-roll bundle, $X".
- A **follow-up email** for day 7.
- **Who to contact:** the likely role (e.g. "Head of Partnerships / Influencer Marketing") and the brand's official site from Qloo.
- Buttons: Copy, "Open in Gmail" (compose URL), Regenerate, and Mark as pitched (moves the pipeline status).

### 5.6 Media kit (public page, editable)
- Show artwork, about text and host photo (uploaded to R2), plus links.
- Self-reported stats: downloads, episode count, publishing cadence (from RSS).
- The audience taste profile highlights, the leans, a map snippet and the top metros.
- "Brands our audience loves", with a picker so the host can hide brands that compete with them.
- **Rate card**, generated from the rate rule and editable.
- A "Work with us" contact button (mailto).
- **Print-to-PDF** through a print stylesheet. A server-rendered PDF is a later item.
- A view counter. On the Free plan the page shows a "Made with Midrolo" badge, which is our distribution.
- **Publishing requires proving you own the show** (Claude's call). Anyone can add any show and run private reports. To make a kit **public**, the user enters a 6-digit code sent to the owner email in the show's RSS feed (`itunes:owner` / `podcast:email` / `managingEditor`).
  - If the feed has no email, or the user can't reach it, the fallback is to put a token in the show description (`podcast:txt` or a description line) and click "check".
  - This blocks fake kits that sell fake ad spots for someone else's show, and it stops slug squatting. Slugs are reserved only once a show is verified.
  - Unverified users see a **private preview** of the full kit (noindex, watermarked "Preview"). Judges can see everything without owning a show.
  - Public kits carry a small "Stats self-reported by the verified owner" note.

### 5.7 Rate rule (deterministic, editable by the user)
- **Under about 5k downloads per episode:** a flat fee per mid-roll, with a $25 floor. The amount is scaled by downloads and a niche multiplier (B2B and finance 1.5×, others 1.0–1.2×).
- **5k and above:** 30-day downloads × CPM. Host-read mid-roll uses a $25 CPM baseline (range $20–30), times the niche multiplier. Pre-rolls are 0.8× and post-rolls 0.5×.
- **Bundles:** 4 episodes at 10% off.
- The page shows the source of these numbers, citing published CPM benchmarks.

### 5.8 Account and billing
- Plan, usage this period, upgrade or manage (the Dodo customer portal), and an invoices link.
- Delete account and data.

### 5.9 Admin (internal)
- Mission Control Jobs at `/admin/jobs`, behind HTTP basic auth.
- A small admin page: users, reports, spend counters (Claude tokens, Qloo calls), and a kill switch for new runs.

## 6. The agent: how a report is made

**Framework: RubyLLM** (the user's call, 2026-10-24, so the AI provider can be switched by config). Pin the latest 2.x release (2.1.1 on Oct 11, 2026).
- The agent is a `RubyLLM::Agent` subclass (`SponsorResearchAgent`), and each tool is a `RubyLLM::Tool` class. RubyLLM runs the tool-calling loop.
- This counts as both "functions as an agentic tool" and "built using an agent framework."
- **The provider and model come from config, never code.** Defaults:
  - `LLM_AGENT_MODEL=claude-opus-5-5` for the agent
  - `LLM_PITCH_MODEL=claude-opus-5-5` for pitches
  - provider: Anthropic
  - **Changed 2026-10-29 (the user's call):** the defaults are now `z-ai/glm-5.3` (GLM 5.3, chosen over DeepSeek V4.1 Flash and GLM 5.3 Flash in a head-to-head on the demo shows, R146) through OpenRouter
    (`LLM_PROVIDER=openrouter`, `OPENROUTER_API_KEY`), asking OpenRouter for hosts that don't store or train on
    prompts. Anthropic stays one env change away (`LLM_PROVIDER=anthropic`, the model ids above).
- Switching to Sonnet or Haiku, or to OpenAI or Gemini, is an env change plus a run of the eval below.
- **Model settings:** thinking on (RubyLLM `with_thinking(effort: :medium)` to start, tuned in testing). No temperature, since current Claude models reject it.
- **Prompt caching** on the system prompt and tool definitions, through RubyLLM's Anthropic cache support.
- **Day-1 compatibility check:** the current Claude models have stricter rules: adaptive thinking only, no `temperature`, no forced tool choice. Day 1 confirms RubyLLM 2.1.x sends valid requests for `claude-opus-5-5` (model in its registry, thinking format, tool calls, structured output).
  - If something's missing, use RubyLLM's `with_params` and `assume_model_exists`, or a small provider patch inside our wrapper.
  - The rest of the app stays unaffected.
- **Small eval set:** 8–10 real shows with expected traits (e.g. "a finance show gets fintech and B2B brands; a proxy profile is labeled"). Run it before switching models or providers.
- One report runs in one Solid Queue job (`GenerateReportJob`).

**Tools the agent can call.** The tools are **coarse on purpose**: each one bundles several Qloo calls in Ruby and returns a compact summary. That keeps a report to about **6–10 agent turns instead of 20+**, roughly halving Claude cost (see §11). The agent still makes the decisions that need judgment: which seeds to use, whether a profile is too thin and needs different seeds, which brand categories suit this show, and how to explain each match. Each tool call is logged as an `AgentStep` and broadcast to the page. The individual Qloo calls inside a tool are logged as sub-steps, so the trace still shows all the Qloo work.

| Tool | What it does | Backed by |
|---|---|---|
| `read_show_feed` | Show metadata plus the last ~15 episodes (titles and trimmed descriptions) | Podcast Index + RSS |
| `find_on_qloo` | Batch lookup: up to 10 names (the show, comparable shows, guests, artists, brands) → Qloo entities, and up to 5 topic phrases → Qloo tags | Qloo `/search` + `/v2/tags` |
| `build_audience_profile` | For a seed set: top brands, artists, TV shows and podcasts, taste tags, age and gender leans, and the heatmap (country, falling back to top metros). Saves the profile sections and returns a compact digest, including a "thin profile" warning when results are sparse. | Qloo `/v2/insights` (entity types, `urn:tag`, `urn:demographics`, `urn:heatmap`) |
| `find_sponsor_candidates` | For a seed set and the brand categories the agent picks: broad and per-category brand recommendations with a popularity cap, merged with the proven-sponsor scan of similar shows (§7.3), then scored and tiered deterministically (§7.2). Returns the ranked list with evidence. | Qloo insights (`filter.results.entities` for scoring) + Podcast Index + RSS |
| `explain_matches` | For the top ~30 brands: the taste tags each brand shares with the audience, returned compactly | The overlap of each brand's own Qloo tags with the audience's taste tags, so no Qloo call. Qloo `/v2/analysis/compare` is built but off by default (R105: in one live probe, a podcast and its own top brand shared no compare tags) |
| `save_taste_seeds` / `save_sponsor_matches` / `save_summary` | Persist structured results; each section appears on the page when saved | Our DB |

**Playbook given to the agent.** The order is a guide, not hard-coded, and the agent adapts when data is missing:
1. Read the show feed. Find the show itself, plus candidate seeds from episodes and the user's hints, on Qloo.
2. Choose **seeds**: 3–8 entities and 2–5 tags. Record where each seed came from, and save them (direct or proxy).
3. Build the audience profile. If it comes back thin, adjust the seeds once and rebuild.
4. Pick brand categories that suit the show and find sponsor candidates.
5. Explain the top ~30. Write a one-line reason each, grounded only in tool data. Save the matches.
6. Write the summary.

**Guardrails**
- At most ~40 tool calls, a timeout of about 6 minutes, and a task budget on the request.
- If Qloo returns an empty result, the tool says so explicitly ("no results — try different seeds") so the agent can adapt instead of inventing.
- **Provenance check on the server:** `save_sponsor_matches` rejects any brand ID that didn't appear in a tool result during this run, and any numeric claim that isn't in the stored data.
- **Failure handling:** a failed run marks the report failed, keeps whatever sections were saved, doesn't count against the plan, and the user can retry. Retries are idempotent per section.
- **Caching:** Qloo, Podcast Index and RSS responses go into Solid Cache, which lives in our private DB (Qloo allows private caching). TTL is 7 days for Qloo (30 days for `/search` and `/v2/tags` lookups, 1 day for a 400 or 404 miss: R93, R110) and 24 hours for feeds.
- **Paused mode for new runs** (Claude's call), for when the Qloo key is switched off or we're over budget:
  - **Triggers:** a `RUNS_PAUSED` flag in the env or admin, or an automatic switch after repeated Qloo 401/403 errors.
  - **Behaviour:** new reports, Snapshots and pitches show a clear "new reports are paused, we'll email you" message and add the user to a notify list. Existing reports, pipelines and kits stay available.
  - **Public trace:** the agent trace stores and shows short summaries, never raw Qloo responses.

**The pitch writer** is not an agent. It's a single LLM call (`LLM_PITCH_MODEL`) with structured output (RubyLLM `with_schema`, using a `RubyLLM::Schema` class) in `GeneratePitchJob`. Its inputs are the show summary, the brand's Qloo properties (description, target audience, official site), shared tags, proven-sponsor evidence and the rate rule. Its output is subject, body, angles, offer, follow-up and contact role.

## 7. Matching, scoring and the proven-sponsor scan

### 7.1 Direct vs proxy profiles
- **Direct:** the show itself is in Qloo's graph, so we seed with its entity plus comparable entities.
- **Proxy:** the show isn't in Qloo (common for small shows). We seed with comparable shows, guests and topics the agent finds in the feed, plus the user's hints.
- Proxy is shown honestly in the UI and in the media kit's methodology note.

### 7.2 Fit score (0–100) and tier
Computed in Ruby so it's explainable and stable:
- **Taste affinity:** 55%. The brand's affinity to the seed set, normalized within the run.
- **Proven podcast sponsor:** 20%. Seen sponsoring similar shows, weighted by recency.
- **Shared-tag overlap:** 15%. The brand's own Qloo tags that the audience's taste tags share (R27; compare is off, R105).
- **Category relevance to the show's genre:** 10%.
- **Popularity:** sets the tier. Popularity ≥ 0.9 is a *long shot*, 0.6–0.9 is *realistic*, under 0.6 is an *easy yes*. It also applies a mild penalty for small shows, which keeps Nike-scale brands from taking over the list.
- The weights live in one config, and the builder may tune them against test shows.

### 7.3 Proven-sponsor scan (key differentiator)
1. Similar podcasts come from Qloo podcast recommendations, plus the user's "shows your listeners love".
2. Find each one in Podcast Index, then fetch its RSS.
3. Run a **deterministic** extraction over the last 20 episodes. Patterns include "sponsored by X", "brought to you by X", "thanks to our sponsor X", "use code … at X", "promo code", and URL patterns like `x.com/showname`. Each match yields a candidate brand name or domain. **No LLM call happens here, so the step costs nothing.** If the deterministic pass misses obvious sponsors during tuning, the builder may add one small structured Claude call per show, only on snippets that matched.
4. Confirm each brand on Qloo (`/search` with types=brand). Drop anything that can't be resolved.
5. Store the evidence as brand, show, episode and date. The UI shows "Sponsored *Show X* · 3 episodes · latest Oct 12".

## 8. Data sources and accounts

- **Qloo API:** the hackathon environment, `X-Api-Key`. Request shapes follow Qloo's API docs. The client sits behind a small adapter (`Taste::Provider`, with `Taste::Providers::Qloo` and a Fake) so it can be swapped for the `qloo api` command-line tool if Qloo requires it. *Action: confirm in Discord #api-help.*
- **Podcast Index API:** primary source for podcast search and metadata. Free key, attribution required in the footer and on the about page.
- **RSS feeds:** episodes and show notes, read with a feed parser.
- **Apple iTunes Search/Lookup:** fallback only (artwork, Apple ID, URL pasting), cached and rate-limited to under 20 calls a minute.
- **Anthropic API:** Claude.
- **Map tiles:** OpenFreeMap (free, no key) rendered with MapLibre GL JS.

## 9. Stack (decided)

Matches the user's most recent Rails app (`dinnerbell-app-feel`) except where noted.

| Area | Choice |
|---|---|
| Language / framework | Ruby 3.4.12, **Rails 8.1.3** |
| Database | **PostgreSQL 16** (user's call) |
| Frontend | Hotwire (Turbo + Stimulus), **importmap**, **Tailwind CSS 4** (`tailwindcss-rails`), Propshaft. Chart.js for the bars, if they're not done in plain CSS. |
| Map | MapLibre GL JS (pinned version, via importmap/CDN) + OpenFreeMap tiles |
| Background jobs | **Solid Queue**, plus **Mission Control Jobs** for admin |
| Live updates | **Solid Cable** + Turbo Streams |
| Cache | **Solid Cache**, also used for the private API-response cache |
| Auth | **Devise + omniauth-google-oauth2 + omniauth-rails_csrf_protection**, Google only |
| File storage | **Active Storage → Cloudflare R2** (S3-compatible, `aws-sdk-s3`): kit images, host photos, cached artwork. A separate R2 bucket holds DB backups. |
| AI | **RubyLLM 2.x** (`ruby_llm`, `ruby_llm-schema`; `ruby_llm-test` for specs, as in dinnerbell), with `RubyLLM::Agent` and `RubyLLM::Tool`. Provider-agnostic; the default is Anthropic `claude-opus-5-5`, set from env. *(The user's call.)* |
| HTTP / RSS | Faraday with retries that honor `Retry-After` · Feedjira for RSS *(builder may swap)* |
| Payments | **Dodo Payments** for now (`dodopayments` gem). Merchant of record, so global tax is handled; hosted checkout, webhooks, customer portal. It sits **behind a provider interface** (§9a), so Polar.sh or another provider can be swapped in later. |
| Email | **Resend**: welcome, report ready, payment issues |
| Rate limiting / security | Rails 8 `rate_limit`, CSP, Brakeman, bundler-audit |
| Pagination | pagy |
| Tests | RSpec, FactoryBot, shoulda-matchers, WebMock. **Synthetic** fixtures go in the repo; fixtures recorded from Qloo stay private (gitignored). |
| Deploy | Rails 8 Dockerfile + Thruster → **Docker Compose on our own server** behind Coolify's **Traefik** proxy, with Cloudflare DNS in front (R37, R79; no tunnel, no host ports) |
| License | **AGPL-3.0** *(Claude's call, see §16)* |

## 9a. Engineering practices (the user's call: "modular so we can switch, follow best practices")

**Every outside service sits behind an adapter.** The app talks to our own interface, never to a vendor SDK directly. Swapping a vendor means writing one new adapter and changing config, with no edits elsewhere.

| Interface | v1 adapter | Possible later | What the interface covers |
|---|---|---|---|
| `Billing::Provider` | `Billing::Providers::Dodo` | `Billing::Providers::Polar`, Stripe… | `checkout_url(user, price_key)`, `portal_url(user)`, `verify_webhook(request)`, and `parse_event(payload)` → our own normalized `Billing::Event` (subscription_started / renewed / canceled / payment_failed / one_time_paid) |
| `Taste::Provider` | `Taste::Providers::Qloo` (direct REST) | `Qloo` via the `qloo api` CLI | search, tags, recommendations, demographics, heatmap, compare. Each returns our own value objects, never raw vendor JSON. |
| `Podcasts::Directory` | `Podcasts::Directories::PodcastIndex` | Apple, Taddy | search, lookup by ID or URL, feed URL |
| `Llm` (thin wrapper over RubyLLM) | RubyLLM, with the provider and model set by env | Any RubyLLM provider (Anthropic, OpenAI, Gemini, Bedrock, OpenRouter…), or another library entirely | Starts the agent and structured one-shot calls. It owns model and effort config, **cost accounting** from our own price table (`config/llm_pricing.yml`, so costs are right even for models RubyLLM's registry doesn't price), budget checks, and logging. RubyLLM is used only inside `app/llm/` and the agent and tool classes. |
| Email | ActionMailer + Resend delivery method | any SMTP | standard mailers |
| Storage | Active Storage service `r2` | any S3-compatible service | standard |

**Rails' own abstractions are used wherever they exist,** so their backends can be swapped by config. That covers Active Job (Solid Queue now), Active Storage (R2 now), Action Mailer (Resend now), `Rails.cache` (Solid Cache now), Action Cable (Solid Cable now) and OmniAuth (Google now; Apple or GitHub sign-in is one more strategy).

**Product rules live in config, not code:**
- `config/plans.yml`: prices, caps, features.
- `config/llm.yml` + `config/llm_pricing.yml`: models, effort, prices.
- `config/scoring.yml`: fit weights and tier thresholds.
- `config/rate_card.yml`: CPMs, floors, multipliers.
- `config/geo.yml`: heatmap fallback metros per country.
- `MAP_STYLE_URL`: the map tile provider.

**Plans and limits belong to us, not the payment provider.**
- Prices are mapped by a `price_key` (e.g. `creator_monthly`) to each provider's product IDs in config.
- **Entitlements** (caps, features) are defined in one `Plans` config in our code.
- Webhooks only update our `subscriptions` table through normalized events.
- Webhook handling is **idempotent**: each event is stored once by its ID and then processed in a job.

**Code structure**
- Thin controllers.
- Domain logic lives in plain service objects under `app/services`. Examples: `Reports::Generate`, `Matching::Score`, `Pricing::RateCard`, `Billing::Sync`.
- Background work runs in jobs: `GenerateReportJob`, `GeneratePitchJob`, `BuildSnapshotJob`, `ProcessBillingEventJob`.
- Agent tools are small classes that call services, so they're testable without Claude.

**Configuration**
- All keys and secrets come from ENV, through Rails credentials or `.env` on the server. `.env.example` lists every one.
- No vendor IDs are hard-coded in code paths.

**Quality**
- RSpec for services, scoring, the rate card, adapters (WebMock with synthetic fixtures), webhooks (signed fixture events) and request specs. One system test of the core flow.
- RuboCop (rails-omakase), Brakeman and bundler-audit.
- **GitHub Actions CI** runs all of these on every push.

**Observability**
- Structured logs with a request ID.
- Per-run cost and latency recorded in the DB.
- The Rails error reporter emails the admin.
- `/up` health check, used by Docker.

**Security**
- CSRF protection and a CSP.
- Rate limits through Rails' built in `rate_limit` (R84): per user on reports, pitches, show search and the judge code, per show on verification mail, and a global per IP guard (60 a minute). Search engine crawlers confirmed by reverse and forward DNS (`VerifiedCrawler`, never the user agent alone) may read past the global guard on GET and HEAD; every other limit still applies to them.
- Signed webhook verification.
- Authorization checks so users only see their own shows, reports and kits. Public kits and samples are read-only.
- Secrets never reach the browser.
- Qloo data never goes into the public repo.

**Git**
- Small, focused commits with clear messages.
- `main` is always deployable.
- A README covering setup, architecture and "How we use Qloo".

## 10. Data model (sketch)

- **users:**
  - Google `uid`, email, name, avatar
  - `admin` flag
  - The current plan is derived from the user's active subscription, sprint or promo.
- **subscriptions:** provider-agnostic.
  - user, `provider` (dodo/polar/…), provider customer ID, provider subscription ID
  - `price_key`, `plan` (creator/pro/sprint), `status`
  - `current_period_start` / `current_period_end`, `cancel_at_period_end`
- **shows:** belongs to a user.
  - Podcast Index ID, Apple ID, feed URL, title, author, description, artwork URL, categories, episode count, cadence
  - Qloo entity ID (nullable)
  - self-reported downloads, country, contact email
  - hints (comparable shows, topics) as JSON
- **reports:** belongs to a show.
  - status (queued, running, done, failed), profile kind (direct/proxy)
  - JSON sections: seeds, audience, demographics, heatmap, summary
  - started/finished timestamps, error
  - usage: input/output tokens, Qloo calls, cost estimate
  - `sample` flag and slug, for the public sample reports
- **agent_steps:** belongs to a report. Position, tool name, readable label, input summary, output summary, status, duration.
- **sponsor_matches:** belongs to a report.
  - Qloo brand ID, name, image, official site, category tags
  - affinity, popularity, fit score, tier, reason
  - evidence JSON: shared tags, proven-sponsor shows and episodes
  - pipeline status, notes, follow-up date
  - Matches are copied forward to a new report so status and notes aren't lost.
- **pitches:** belongs to a sponsor match. Subject, body, angles, offer, follow-up, contact role, model, tokens.
- **media_kits:** belongs to a show. Slug, published, headline, about, rate card JSON, hidden brand IDs, view count. Photos via Active Storage (R2).
- **billing_events:** webhook log for any provider (provider, provider event ID unique per provider, type, payload, processed time), so each webhook is processed exactly once.
- **usage_counters,** or plan checks computed on the fly: reports and pitches per billing period.

## 11. Pricing, plans and unit economics (profitable from day 1)

**The user's requirement:** profitable from day 1. Here that means three things:
1. Every paid plan stays profitable at its **maximum** allowed usage.
2. Free users cost us **no Claude spend**.
3. Fixed costs are close to zero, because everything is hosted on our own server.

**Market grounding** (our market research): half of podcasters spend $25 a month or less on all their tools, commission marketplaces for small shows keep failing, and the adjacent tools start at $99. **No commission.**

**Billing launch** (the user's call, 2026-10-24): **Dodo test mode plus a waitlist.**
- **What's built:** billing in full (checkout, webhooks, portal, plan limits), tested end to end in **Dodo test mode**.
- **What visitors see:** the pricing page shows the real prices. Paid buttons say **"Join the founding member waitlist"**, which records the email and the chosen plan.
- **Going live:** we switch to live payments only once we have a **commercial Qloo agreement**. A hackathon key likely doesn't cover charging customers, and it switches off after the event. Charging before then would risk the entry and mean refunds. The code enforces it (R94): `Billing.mode` refuses `live` until an admin sets `qloo_cost_per_call_usd` and every paid plan keeps at least 60% margin at its caps (`Billing::Margins`: LLM, Qloo and worst case Dodo fees).
- **When "day 1" is:** day 1 of revenue is the day billing goes live. Every plan is profitable from that first sale (the tables below). Until then, spend is limited to the hackathon budget.

| Plan | Price | What you get | Hard caps per period |
|---|---|---|---|
| **Free: Snapshot** | $0 | 1 show. A **Snapshot**, built **without any AI**: Qloo data only, using deterministic seeds (the show's own Qloo entity if it's there, otherwise Podcast Index categories mapped to Qloo genre tags plus the user's comparable shows). It shows taste tags, the map and the **top 5 brand matches** with scores but no reasons; the rest are blurred with their count shown. Media kit with a "Made with Midrolo" badge. Full sample reports to browse. | 1 Snapshot refresh per month. 0 agent reports. 0 pitches. |
| **Creator** | **$19/mo** or $190/yr | 1 show, the full **agent report** (~50 matches with reasons and the proven-sponsor scan), pitch packs, branded kit with no badge, rate card, pipeline, kit view count | 4 reports, 40 pitches |
| **Pro** | **$49/mo** or $490/yr | 3 shows, deeper scan (more similar shows), CSV export, priority queue | 12 reports, 150 pitches |
| **Sponsor Sprint** | **$49 once** | Pro for 30 days, no renewal | Same as Pro |

**Variable cost per unit.** Estimates, to be measured in testing; every run logs its real cost.

| Unit | Claude Opus 5.5 | Claude Sonnet 5.5 (option) |
|---|---|---|
| Agent report (6–10 turns with coarse tools, cached prompt, compact results, deterministic sponsor scan) | **≈ $0.40–0.50** | ≈ $0.20–0.25 |
| Pitch pack (one structured call) | **≈ $0.04** | ≈ $0.02 |
| Free Snapshot | **$0** (no AI) | $0 |

**Payment fees** (Dodo, merchant of record): 4% + 40¢, plus 0.5% for subscriptions and 1.5% for international cards. The worst case is about **6% + 40¢**.

**Margin at the caps**, on Opus with worst-case fees. Real usage will be well below the caps.

| Plan | Net after fees | Claude at caps | Gross margin at caps | At typical use (≈ 25% of caps) |
|---|---|---|---|---|
| Creator monthly $19 | $17.46 | 4 × $0.50 + 40 × $0.04 = **$3.60** | **79%** | ~95% |
| Pro monthly $49 | $45.66 | 12 × $0.50 + 150 × $0.04 = **$12.00** | **74%** | ~93% |
| Sprint $49 | ≈ $45.90 | $12.00 | **74%** | ~93% |
| Creator yearly $190 (per month) | ≈ $14.85 | $3.60 | **76%** | ~94% |

**Fixed costs**
- **Hosting:** $0 extra. The app, database, job worker and backups all run on our existing server.
- **Cloudflare R2:** free tier, which covers 10 GB storage and 1M writes a month.
- **Resend:** free tier, 3k emails a month.
- **Podcast Index:** free.
- **Domain:** about $15–90 a year, depending on the TLD.
- **Break-even is the first paying customer.**

**The one unknown is Qloo's commercial price after the hackathon** (free during it, with a limited allowance). Our
protections, as built (R92, R93, R105, R108 to R110; these replace R31's numbers):
- **Calls per report:** a soft cap of 30 uncached Qloo calls per full agent report (`max_taste_calls`, `config/research.yml`).
  Past it, optional sub calls are skipped. A hard ceiling of 40 (`hard_taste_calls`, R130) then stops every call, the
  ones a report can't do without included: the agent is told the budget is used up and saves what it has, so one
  runaway report can't spend the day. A Snapshot makes about 10 and is held to the same ceiling. `Billing::Margins`
  counts every report at 40.
  Compare is off (`match_explainer_compares: 0`, R105), so explaining matches costs no call.
- **A shared cache:** responses are cached privately in Solid Cache and **shared across users**: `/search` and `/v2/tags`
  for 30 days, everything else for 7, and a 400 or 404 miss for 1 day (R110). Heatmaps keep only their top 200 cells.
- **A call guard** (`Taste::CallGuard`, R92): at most 30 live calls a minute (`QLOO_MAX_PER_MINUTE`) and a daily cap the
  admin sets (`qloo_daily_call_limit`, 100 by default), checked before every request and every retry, failing closed.
- **A capped lane** (R108): runs by free and promo users may use at most 40% of the daily cap (`qloo_free_share`), so
  judges, paying users and sample generation keep the rest. The run form checks the lane before queuing.
- **Minute waits** (R109): a report in a background job waits out the minute cap, at most twice per call. The daily cap
  and the lane refuse at once.
- **The go live guard** (R94): live billing is refused until `qloo_cost_per_call_usd` is set and every paid plan keeps
  at least 60% margin at its caps. The admin page shows Qloo calls and cost per report, and the margin per plan.

**Spend safety**
- A monthly spend limit set in the Anthropic console.
- An app level **daily LLM budget** (`LLM_DAILY_BUDGET_USD`, 5 by default). Over it, new promo and paid full reports
  stop with a "paused, nothing was charged" message; judges and samples draw on their own budgets.
- The cost of every report and pitch is logged, and the admin page shows margin per user.
- A kill switch.
- Google sign-in is required for everything except sample reports.
- Per-IP and per-user rate limits (Rails `rate_limit`).

**Hackathon judging promo, with a hard total budget of $10** (the user's call, 2026-10-24, may be raised later)
- Qloo is free during the hackathon, so the budget is effectively all Claude cost, about 20 agent reports. Development and tuning runs are tracked separately and aren't part of this budget.
- **Budget split** (`PROMO_BUDGET_USD=10`, `JUDGE_RESERVE_USD=5` in env, both editable without a deploy through the admin page):
  - **Judge access code** (Claude's call): a code in the Devpost testing instructions (`JUDGE_CODE` env), entered once on the account page. It unlocks Pro features with up to 3 agent reports and unlimited pitches per judge account, drawing on the **$5 judge reserve**, so judges never hit a cap.
  - **Public promo:** until **Nov 6, 2026** (`PROMO_PRO_UNTIL`), every other signed-in account gets **1 agent report** plus pitches, from the remaining **$5**. When that runs out, new public accounts get the free Snapshot and a "full reports are paused, join the waitlist" message. Judges are unaffected.
- **Sample reports** are generated once before submission. They cost about $1.50 in total and come out of the development budget; viewing them costs nothing.
- Anyone can still browse the samples, take a free Snapshot and preview a kit, all at $0 in Claude cost. This keeps us within the rule that judges get free, unrestricted access.

## 12. Hosting and operations

As first built (R37, R79, R115, R117), and kept for self-hosting in `docs/self-hosting.md`. Since 2026-10-29
midrolo.com runs as a Coolify project instead (web app, worker and Postgres, hourly backups to R2; `docs/deploy.md`).
- **`compose.yml`** in the repo, every service named `midrolo-*`:
  - `midrolo-web`: Rails behind Thruster (port 80 inside the container). The only service that also joins the shared
    `coolify` network.
  - `midrolo-jobs`: `bin/jobs`, the Solid Queue worker.
  - `midrolo-db`: `postgres:16` with the `midrolo-db` volume, on the stack's own `midrolo-net` network only.
  - `midrolo-backup`: a nightly `pg_dump` at 03:00 UTC to an **R2 bucket**, keeping 14 days. It has its own R2 token
    (`BACKUP_R2_ACCESS_KEY_ID`, `BACKUP_R2_SECRET_ACCESS_KEY`), scoped to the backup bucket, and a
    `midrolo-backup-state` volume that keeps a failed run flagged (and the container unhealthy) until a later one
    succeeds.
- Every service has **CPU and memory caps** (2 CPUs and 2 GB each), a health check and `restart: unless-stopped`.
- **No tunnel and no host ports.** Coolify's **Traefik** proxy finds `midrolo-web` by its labels: `Host(midrolo.com)` on
  the `https` entrypoint with a Let's Encrypt certificate, `http` redirected to `https`, and `www` redirected to the apex.
  TLS ends at Traefik, so Rails runs with `assume_ssl` and `force_ssl`.
- **DNS** at Cloudflare: A records for midrolo.com and www to the server, DNS only to start. Cloudflare's proxy works too
  (SSL Full strict); the client IP then comes from CF-Connecting-IP, believed only from Cloudflare's own addresses
  (`cloudflare-rails`, `config/initializers/client_ip.rb`).
- **Secrets** live in `.env` on the server only. `.env.example` in the repo lists every variable. Production refuses to
  boot without the required set (`lib/required_env.rb`), including `QLOO_API_KEY`, `PODCAST_INDEX_KEY`,
  `PODCAST_INDEX_SECRET` and an absolute http(s) `APP_URL`.
- **Deploying:** rsync the code from a laptop (of the `.env*` files, only `.env.example`), then `docker compose up -d
  --build` on the server, building there. Other stacks' containers, networks and volumes, and Traefik's and Coolify's
  own configuration, are never touched.
- **Logs:** Docker logs. Errors go to the Rails error reporter, logged plus an email to the admin through Resend. A
  hosted error tracker is a later item.

## 13. Hackathon submission plan

**Stage 1 (pass/fail).** It's clearly an agent, and Qloo is used in 6 different ways: search, tags, brand and podcast insights, taste tags, demographics and the heatmap. Compare is built but off by default (R105), which the write up says plainly.

**Stage 2, mapped to the criteria:**
- **Technical implementation (also the tie-breaker):**
  - deep, multi-endpoint Qloo use
  - a visible agent trace with provenance
  - deterministic scoring
  - tests
  - a clean public repo
- **Design:** a complete product. Landing page, onboarding, live report, pitch pack, media kit, billing and a polished UI.
- **Potential impact:**
  - the hosts' own quotes
  - market numbers
  - Podcorn shutting down Nov 1
  - fully built billing (test mode) with a founding-member waitlist
  - the $19 tool pays for itself with one sponsor spot, and every plan is profitable at its caps
- **Quality of idea:**
  - taste data as the evidence small shows never had
  - "proven sponsors of similar shows"
  - honest proxy profiles

**Deliverables**
- Live URL.
- Sample reports anyone can open without logging in.
- Public GitHub repo with an AGPL-3.0 license in About, a README with setup steps, and **"How we use Qloo"**: a redacted request-to-result walkthrough of a report.
- Known limitations: modeled audience, not measured; proxy profiles; data gaps.
- Devpost description with screenshots and testing instructions: sample report links, Google sign-in, the **judge access code**, and the note that billing is in test mode (with Dodo's test card, if judges want to try checkout).
- An optional 2-minute video, since judges may judge from images and text alone.
- A **live-pitch prep** doc for Nov 5: a 3-minute pitch, a demo script, and answers to likely questions on business model, Qloo dependency and accuracy.

## 14. Schedule (India time)

| When | What |
|---|---|
| **Sat Oct 24** | Approve this doc (name chosen: Midrolo). User registers midrolo.com and creates accounts and keys (§17). Qloo key requested. |
| **Sun Oct 25 – Tue Oct 27 midday** | The user is on other deadlines, so **Claude builds the foundation** with short check-ins: Rails app, auth, landing page, show search (Podcast Index), Qloo client against synthetic fixtures, agent and tools, report UI, media kit, pitch pack, billing in test mode, compose files. |
| **Tue Oct 27 evening – Wed Oct 28** | Switch to live Qloo (if the key is in). Tune seeds, scoring and prompts on 8–10 real shows. Proven-sponsor scan on real feeds. |
| **Thu Oct 29** | Deploy to the server. Verify Dodo **test-mode** checkout, webhooks and portal end to end; turn on the waitlist. Generate sample reports. Design polish. Fixes. |
| **Fri Oct 30** | Hardening. README and "How we use Qloo". Devpost write-up and screenshots. Optional video. **Submit by Fri Oct 30, 17:30 UTC**, about 10 hours before the deadline. |
| **Nov 2–5** | Keep it up and watched during judging. Prepare the live pitch in case we're a finalist. |

**If the Qloo key hasn't arrived by Wed Oct 28 morning:** escalate in Discord and keep building on fixtures. The demo can't be honest without live data, so this is the critical path.

## 15. Risks and what we do

| Risk | Impact | What we do |
|---|---|---|
| Qloo key arrives late | Can't tune on real data | Fixtures first, escalate in Discord, a small set of carefully tuned sample reports |
| Small shows aren't in Qloo | Weak results | Proxy profile from feed-derived seeds plus hints, labeled honestly |
| Calling Qloo directly vs the kit's harness | Rules ambiguity | Ask in Discord. Keep the adapter swappable. |
| **Qloo access after the hackathon** | Can't sell without it | Contact Qloo about partner or commercial terms (a finalist slot helps). Cache aggressively within their terms. State the dependency openly in the business plan. |
| Brand data skews to big brands | Unrealistic matches | Popularity cap, tiers, per-category passes, proven-sponsor weight |
| Silently ignored Qloo parameters | Wrong results that look fine | A fixture test per request shape, empty results treated as errors, the query echo logged |
| Claude cost overrun or abuse | Spend | Plan limits, global daily cap, kill switch, cost logged per report |
| Hallucinated brands or numbers | Trust and credibility | Server-side provenance check, structured outputs, "modeled" labels |
| Too much scope for ~4 days | Unfinished product | Order of cuts if late: CSV export → Pro multi-show → pipeline notes → Sprint plan. The core flow and media kit stay. |
| Shared server safety | Outage of other apps | Isolated compose stack, resource caps, never touch other containers |
| Apple iTunes terms | Legal grey area | Podcast Index is the primary source; Apple is only a cached helper |
| Charging customers on a hackathon-only Qloo key | Possible breach of the API terms, which would put the entry at risk. Refunds if the key dies. | **Resolved:** billing stays in test mode with a waitlist until a commercial Qloo agreement exists (§11) |
| Fake kits for shows the user doesn't own | Impersonation, fake ad sales | RSS-owner verification before publishing (§5.6) |
| RubyLLM lagging behind the newest Claude API rules (no temperature, adaptive thinking only, no forced tool choice) | 400 errors from the agent | The day-1 compatibility check (§6). Fix through `with_params` / `assume_model_exists` or a small patch inside `app/llm/`. Fallback: switch `LLM_AGENT_MODEL` to a model RubyLLM fully supports. |
| Dodo onboarding as an individual with no company | Live payments delayed | Build and test end to end in test mode. Confirm Dodo's individual-seller onboarding early; Polar is the alternative behind the same interface. |

## 16. Decisions

**Made by the user**
- Podcast-only product for podcasters, including the map. Production-ready, intended for sale.
- Google login, landing page, background jobs, Cloudflare R2, PostgreSQL.
- Host the **entire app on our own server**, the database included.
- **Profitable from day 1** (§11).
- **Dodo Payments for now**, with billing **modular so the provider can be switched** (Polar.sh is a candidate). Follow software-engineering best practices (§9a).
- **Billing launch:** test mode plus a founding-member waitlist until there's a commercial Qloo agreement (§11).
- **Hackathon promo budget:** $10 total for now (§11). The user will check whether Qloo offers free testing usage.
- **Name: Midrolo.**

- **RubyLLM** for all LLM work, so the provider and model can be switched. **Everything modular** (§9a).

**Claude's calls (check these while reading)**
1. *(Replaced: the user chose RubyLLM.)*
2. **Default model: Claude Opus 5.5** for the agent and the pitches (about $0.40–0.50 per report and $0.04 per pitch with coarse tools). That's already profitable at the caps. With RubyLLM it's one env change to Sonnet 5.5 (about half the cost) or to another provider. Check the eval set first.
2a. **Free tier is an AI-free Snapshot.** The full agent report is paid, so free users cost nothing in Claude spend.
3. **Resend** for email. *(Dodo Payments for now is the user's call, behind a swappable billing interface.)*
4. **Docker Compose**, not Kamal. kamal-proxy would clash with the existing setup. (The Cloudflare tunnel planned here was replaced by Coolify's Traefik proxy: R37, R79, §12.)
5. **AGPL-3.0.** The rules require an OSI license. AGPL stops someone hosting a closed clone, while MIT would allow it.
6. **Podcast Index** as the primary podcast data source, with Apple as a fallback.
7. **Pricing:** Free Snapshot / Creator $19 / Pro $49 / Sprint $49, no commission. The caps are in §11.
8. **Rate rule** and **fit score weights** as in §5.7 and §7.2.
9. **Print-to-PDF** for media kits in v1, with a server-rendered PDF later.
10. **Domain** `midrolo.com` on Cloudflare.
11. **Proving show ownership** before a kit goes public (an RSS owner-email code, or a token in the feed). Everyone, judges included, gets a private preview (§5.6).
12. **Paused mode** for when the Qloo key goes off or the budget runs out. Existing work stays available (§6).
13. **Judge access code** with its own $5 reserve. Public promo gets 1 agent report per account from the other $5 (§11).

**Nothing is left open.** The builder check came back with three questions; all three are answered above (billing launch, kit ownership, promo budget and judge access).

## 17. Setup checklist (accounts and keys the user creates)

0. **Register `midrolo.com`** (Cloudflare Registrar, about $10/yr), and optionally `midrolo.fm`. Do it soon, since both were unregistered on Oct 24.
1. **Qloo API key:** use the form in the dev guide, today. Check spam. Ask in Discord #api-help about direct REST calls, and whether there's free testing usage beyond the hackathon key.
2. **Podcast Index API key:** api.podcastindex.org, free.
3. **Anthropic API key**, with a spend limit set.
4. **Google OAuth client** (Google Cloud Console): web app, redirect URIs for localhost and the production host.
5. **Cloudflare R2:** two buckets (app files, DB backups) and an S3 API token.
6. **Dodo Payments:** an account (check that onboarding works as an individual) with products **in test mode** (Creator monthly/yearly, Pro monthly/yearly, Sprint one-time) and a webhook secret.
7. **Resend:** API key and a verified sending domain.
8. **DNS A records** for midrolo.com and www at Cloudflare (no tunnel: §12), plus the server path for the compose stack.
9. **GitHub:** a public repo `inventionsbyhamid/midrolo`.

## 18. Left to the builder

- Exact gem versions, file and module layout, controller and route naming.
- The HTTP client and RSS parser choice (Faraday and Feedjira are suggestions).
- Visual design details within "clean, confident, media-kit quality". Use the frontend-design skill.
- Prompt wording, agent effort level and the tool result shapes. Keep tool results compact for cost.
- Tuning the fit-score weights and the popularity thresholds against test shows.
- How the heatmap is rendered and which metros are in the US fallback list.
- Test depth beyond: a fixture test per Qloo request shape, the scoring unit, rate-rule units, the webhook handler, and one system test of the core flow.
