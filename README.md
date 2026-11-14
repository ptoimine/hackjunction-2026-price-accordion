# Price Accordion – Hintahaitari

Look at anything, guess its price, and watch the accordion squeeze to the real price range. Then see what that price
means for *your* money. A Junction 2026 hackathon project: an iPhone app (works with the phone camera, and with Meta
Ray-Ban glasses incl. the Display model) plus a small Python server.

```
iPhone app (Swift)  ──HTTPS──▶  server/ (Python, FastAPI)
  camera / Meta glasses            ├─ see:   Nemotron (vision) identifies what is in the photo
  blurs faces, crops on device     ├─ price: Context.dev reads live Finnish shop and dealer pages
  guess · accordion · coach        ├─ money: S-Pankki synthetic data → baskets, spare money (plain Python)
                                   └─ coach: Nemotron explains the computed numbers
```

`CLAUDE.md` is the design document (decisions, rules, endpoints). This file is how to set it up and run it.

## What it does

Built and tested (116 server tests, the iOS suite, and a session on real Meta Ray-Ban Display glasses):
look at anything → Nemotron identifies it → you confirm or correct it → you **guess its price first** → live prices from
Finnish shops and dealers (Context.dev) squeeze the accordion to the real range → the **Coach** puts the price into a
synthetic S-Pankki customer's three baskets and spare money, answers questions (Nemotron explains numbers Python computed),
and the **Score** screen tracks how close your guesses are. Prices work for cars, headphones, phones and laptops (new and used),
and any other thing with a shop price as a rough estimate. On the Meta Ray-Ban Display the same flow runs hands-free on the
lens (aim reticle, capture, confirm, guess dial, accordion) with the touchpad, Neural Band and capture button; photos can come
from the stream or from standalone photo capture.

## Requirements

| What | Why | Notes |
| --- | --- | --- |
| Mac with **Xcode 26.4+** | builds the iPhone app | tested with Xcode 26.5 |
| **iPhone**, iOS 17.2+ | runs the app | a simulator works for everything except real glasses |
| **uv** and Python 3.11+ | the server | `brew install uv` (uv installs Python for you) |
| **cloudflared** | lets the phone reach the server on your Mac | `brew install cloudflared`; no account needed |
| **NVIDIA Build API key** + model id | Nemotron: identifies things, explains the numbers | https://build.nvidia.com |
| **Context.dev API key** | live prices | https://docs.context.dev (about 5 credits per page read, ~30 per lookup) |
| Apple Developer team | signs the app for a real iPhone | **paid** team for the glasses' camera stream; a free Personal Team works for everything else (see Signing) |
| S-Pankki challenge data | the Coach screen | optional, see Money data |
| Meta Ray-Ban glasses, Meta AI app | glasses features | optional, see Glasses. Without glasses the phone camera and Meta's Mock Device Kit work |

## 1. Set up

```bash
git clone https://github.com/<you>/hackjunction2026-price-accordion.git && cd hackjunction2026-price-accordion
cp .env.example .env          # then fill in the keys; .env is git-ignored, never commit it
cd server && uv sync          # installs the Python dependencies
uv run pytest                 # 116 tests, no network, no credits
```

Check the keys work (each makes one real call):

```bash
cd server
uv run python scripts/smoke_nemotron.py                       # text + a generated picture, nothing personal is sent
uv run python scripts/smoke_contextdev.py
```

### Money data (for the Coach screen)

The coach uses the synthetic S-Pankki dataset from the Junction 2026 challenge
(https://github.com/hackjunction/Junction-2026-S-pankki, the transactions file is stored with Git LFS: download it
with the *Download raw file* button or `git lfs pull`, a few-line file means you got only the pointer). Put the four CSVs in
`data/spankki/` (create the folder; it is git-ignored), then boil the 346 MB transactions file down to two small tables:

```bash
cd server && uv run python scripts/build_money_profiles.py     # ~20 s, writes data/spankki/monthly.csv + customers.csv
```

Without this the app still works; the Coach screen just says the money data is not built. Check the dataset's terms before
sharing the derived tables; they are git-ignored on purpose.

## 2. Run the server

```bash
cd server && uv run uvicorn main:app --port 8000
curl localhost:8000/health        # {"status":"ok","nemotron_configured":true,"context_dev_configured":true}
```

## 3. Run the app

### On the simulator

Open `ios-app/PriceSense.xcodeproj`, pick an iPhone simulator, Run. `SERVER_URL` in
`ios-app/PriceSense/Config.swift` is `http://localhost:8000`, which reaches your Mac. There is no camera in the simulator:
tap the **ladybug** button → *Enable MockDeviceKit* → *Pair Ray-Ban Meta* (power, donned, unfolded) → pick a video file as
the camera source (`xcrun simctl addmedia booted <video.mp4>` adds one; Meta's sample is
`ios-app/PriceSense/TestResources/plant.mp4`, which identifies as "nothing to price": use a car or a product video, see
`ios-app/README.md`). Then **Start session → Preview → Look**. The ladybug menu also has the Accordion playground and the
Coach and Score previews, which need no server.

### On a real iPhone: one command

```bash
scripts/run-on-phone.sh
```

Plug the iPhone in with a cable, unlock it and tap *Trust this computer* the first time. The script does what you would
otherwise do by hand, and stops with a clear message at the first thing that is wrong:

1. checks the tools (uv, Xcode, cloudflared), that `.env` has the three required keys, and warns if the money data is missing;
2. finds the connected iPhone (`xcrun devicectl list devices`);
3. starts the server on port 8000, or reuses it if it already answers `/health`;
4. starts a Cloudflare quick tunnel to it (`cloudflared tunnel --url http://localhost:8000`), waits until it is registered
   **and** the new address really answers (right after it registers it shows error 1033 for a few seconds);
5. writes that address into `SERVER_URL` in `Config.swift` (only that one line);
6. builds the app for the phone with `xcodebuild ... -allowProvisioningUpdates`;
7. installs it (`xcrun devicectl device install app`) and launches it (`devicectl device process launch`);
8. prints the address and where the logs are (`.run/`, git-ignored).

It takes about a minute when nothing needs downloading. Options: `--team <id>` and `--bundle-id <id>` (sign with your own team;
change the bundle id if Apple says it is taken), `--free-team` (see Signing), `--device <id>`, `--tunnel-url <https url>` (use
your own address instead of a quick tunnel), `--no-build`. `scripts/run-on-phone.sh --help` lists them.

The tunnel address changes every time the tunnel restarts, and the phone only works while your Mac is awake with the server
and tunnel running. To stop everything and put `SERVER_URL` back to localhost (**do this before committing**):

```bash
scripts/run-on-phone.sh --stop
```

The first time you install your own build, iOS may say the developer is not trusted: iPhone *Settings → General → VPN & Device
Management →* your developer certificate → Trust. Allow **Local Network** for Price Sense (and Meta AI) when asked.

### Signing

Open the project in Xcode once and pick your team under *Signing & Capabilities* (or pass `--team` to the script). The
project currently has the original developer's team id and bundle id (`fi.pekkatoiminen.pricesense`), which will not work for
you: change both.

- **Paid team:** everything works, including the glasses' camera stream, which needs the `HotspotConfiguration` and
  `wifi-info` entitlements (`PriceSense.entitlements`, the default).
- **Free Personal Team:** Apple refuses those two entitlements ("Personal development teams do not support the Hotspot and
  Access Wi-Fi Information capabilities"). Build with `--free-team` (or set *Code Signing Entitlements* to
  `PriceSense/PriceSense.freeteam.entitlements`). The look → guess → accordion → coach flow, the mock glasses and the lens HUD
  work; the real glasses' video stream does not start.

Never build with `CODE_SIGNING_ALLOWED=NO`: without entitlements the Meta SDK traps at launch. For simulator test builds use
`CODE_SIGN_IDENTITY=-`.

## 4. Glasses (optional)

The app works with the phone camera alone. With Meta glasses (Ray-Ban Meta Gen 2: camera, microphone, speakers; Meta Ray-Ban
Display: plus the lens and the Neural Band) you also need: the Meta AI app and glasses firmware at (or above) the versions Meta lists for the pinned SDK 1.0.1 (https://wearables.developer.meta.com/docs/develop/dat/version-dependencies), with the glasses paired, *Developer
Mode* on (Meta AI → Settings → App Info → tap the version 5 times), the DAT app installed on the glasses from there (glasses
on and worn, Meta AI in the foreground), **Local Network** allowed for Meta AI and Price Sense, and a paid signing team.
Display glasses: tap the eyeglasses icon in the app for the **Glasses lab**, and read `docs/GLASSES_SESSION.md` (checklist,
gestures, what to measure). Setup problems: `ios-app/README.md`. The lens art: `design/glasses/` (`process_assets.py`).

## 5. Tests

```bash
cd server && uv run pytest                                            # server, no network
cd ios-app && xcodebuild test -project PriceSense.xcodeproj -scheme PriceSense \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGN_IDENTITY=- \
  -only-testing:PriceSenseTests -parallel-testing-enabled NO
```

With the server running, the iOS tests also run live end to end (look → guess → price → coach; this spends a few Context.dev
credits and one Nemotron call per test run, results are cached 30 minutes). They need a photo of a car, which the repository does
not include: pass one with `TEST_RUNNER_PRICE_TEST_PHOTO=/path/to/photo.jpg`. Without the server or the photo those tests skip.
The whole-lesson-on-mock-glasses tests need a car video: `TEST_RUNNER_HUD_CAR_VIDEO=/path/car.mp4` (HEVC, 540x960; make one with
`ffmpeg ... -c:v hevc_videotoolbox -tag:v hvc1`), `TEST_RUNNER_HUD_OUT=/some/dir` makes the tests write the rendered lens
screens as PNGs.

## 6. Should I host it?

- **The phone app** is native, so it is not something to host like a website. To put it on other people's phones use
  TestFlight (needs the paid Apple Developer account). Note: the glasses' lens inputs and standalone photos are Meta beta
  features that only work on glasses in developer mode, and Meta says apps using them cannot be published yet.
- **The server** is the only part that can be hosted, and for a demo you do not need to: the tunnel above is enough. Its limits
  are that your Mac must stay awake and the address changes. If you want it always on:
  - *Stable address, Mac still needed:* a named Cloudflare tunnel (free, needs a domain on Cloudflare).
  - *Really hosted* (Fly.io, Render, Railway or any host that runs Python): start command
    `uv run uvicorn main:app --host 0.0.0.0 --port $PORT`; give it the `.env` values as the host's secrets (never in the repo);
    keep **one instance** (looks are kept in memory, so several workers or instances would lose each other's looks); let it
    write to `cache/`; copy only the two small tables `data/spankki/monthly.csv` and `customers.csv` (never the 346 MB file,
    and check the dataset's terms first). Then set `SERVER_URL` to the host's https address and rebuild the app.
  - **Protect it first.** Anyone who has the address can spend your NVIDIA and Context.dev credits; the server has no login yet.
    Add a shared secret header (checked by the server, sent by the app) before putting a public address anywhere.
  - Nothing has been deployed or tested on a host yet; this is the plan, not a tried recipe.

## 7. Troubleshooting

| Symptom | Fix |
| --- | --- |
| App says "Cannot reach the server" | the tunnel address changed or the Mac slept: run `scripts/run-on-phone.sh` again |
| Cloudflare "error 1033" in a browser | the tunnel was started seconds ago; wait, the script waits for it |
| Script: "no connected iPhone" | cable, unlock, tap Trust; `xcrun devicectl list devices` must say `connected` (`unavailable` = locked or unplugged) |
| Build fails with a signing error | use your own `--team` and `--bundle-id`; free team: add `--free-team` |
| Install works but the app will not open | Settings → General → VPN & Device Management → trust your certificate |
| Coach: "the money data is not built" | `cd server && uv run python scripts/build_money_profiles.py` (needs the dataset in `data/spankki/`) |
| `/look` answers 504 "thinking" or 503 | Nemotron is slow or busy; try again, the app shows a friendly message |
| "Something went wrong: Device is not connected" with glasses | `ios-app/README.md` (Wi-Fi, Local Network, paid team) and `docs/GLASSES_SESSION.md` |
| Simulator app crashes at launch | built unsigned: use `CODE_SIGN_IDENTITY=-`, not `CODE_SIGNING_ALLOWED=NO` |

## Privacy and secrets

Faces are blurred and the photo is cropped **on the phone**; only that crop is sent, nothing is stored, and the server keeps
only the identification and price in memory for an hour. Keys live only in `.env` (git-ignored); `data/`, `cache/` and `.run/`
are git-ignored too. Licence plates are not blurred yet. The S-Pankki customers are synthetic, never real people. The coach
is coaching, not financial advice.

## Repository layout

```
LICENSE, NOTICE   MIT for our code; third-party material (Meta's sample code, art, data, services) listed in NOTICE
server/        FastAPI app (main.py), see.py, price.py, products.py, money.py, coach.py, tests/, scripts/
ios-app/       the Swift app: Look/ (flow), Coach/ (money coach, score), Glasses/ (lens HUD), Views/, tests
design/glasses lens art and its clean-up script
docs/          GLASSES_SESSION.md and notes              scripts/run-on-phone.sh   the one-command phone run
CLAUDE.md      design document and rules                 .env.example   the keys the server needs
```

Meta's sample code keeps its licence headers.

## Licence

MIT for our own code and documents (`LICENSE`). Meta's sample-app files keep Meta's terms, and the lens art, the S-Pankki data and the online services have their own: see `NOTICE`.
