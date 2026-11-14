# Price Accordion – Hintahaitari

> Look at anything, guess its price, and watch the accordion squeeze to the real price range. Then see what that price means for *your* money.

Junction 2026 hackathon project (solo). This file is the design document and the rules of the project:
Claude Code reads it at the start of every session. Setup and run instructions are in `README.md`. Keep this file up to date
when decisions change.

---

## 1. The idea in one paragraph

Young adults rarely know whether something is cheap or expensive, because prices live on screens
and things live in the street. Hintahaitari ("price range" in Finnish) turns everyday sights into
money lessons. You look at a car, a pair of headphones or a chair (through Meta glasses or the
phone camera). You **guess** its price first. Then the **price accordion** opens on your guess
and squeezes to the real price range as live data arrives. Finally the coach puts the
price into your own budget: which of the three spending baskets it belongs to, how many weeks of your
everyday spending it is, and how much of your spare money it takes.

## 2. Submission and tracks

| Field | Value |
| --- | --- |
| Project name (≤30) | Price Accordion – Hintahaitari |
| Punchline (≤200) | Look at anything, guess its price, and watch the accordion squeeze to the real price range. Then see what it means for your own money. |
| Submission 1: main challenge | **Personal Economic Trainer** (S-Pankki): the money-coach story |
| Submission 2: main challenge | **AI Glasses for Everyone, Everyday** (Meta): the first-person story |
| Tech challenges | Best Use of Nemotron (NVIDIA) · Best Use of Context.dev: Fully Structured Web |
| Deliverables | Demo link · public GitHub repo · demo video · presentation (Keynote/PDF, ≤20 MB) |

**Same app, two submissions, two framings.** One codebase and one repo. Each submission gets its own
punchline, description, video cut and deck emphasis:
- **S-Pankki:** "chat with your money, starting from what you see": baskets, safe-to-spend, guess-first learning. Mobile first.
- **Meta:** "a price lens for the real world": hands-free and first-person on the Ray-Ban Display lens.

**Glasses:** built and tried on **Meta Ray-Ban Display + Neural Band** (camera, lens, touchpad, band); the camera and
speakers also work on Ray-Ban Meta glasses without a lens, where the phone shows the screens. The HUD uses the DAT SDK 1.0.1
Display, Inputs and photo capture. Checklist and findings: `docs/GLASSES_SESSION.md`.

**Lens HUD:** the display API places components side by side and takes one root
view per `send`, so each 600 x 600 screen is composed in HUDRenderer.swift (reticle + animation + text) and sent as
one image. Art: design/glasses (HUD_ASSETS.md, process_assets.py → Glasses/HUD/*.png). Flow (GlassesFlow.swift):
aim → lock → looking → success → "Is this a …?" → guess dial → accordion + verdict, driven by Inputs events
(capture button, touchpad / band Select, Nav, band Drag) and a lens tap. The picture for a look is a stream frame or a standalone photo (switch in the Glasses lab; each has its own aim calibration). The phone flow keeps working unchanged.

The phone flow must always work without glasses (S-Pankki feasibility). The glasses flow must feel
native, not like a mirrored phone screen (Meta's brief).

### Judging criteria (design every feature against these)

**S-Pankki – Personal Economic Trainer** (main, 5 × 20%)
- Impact on financial literacy, including the pedagogical angle → guess-first + three baskets on every answer
- Originality of AI integration → money questions start from what you *see*
- Clarity of the mobile user experience → three screens: Look · Coach · Score
- Feasibility → runs on S-Pankki's synthetic data; the glasses are optional
- Potential to integrate into S-mobiili → the coach logic is plain Python behind a small API; Nemotron is open-weights, so the bank can self-host

**Meta – AI Glasses for Everyone, Everyday** (main, 4 × 25%)
- Creativity and use case → prices where the things are; guess-first; an arcade lens HUD with a guess dial you turn with a wrist gesture
- Technical execution → DAT camera stream or standalone photo, Display and Inputs on the Ray-Ban Display; errors, slow networks and device changes are shown on the lens and the phone
- Real-world value and feasibility → a pilot path with a bank's young-adult customers
- User experience: input, accessibility and trust → touchpad, band and button input; VoiceOver reads the result; the glasses speak the description and the result; faces are blurred and the photo cropped on the phone; sources are shown

**NVIDIA – Best Use of Nemotron** (4 × 25%)
- Meaningful usage: Nemotron sees (identifies), reasons (prices + your data) and teaches (plain language)
- Technical execution: crops not frames, cache, retries, timeouts; the guess hides latency
- Quality of AI output: answers grounded in fetched prices and computed numbers; the user confirms what the model saw
- Creativity: vision + personal-finance reasoning in one loop

**Context.dev – Fully Structured Web** (40 / 30 / 30)
- Creative use (40%): search → structured extraction across many Finnish shops and dealers, for cars, electronics and any other item, with new and used prices kept apart
- How central live web data is (30%): without live listings there is no price range at all
- Technical execution (30%): accuracy (matching, dedupe, outlier trim), latency (pages read concurrently, the range narrows as each answers)

## 3. The teaching model (S-Pankki pedagogy)

Every answer places money into one of **three baskets**:
1. **Mandatory, regular**: rent, loan payments, subscriptions
2. **Mandatory, irregular**: a broken washing machine, a car repair
3. **Everyday leaks**: coffees, snacks, taxis; the money that slips through your fingers

**Guess first.** The user always guesses before seeing a price. The app keeps a **price-sense score**
(how close the guesses are, per category, over time). This is the core learning mechanic.

**MyData spirit.** The user explores their own data freely ("what kind of spender am I?", "what is safe
to spend this week?", "what if I cut dining out by 20%?"), not fixed charts. Peers are the median of the same age band in the
dataset.

## 4. The price accordion (signature UI)

A horizontal accordion whose bellows show a price range:
- It **opens wide** on the user's guess (uncertainty).
- It **squeezes** as each source answers (listings found → range narrows → median marked).
- The final state shows the real range, the median, the user's guess as a marker, and the gap in € and %.
- On the phone it is a SwiftUI view (`AccordionView`); on the Ray-Ban Display lens the same squeeze is drawn as an
  arcade bar (`HUDRenderer`), and the result is also spoken with the on-device voice.

## 5. Architecture

```
Meta glasses (camera, lens, touchpad, band) or the phone camera
        │  picture (on the phone: blur faces, crop to the object)
        ▼
iOS app (Swift + Meta Wearables Device Access Toolkit)
        │  HTTPS via cloudflared tunnel
        ▼
server/ (Python, FastAPI)
   ├── see:     Nemotron 3.5 Super VL → {kind, make, model, year_range, confidence}
   ├── price:   Context.dev (search → structured extraction): cars, electronics and any other item
   ├── money:   S-Pankki synthetic data → baskets, safe-to-spend, what-if (pure Python, no LLM maths)
   └── coach:   Nemotron → plain-language explanation, grounded in the numbers above
```

### Endpoints
- `POST /look`: image crop (+ optional kind hint) → identification + price range + sources
  The iOS app sends the blurred, centre-cropped JPEG as the raw request body (`Content-Type: image/jpeg`), not multipart.
  **Built:** the reply is immediate (~2 s) with `look_id`, `identification` ({kind, make, model, year_range, confidence,
  description, variant}, from see.py: Nemotron with reasoning off + a JSON schema) and `price`. Priceable kinds: `car`, `headphones`,
  `phone`, `laptop`, and `item` = ANY other purchasable object (furniture, bike, coat, toy ...): Nemotron gives a generic or
  specific name plus a Finnish search phrase (`search_fi`), Context.dev searches shops live and the range is flagged as a rough
  estimate (brand, size and quality move it). Only things with no shop price (`building`, `menu`, `other`) are skipped. For a confident one, `price` starts as `searching` and a background job (looks.py) reads live Finnish pages
  through Context.dev (search → ~6 pages scraped concurrently, 5 credits each, ~15-20 s) → low / median / high, sources,
  `fetched_at`, notes. Cars: dealer listings (price.py). Products: shop pages (products.py) → the **new** price range is the guess
  target, plus a `used_range` (used / refurbished) as a second line; a model only sold used now gets `price_basis: "used"`.
  Other kinds: `skipped`.
- `POST /confirm` `{look_id, kind?, make, model, variant?, year_from?, year_to?}`: the user says "yes, that is it" or corrects what the
  model saw (it is often wrong on electronics and on similar cars). A user-confirmed identity skips the confidence bar and, if it
  changed, restarts the price job for the right thing (stale jobs are ignored). 409 once a guess is locked; 422 when a correction
  needs a `kind`. The app asks before every guess: the price depends on the exact model.
- `GET /look/{look_id}`: the same look with the price as far as it has got (`searching | reading | done | insufficient | failed |
  skipped | unavailable`). The app polls every ~1.5 s: the range narrows as each source answers, while the user guesses.
  Price stats are plain Python: dedupe the same car across sites, match the model, ±1 year window (flagged "rough" under 8
  listings; under 3 → `insufficient`, never a fallback to all years, which once priced a 2018 Octavia at 550-1,100 EUR from
  2007 listings), Tukey outlier trim, 10th-90th percentile (min-max under 10 listings). Results are cached 30 min in cache/price/. Errors from identification:
  504 `thinking`, 503 `unavailable`, 502 `unreadable_reply` / `model_error`.
- `POST /guess` `{look_id, guess_eur}`: lock in the user's guess for a look (guess first, then see). Immutable once locked
  (same value again is fine, a different one is 409); 400 when the look has nothing to price. The comparison is computed
  by Python (score.py) and appears as `guess.result` on `GET /look/{id}` once the price is final: `gap_eur`, `gap_pct`,
  `verdict` (close within ±5% | high | low), `in_range`, `score` (100 at the median, 0 at half or double, ratio-based) and a
  ready-made `summary` sentence that the phone, VoiceOver and the glasses' voice all use.
  **iOS flow built:** Look → identification → "Is this a …?" (yes / change it / tell me what it is) → "what do you think it costs?"
  (number pad) → Lock in → the accordion
  (ios-app/PriceSense/Look/AccordionView.swift): bellows open wide on the guess, squeeze as sources answer, median line, green
  guess marker when inside the range, the summary, score and sources line. A debug-only "Accordion playground" (ladybug menu) plays a
  recorded lookup without server or credits.
- `GET /money/personas`, `GET /money/profile?customer_id=`, `POST /money/context` `{customer_id?, look_id | price_eur, kind, name}`:
  what a price means for a customer of the synthetic S-Pankki data. **Built (money.py, pure Python):** the three baskets are OUR
  mapping of the 15 categories (regular = Housing, Utilities, Groceries, Transportation; irregular = Health, Home & Tech; leaks =
  Restaurants, Entertainment, Lifestyle, Travel; investment deposits are savings, not spending), a typical month is the mean of the
  latest 12 months without one-off spikes (> 3x the median), spare money = income - baskets - savings, peers = median leaks of the same
  age band. A price gets a basket (rule of thumb), weeks of everyday leaks, % of spare money, months to save, a verdict
  (fits-this-week | fits-this-month | save-up | out-of-reach | no-room), the 20 % what-if and a ready-made sentence. Three demo
  personas (22-34: tight / typical / comfortable). Data: `scripts/build_money_profiles.py` boils the 346 MB transactions file down to
  `data/spankki/monthly.csv` + `customers.csv` (git-ignored).
- `POST /coach` `{customer_id?, question, look_id | price_eur ...}`: Nemotron explains the numbers above in plain language (English or
  Finnish), given only a FACTS block (typical month, the price context, a table of every what-if it may quote) and told never to
  calculate or contradict the computed verdict. Falls back to the computed sentence if the model is unreachable (`source`).
  **iOS built:** Coach screen after the accordion ("What this means for my money": persona picker, basket card, three stat tiles, the
  month as one bar, what-if, ask box with suggestions) and a Score screen (top bar chart icon: average, trend, hit rate, streak, per
  kind, recent guesses; kept on the phone, one entry per look).
- `GET /health`

## 6. Hard rules

1. **Privacy.** NVIDIA's hosted API must not receive personal data (faces). Never send raw
   frames off the phone. On device: blur faces (Apple Vision) and crop to the object; licence plates are not
   blurred yet. Store no images. Price the *model*, never "this person's car".
2. **No LLM arithmetic.** Python computes totals, baskets, ranges and what-ifs; Nemotron explains them.
3. **Grounding.** Every price shows its sources and a "fetched at" time. If sources disagree or are
   missing, say so.
4. **Nemotron client.** Disk cache keyed by (prompt, image hash). Retries with exponential backoff.
   About 40 requests/min. Timeouts and a graceful "still thinking" state.
5. **Context.dev.** Check every output's `success` flag (a 200 can still fail). `maxAgeMs: 0` for
   listings. Respect each site's terms.
6. **Secrets** only from `.env`. Never commit `.env`, `data/` or `cache/`.
7. **The phone flow must work without glasses** (S-Pankki), **and the glasses flow must stand on its own**
   (Meta): aim, capture, confirm, guess and see the result on the lens without touching the phone.

## 7. Tech stack

| Part | Choice |
| --- | --- |
| Server | Python 3.12, uv, FastAPI, uvicorn, httpx, pandas, Pillow, python-dotenv |
| LLM / vision | Nemotron 3.5 Super VL via OpenAI-compatible API, `base_url=https://integrate.api.nvidia.com/v1`, model from `NEMOTRON_MODEL` |
| Web data | `context.dev` Python SDK |
| iOS | Swift, Xcode 26.4+, iOS 17.2+, Meta Wearables DAT (camera, display, inputs), Apple Vision, on-device speech synthesis |
| Tunnel | cloudflared (`cloudflared tunnel --url http://localhost:8000`) |

### Environment variables (`.env`)
```
NVIDIA_API_KEY=
NEMOTRON_MODEL=          # exact ID from build.nvidia.com
CONTEXT_DEV_API_KEY=
```

## 8. Repo layout

```
.
├── README.md            # setup and run instructions, what works today
├── CLAUDE.md            # this file (design, rules, standing procedures)
├── LICENSE, NOTICE      # MIT for our code; third-party material
├── .env.example         # the keys the server needs; copy to .env (git-ignored)
├── scripts/run-on-phone.sh   # server + tunnel + build + install + launch on an iPhone
├── server/
│   ├── main.py          # FastAPI app: /look /confirm /guess /money/* /coach /health
│   ├── nemotron.py      # client: cache, retries, backoff
│   ├── see.py           # identification (Nemotron vision)
│   ├── price.py         # car prices (Context.dev listings)
│   ├── products.py      # prices for headphones, phones, laptops and any other item
│   ├── looks.py, score.py   # look store and price jobs; guess scoring
│   ├── money.py         # baskets, spare money, what-if, what a price means (S-Pankki data)
│   ├── coach.py         # Nemotron explains the computed numbers
│   ├── tests/           # pytest, no network
│   └── scripts/         # smoke tests, build_money_profiles.py
├── ios-app/             # Swift app: Look/, Coach/, Glasses/ (lens HUD), Views/ (based on Meta DAT samples)
├── design/glasses/      # lens art, HUD_ASSETS.md, process_assets.py
├── data/                # S-Pankki data and the tables built from it (git-ignored)
├── cache/, .run/        # API response cache; run-on-phone logs (git-ignored)
└── docs/                # GLASSES_SESSION.md, spankki_data.md (meta repo clones git-ignored)
```

## 9. Commands

```bash
# server
cd server && uv run uvicorn main:app --reload --port 8000
# tunnel (keep open; URL changes on restart → update ios-app Config.swift)
cloudflared tunnel --url http://localhost:8000
# tests (see README for the live ones)
cd server && uv run pytest
# a real iPhone: server + tunnel + build + install + launch
scripts/run-on-phone.sh
```

## 10. Reference links

- Meta wearables docs: https://wearables.developer.meta.com
- DAT getting started: https://wearables.developer.meta.com/docs/develop/dat/getting-started-toolkit
- Repo: https://github.com/facebook/meta-wearables-dat-ios
- Context.dev docs: https://docs.context.dev
- NVIDIA Build: https://build.nvidia.com

---

## 11. Standing procedures

### "Run it on the phone" (also: "re-run the app", "install it on my phone")

The user means the real iPhone with the glasses features, talking to the server on this Mac. Do exactly this, in this order,
and report each outcome plainly (README section 3 describes the same steps for humans):

1. **Run `scripts/run-on-phone.sh`.** It: checks the tools and the three required keys in `.env` (never print key values);
   finds the connected iPhone; starts the server on port 8000 or reuses a running one; starts a cloudflared quick tunnel and waits
   until the tunnel address really answers `/health` (error 1033 for the first seconds is normal); writes the address into the
   `SERVER_URL` line of `ios-app/PriceSense/Config.swift`; builds for the phone with `-allowProvisioningUpdates`; installs
   with `xcrun devicectl device install app`; launches with `devicectl device process launch --terminate-existing`
   (retrying, the first launch after an install sometimes only acquires the device). About a minute.
2. **If the phone is not connected or is locked** (`xcrun devicectl list devices` says `unavailable`), say so and ask the user to
   plug it in and unlock it; do not loop or retry in the background. If the build fails on signing, the user's team or bundle id
   differs from the project's: use `--team` / `--bundle-id`, or `--free-team` for a Personal Team (see README, Signing).
3. **Before saying it is running**, confirm the server answers locally and through the tunnel (the script does; if you ran the
   steps by hand, do both `curl`s) and that the launch printed "Launched application".
4. **Tell the user** which address the phone uses, that it changes whenever the tunnel restarts, that the phone only works while
   this Mac is awake with the server and tunnel up, and what is new to try in this build.
5. **Never leave the tunnel address in a commit.** `Config.swift` is modified by the script on purpose. Before any commit run
   `scripts/run-on-phone.sh --stop` (stops the server and tunnel it started, puts only the `SERVER_URL` line back to
   `http://localhost:8000`; other edits to `Config.swift` stay). If the user is still using the phone, ask first: stopping the tunnel
   cuts the app off. `.run/` (logs, pids, derived data) is git-ignored.
6. Old tunnels started by hand (`pgrep -x cloudflared`) may still be running: stop the ones the script did not start (they are
   not in `.run/tunnel.pid`).

Related: the simulator run (`localhost:8000`, no tunnel) and the test commands are in README sections 3 and 5. iOS tests that
go live need the server running; the glasses mock tests need `TEST_RUNNER_HUD_CAR_VIDEO` (HEVC, 540x960).

