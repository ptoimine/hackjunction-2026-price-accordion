# Ray-Ban Display session: checklist (2 hours, one slot)

Everything below is built and passes on Meta's mock Ray-Ban Display (46 iOS tests, including the whole lesson
capture → confirm → dial → lock → accordion). **Nothing has touched real glasses yet**: the first 15 minutes
should answer the open questions in section 3 before anything else is tuned.

## 1. Before putting them on (5 min)

1. Server: `cd server && uv run uvicorn main:app --port 8000`, tunnel: `cloudflared tunnel --url http://localhost:8000`,
   put the tunnel URL in `ios-app/PriceSense/Config.swift` (`SERVER_URL`), build and install on the iPhone.
2. Meta AI app on the iPhone: version for DAT 1.0.x (V290 or later), glasses firmware V128 or later,
   Developer Mode on (Settings → App Info → tap the version 5 times), **local network allowed for Meta AI** and for
   Price Sense. The DAT app must be installed on the glasses (the install button in Meta AI, glasses ON and worn,
   Wi-Fi prompt on iOS, ~10 s). The Display capability needs this; a "DAT app needs an update" error means update it there.
3. Neural Band paired and worn. Battery of glasses and band above 50 %.
4. Put the glasses on (the session only starts when they are worn).

## 2. Run order

1. Open Price Sense → camera screen → **eyeglasses icon** (top right) opens the **Glasses lab**.
2. **Start session + display + inputs + camera.** The chips on the camera screen should turn: Session started,
   Display ready, Inputs active, Stream streaming. The HUD flow starts by itself when the display is ready.
3. In the lab: **Test pattern** first (see 3a), then the other test screens, then put the lab away and run the flow:
   press the capture button → reticle locks → "Is this a …?" → Select → dial the guess → Select → watch the squeeze.

## 3. What only the real glasses can answer (note the answers; the knobs are in brackets)

| # | Question | Where to see it | If the answer is bad |
|---|----------|-----------------|----------------------|
| a | Is the whole 600 x 600 picture visible, uncropped, and is the black really transparent? | Lab → Test pattern: all four white edges and TL/TR/BL/BR labels | `HUDRenderer` margins; the reticle is at (44,44,512,512) |
| b | Does `Image(.fill)` fill the lens, or letterbox? | Same screen | Lab toggle **Image size .icon instead of .fill** |
| c | How fast can screens be sent? Is the 8-frame blink / squeeze smooth? | Lab → **Animation speed test**: delivered fps, dropped, avg ms | `GlassesFlow.tick` interval (100 ms), `GlassesDisplay` coalescing, fewer frames per clip |
| d | Which physical gesture is which event? (tap, double tap, swipe, pinch, capture short/hold/double, action button) | Lab → **Input events** list, live | `GlassesRig.route` maps events to commands |
| e | Neural Band drag: what are `dx` and `x` (pixels or normalised), how far is a comfortable drag? | Lab → "Last drag" line while pinching and dragging | `GlassesFlow.drag(dx:)` guesses the scale from magnitude; fix the two constants (0.003 / 0.5) |
| f | Do the native components (Text, Buttons) look better than our image screens, does touchpad focus work? | Lab → **Native components** (taps listed under the button) | We keep the image screens unless native is clearly better |
| g | Does the camera stream keep running while the display session is up? Does a lens tap or capture press pause the stream? | Camera chip "Stream"; press the capture button | `CameraViewModel` auto-starts the stream |
| h | Where does the camera crop sit relative to the reticle? (the camera is at the temple, the lens is in the right eye) | Lab → **Aim calibration**: aim the reticle at a target at your usual distance, freeze the frame, **tap the spot the reticle was on**; the yellow crop window jumps there and is saved (distance matters: parallax). Default crop is the centre 70 %; the Size slider below it widens or narrows it | `HUDCalibration` (also used by the phone flow) |
| h2 | Is a standalone photo better than a stream frame? (wider view, sharper, no stabilisation; takes seconds; the stream is off in photo mode) | Lab → **Where the picture comes from** → Standalone photo, pick a resolution (small, medium, large, full), **Take a test photo**: the last-photo line shows seconds and pixels. Calibrate each source separately in **Aim calibration**. Then run the flow: capture button → photo → look | `CaptureSource` / `CameraViewModel.captureForLook` |
| i | Does the display sleep (20 s dim, 25 s sleep) and come back with the right screen? | Leave it alone, then press something | `GlassesDisplay.readyEpoch` re-sends the screen |
| j | Does the spoken answer come out of the glasses' speakers? | Lab → **Speak a sample answer**; then run the flow | `HUDVoice` (on-device speech) |

## 4. Controls on the lens (defaults; change after (d) is known)

| Input | aim | confirm | guess | accordion / error |
|-------|-----|---------|-------|-------------------|
| Tap on the temple (Select), capture short press, lens tap | **look** | **yes** | **lock in** | look again |
| Any swipe on the temple | | **try again** | big / small steps (up down / left right) | **look again** |
| The back swipe, twice within 0.8 s | | | **back to aiming** | |
| Capture hold, action button | | try again | try again | |
| Band Drag | | | turns the dial on a log scale | |

**Back on the temple:** a two-finger tap is the system's Back and ends the whole display session, and real glasses do not
send our app a Back event yet, so back is a swipe. The back swipe defaults to "down"; swipe directions can be inverted by
the wearer's settings, so in the lab (**Back gesture on the temple**) press *Learn* and make the gesture you find natural.
A one-finger tap and hold also stops the session when no interactive content is shown: do not use it.

Presses within 350 ms of each other count once (a tap can arrive as both Select and a lens tap).

## 5. Good things to capture while you have them

Screen recording of the lens through the phone is not possible; use the Meta AI app's recording or a second
person's phone video. For the deck: aim screen, "Is this a …?", the dial, the squeeze, the verdict. Record the
Neural Band gesture too. Note the measured send speed and the input table for the Meta submission text.

## 6. If something does not come up

- **Display "failed: addDisplay"**: the glasses are not Display glasses, or the DAT app on them is outdated.
- **Inputs "failed" / never active**: Inputs is beta and only exists in the dev release channel; the lens tap
  (touchpad) still works through the display itself.
- **Stream "waiting for device"**: same Wi-Fi / local-network / hotspot checklist as the Gen 2 session.
- The phone flow (Look button) works whatever the glasses do.
