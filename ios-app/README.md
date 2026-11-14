# PriceSense (iOS)

Phone app for Price Accordion. Based on Meta's `CameraAccess` sample from the Device
Access Toolkit (DAT), renamed to PriceSense. Meta's code keeps its licence headers.

## What it does today

Camera screen (Mock Device or real glasses) with a **Look** button:

1. take the current frame
2. blur faces (Apple Vision) on the full frame
3. crop the centre 60%
4. JPEG-encode (quality 0.8)
5. `POST {SERVER_URL}/look` with the raw JPEG as the body (`Content-Type: image/jpeg`)
6. the identification comes back at once (the card shows the sent crop and "Honda HR-V · 2016–2022 · 85% sure")
7. **is that it?** "Is this a Sony WH-1000XM5?" with **Yes, that's it** / **No, change it** (kind, brand, model, size or
   years) → `POST /confirm`. The model is often wrong on electronics, and the price depends on the exact model. A correction
   restarts the price lookup. When it could not tell what it is, the card asks "Tell me what it is".
8. **guess first:** "What do you think it costs?" (products: "…in a shop?", the new price) with a number pad;
   **Lock in my guess** sends it to `POST /guess`
9. **the accordion** (`AccordionView`): bellows open wide on the guess, squeeze as the server's sources answer
   (the app polls `GET /look/{id}` every 1.5 s), then the median line, a green guess marker when you landed
   inside the real range, the server's sentence ("You guessed €18,000. The real range is …"), a score and the
   sources line ("6 sites · 35 adverts · fetched 17:33"). Products also show "Used or refurbished: …" as a second line.

Not a car, headphones, phone or laptop? The card says so and asks for no guess. The `{ }` button in the card
header shows the raw server JSON. Every number shown comes from the server (CLAUDE.md rule 2).

Everything up to step 4 happens on the phone; only the blurred crop leaves it
(CLAUDE.md hard rule 1). Licence plates are **not** blurred yet.
If face detection fails, nothing is uploaded.

Code: `PriceSense/Config.swift`, `PriceSense/Look/` (`ImagePrivacy`, `LookClient`, `LookModels`,
`LookViewModel`, `LookFlowView`, `AccordionView`), button in `Views/CameraView.swift`.
VoiceOver reads the accordion as the server's summary sentence and announces it when it arrives.

**Accordion playground (debug builds):** ladybug button → "Accordion playground" plays a recorded lookup
with a guess slider, with no server, camera or Context.dev credits. Handy for tuning the animation.

**A car for the Mock Device:** the sample's plant video identifies as "other". To test with a car, make a
portrait video from a photo and add it to the simulator, then pick it under Camera source → Video file:

```bash
ffmpeg -loop 1 -framerate 24 -i car.jpg -t 12 -vf "scale=720:-2,pad=720:1280:0:(oh-ih)/2:color=0x202020,format=yuv420p" -c:v libx264 car.mp4
xcrun simctl addmedia booted car.mp4
```

Heads-up: with the letterboxed bars the model said "Honda Crosstour" (75%) for a photo it reads as an HR-V
when uncropped, so identification is sensitive to framing. That is why every identification is confirmed by the user.

## Run

> The short way for a real iPhone is `scripts/run-on-phone.sh` from the repository root (README, section 3). What follows is the manual version.

1. Server: `cd server && uv run uvicorn main:app --port 8000`
2. Simulator: `SERVER_URL` in `Config.swift` is `http://localhost:8000`, which reaches the Mac.
   Real iPhone: `cloudflared tunnel --url http://localhost:8000`, paste the printed
   `https://<random>.trycloudflare.com` into `Config.SERVER_URL`.
3. Open `PriceSense.xcodeproj`, run. Without glasses use the ladybug button
   (MockDeviceKit): Enable → Pair Ray-Ban Meta → Power, Donned, Unfolded on →
   Camera source "Video file" (add a video to the simulator with
   `xcrun simctl addmedia booted <file>`; Meta's sample is `PriceSense/TestResources/plant.mp4`).
   Then Start session → Preview → Look.

## Tests

```bash
xcodebuild test -project PriceSense.xcodeproj -scheme PriceSense \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGN_IDENTITY=- -only-testing:PriceSenseTests
```

Do **not** pass `CODE_SIGNING_ALLOWED=NO`: without entitlements the DAT SDK cannot reach
the keychain and the app traps at launch. `LookFlowTests` also sends a Mock Device frame to
the server; it is skipped when no server is running.

## Signing: paid team for the glasses camera, free team for everything else

The glasses' **camera stream runs over Wi-Fi**: the DAT SDK joins the glasses' hotspot with
`NEHotspotConfigurationManager` (and reads the current SSID). That needs two entitlements,
which only a **paid Apple Developer Program team** can sign:

- `com.apple.developer.networking.HotspotConfiguration`
- `com.apple.developer.networking.wifi-info`

`PriceSense/PriceSense.entitlements` (the default) contains both, plus the keychain group.
`Info.plist` already has the other keys streaming needs (`NSLocalNetworkUsageDescription`,
`NSBonjourServices`, Bluetooth, camera, background modes). Also allow **Local Network** for both
Meta AI and PriceSense in iOS Settings.

**With a paid team:** pick it in Xcode → Signing & Capabilities, build and run. If Apple says
the bundle ID is taken, change `PRODUCT_BUNDLE_IDENTIFIER`.

**With a free Personal Team** the default fails with "Personal development teams ... do not
support the Hotspot and Access Wi-Fi Information capabilities". Build with the keychain-only
variant instead; the Mock Device, Look, Bluetooth and audio work, but the glasses' video
stream cannot start ("waiting for device" / "Device is not connected"):

```bash
xcodebuild -project PriceSense.xcodeproj -scheme PriceSense -configuration Debug \
  -destination 'id=<device id>' -allowProvisioningUpdates \
  CODE_SIGN_ENTITLEMENTS=PriceSense/PriceSense.freeteam.entitlements build
```

In Xcode: Build Settings → Code Signing Entitlements → `PriceSense/PriceSense.freeteam.entitlements`
(and set it back to `PriceSense/PriceSense.entitlements` for a paid team). Removing the
Local Network/Bonjour keys from `Info.plist` does not give a Bluetooth-only video path (tried).

## Real glasses: setup problems

- **"The app on your glasses needs an update"** (`datAppOnTheGlassesUpdateRequired`): the DAT app
  is not installed or is outdated on the glasses. The alert has an **Open Meta AI to update**
  button that opens the App connections page. Use the install button next to the glasses there.
- **"Installation failed: WiFi disconnected during transfer"** in Meta AI: the phone joins the
  glasses' Wi-Fi during the install. Fix that worked: iOS Settings → Privacy & Security →
  **Local Network** → allow **Meta AI**. Also: glasses above 10% battery, Meta AI in the
  foreground, no VPN.

## Coach and Score

After the accordion, **What this means for my money** opens the Coach screen (`Coach/CoachView.swift`): which of the three baskets
the price belongs to, how many weeks of everyday leaks it is, how much of the spare money, what cutting leaks by 20 % would free, the
typical month as one bar, and a box to ask the coach anything (Nemotron explains numbers the server computed; it never calculates).
The customers are synthetic (Junction 2026 S-Pankki data); the persona menu switches between a tight, a typical and a comfortable
month. The **chart icon** in the camera top bar opens the Score screen (`Coach/ScoreView.swift`): your price-sense score over time,
kept on the phone. Debug builds: ladybug menu → Coach preview / Score preview show both with sample data and no server.
Server side first time: `cd server && uv run python scripts/build_money_profiles.py` (needs `data/spankki/tx_junction_transactions.csv`).
