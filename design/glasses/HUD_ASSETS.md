# 8-bit arcade HUD assets for Meta Ray-Ban Display

This document describes the image assets (the generated art, kept renamed in `design/glasses/originals/`; it came as a zip with the truncated names listed below): what each file is, how to clean it, and where it goes in the UI. `process_assets.py` does the clean-up described in section 3 and writes the app's frames.

All art was generated with Retro Diffusion in an 8-bit arcade style. The target is the in-lens display of **Meta Ray-Ban Display** glasses, driven from a phone app through the **Meta Wearables Device Access Toolkit (DAT)** display capability.

---

## 1. Target display: facts that shape everything

| Property | Value |
|---|---|
| Canvas | 600 × 600 px, monocular (right lens), ~20° field of view, ~42 px per degree |
| Refresh | 90 Hz panel, ~30 Hz content |
| Rendering model | Additive waveguide: **pure black `#000000` = transparent** (the user sees the real world through it). Every non-black pixel emits light. |
| Content delivery | Phone app → glasses over Bluetooth. Each `send()` / `sendContent()` **replaces the whole screen**; there are no partial updates. |
| Components | FlexBox, Text, Image (from URL), Button, Icon, Video |
| Video component | **MP4 only**, from an **https URL**, **max 400 px per side and max 70,000 total pixels**, **one video at a time** per session |
| Camera stream to the app | 720×1280 / 504×896 / 360×640; 2, 7, 15, 24 or 30 fps |

Consequences:
- Any dark-grey haze or dark border in an asset shows up as a faint glowing rectangle, so everything must be cleaned to true black (section 3).
- Animations cannot be streamed frame-by-frame over Bluetooth. **Each animation is delivered as a short MP4** played by the Video component.
- Images and videos are loaded from URLs, so the processed assets must be hosted (https).
- Before building, check the current DAT docs for whether a Video can be **layered over** an Image (absolute positioning / z-stack). The documented layout system is FlexBox, which places children side by side, not on top of each other. Section 5 includes a fallback for when layering isn't possible.

---

## 2. Asset inventory

The file names in the zip are truncated with a literal `...`. Rename them to the names in the left column. Animated assets come in pairs: a `-0.gif` (8 frames, 150 ms each, looping) and a `-1.png` sprite sheet of the same 8 frames (4 columns × 2 rows, read left→right, top→bottom). Use either one to extract frames, but check that the sheet order matches the GIF.

### Used assets

| New name | Original file | Size | What it is | Used for |
|---|---|---|---|---|
| `reticle_main.png` | `8_bit_arcade_game_ta...-607252072-0.png` | 128×128 | Main targeting overlay: magenta/cyan corner brackets at the edges, cyan crosshair with a centre gap | Always-on base layer (aimpoint) |
| `brackets_base.png` | `8_bit_arcade_style_f...-478341533-0.png` | 64×64 | Four yellow L-brackets with a centre dot. **Has an 8 px grey border.** | Static crop-zone marker; first frame of the bracket animations |
| `brackets_idle_blink` (.gif + sheet) | `brackets_blink_on_an...-1142282831-0.gif` / `-1.png` | 64×64 ×8 | Yellow brackets blinking on and off. **8 px grey border.** | IDLE state loop |
| `brackets_lockon` (.gif + sheet) | `corner_brackets_jump...-2035052563-0.gif` / `-1.png` | 64×64 ×8 | Brackets step inward and flash white. **8 px grey border.** | LOCK state (play once, hold last frame) |
| `capture_frame_base.png` | `8_bit_arcade_small_s...-1899263131-0.png` | 64×64 | Cyan square picture frame with white corners | First frame of the success animation |
| `capture_success_fly` (.gif + sheet) | `frame_shrinks_in_ste...-922775017-0.gif` / `-1.png` | 64×64 ×8 | The frame shrinks in steps, leaves pixel debris, and disappears. **Has real alpha transparency, not a black background.** | SUCCESS state (the chosen design: "fly to inventory") |
| `coin_base.png` | `8_bit_arcade_spinnin...-1505616123-0.png` | 32×32 | Gold star coin | Base frame for the spinner |
| `loading_coin_spin` (.gif + sheet) | `coin_spins_in_place_...-1696542234-0.gif` / `-1.png` | 32×32 ×8 | Coin spinning, including an edge-on frame. **Preferred.** | PROCESSING state loop |
| `loading_coin_spin_alt` (.gif + sheet) | `coin_spins_in_place_...-1134448828-0.gif` / `-1.png` | 32×32 ×8 | Alternative spin (less edge-on, includes a flat-disc frame) | Backup only |
| `icon_camera.png` | `8_bit_arcade_game_ic...-1083876033-0.png` | 32×32 | Camera icon: cyan outline, dark-grey body | Status strip: "camera stream active" |
| `screen_border.png` | `8_bit_arcade_game_sc...-1156975705-0.png` | 32×32 | Cyan screen-edge frame with corner ornaments | **Optional.** See notes |

### Not used (kept for reference)

| Original file | What it is | Why not used |
|---|---|---|
| `8_bit_arcade_explosi...-780307101-0.png` | Explosion base (8 px grey border) | The designer chose "fly to inventory" for capture success instead |
| `burst_expands_outwar...-1952601622-0.gif` / `-1.png` | Explosion animation | Same reason |

---

## 3. Cleanup pipeline (do this before anything else)

Use Python + Pillow for the image work and ffmpeg for video. Keep the originals untouched and write the results to `assets/processed/`.

1. **Flatten onto black.** Composite every frame (RGBA) over an opaque `#000000` background. This matters most for `capture_success_fly`, which has real transparency. Output RGB.
2. **Remove the grey border.** In `brackets_base`, `brackets_idle_blink`, `brackets_lockon` (and the unused explosion files), the outer **8 px of every 64×64 frame** is grey (about RGB 103,103,102, or 69,79,88 on the explosion). Paint that 8 px ring black on every frame and keep the 64×64 size. In the sprite sheets, apply this per 64×64 tile.
3. **Crush near-black to true black.** Any pixel with `max(R,G,B) < 40` becomes `#000000`. This removes the faint navy scanline haze in `reticle_main.png` and the near-black noise (RGB 0–10) in every file. Afterwards, check that the background really is exactly `#000000`.
4. **Scale with nearest-neighbour by a whole number only** (never bilinear, never a fractional factor):
   - `reticle_main`: 128 → **×4 = 512**
   - bracket assets and `capture_*`: 64 → **×4 = 256**
   - coin spinner and `icon_camera`: 32 → **×1 (32)** in the status strip. ×2 (64) is possible if the margins are increased.
5. **Retime the animations.** The generated GIFs are 8 frames × 150 ms = 1.2 s, which is too slow for feedback events:
   | Animation | Frame time | Total | Loop |
   |---|---|---|---|
   | `brackets_idle_blink` | 150 ms | 1.2 s | yes |
   | `brackets_lockon` | 60 ms | ~0.5 s | no, hold the last frame |
   | `capture_success_fly` | 60 ms | ~0.5 s | no, end on black |
   | `loading_coin_spin` | 100 ms | 0.8 s | yes |
6. **Encode to MP4** (H.264, `yuv420p`, even dimensions), e.g.:
   ```
   ffmpeg -framerate 16.67 -i frame_%02d.png -c:v libx264 -preset veryfast -crf 12 -pix_fmt yuv420p -movflags +faststart brackets_lockon.mp4
   ```
   For a 60 ms frame time use `-framerate 16.67`; for 100 ms use `10`; for 150 ms use `6.67`. For looping videos, check whether the DAT Video component has a loop option. If it doesn't, concatenate several cycles into the file.
7. **Check the Video limits:** ≤400 px per side and ≤70,000 total pixels. 256×256 = 65,536 passes. The 512 reticle is **not** a video; it's a static Image.
8. **Verify** by decoding the first frame of each MP4 and confirming that its corners are `#000000` (YUV encoding can lift black slightly; if it does, fix the encode range).

---

## 4. Screen layout (600 × 600)

Coordinates are top-left origin, in display pixels.

| Element | Asset | Size on screen | Position |
|---|---|---|---|
| Aimpoint / main reticle | `reticle_main` ×4 | 512×512 | (44, 44), so its centre is the screen centre (300, 300) |
| Crop-zone brackets | `brackets_*` ×4 | 256×256 | (172, 172), centred on (300, 300) |
| Camera-active icon | `icon_camera` ×1 | 32×32 | top-left margin, ~(6, 6) |
| Processing spinner / "inventory" slot | `loading_coin_spin` ×1 | 32×32 | top-right margin, ~(562, 6) |
| Capture success | `capture_success_fly` ×4 | 256×256 | starts at (172, 172), over the crop zone |

**Crop region.** The image the app crops from the camera stream is defined by the yellow brackets. After cleanup, measure the outer extent of the bracket pixels in the 256×256 version and convert it to display coordinates. That rectangle, mapped into the camera frame, is the crop.

**Calibration (required).** The camera sits at the corner of the frame and sees a much wider view than the display's ~20°. The display centre (300, 300) does **not** automatically correspond to the centre of the camera image. Build a calibration step: the user aims the reticle at a high-contrast target, the app finds the target in the camera frame, and stores the offset and scale. Parallax means the offset changes with distance, so calibrate at the typical working distance (or store several distances).

**Text.** Don't use generated text. Render labels such as `READY`, `LOCK` and `SAVED x3` with the Text component (a pixel font if the SDK allows custom fonts; otherwise the built-in styles). Keep them inside the top or bottom margin, not across the crop zone.

**`icon_camera` note.** Its body is dark grey, which will look very dim or invisible on the glasses, so only the cyan outline will really show. That's acceptable. Optionally, recolour the body to black during cleanup so it's a clean outline.

**`screen_border` note (optional).** It's 32×32 with lines about 2 px thick. Scaling the whole thing up to the screen size would make lines that are far too thick. If you use it, nine-slice it: keep the 4 corners at ×2 to ×4 and tile or stretch the edge segments. Keep it out of the centre: the view is only ~20° wide.

---

## 5. States and which asset plays when

```
IDLE ──(target held steady / user pinch)──▶ LOCK ──▶ CAPTURING ──(frame saved)──▶ SUCCESS ──▶ IDLE
```

| State | Static layers | Video (only one at a time) | Notes |
|---|---|---|---|
| IDLE | `reticle_main`, `icon_camera` | `brackets_idle_blink` (loop) | Default view |
| LOCK | `reticle_main`, `icon_camera` | `brackets_lockon` (once, hold last frame) | Triggered by the user's capture input |
| CAPTURING | `reticle_main`, `brackets_base` | `loading_coin_spin` (loop, top-right) | While the frame is grabbed, cropped and processed on the phone |
| SUCCESS | `reticle_main`, `brackets_base` | `capture_success_fly` (once) | Then return to IDLE |

Each state change is one full `send()` of the whole layout.

**Making "fly to inventory" read clearly.** The generated frames mostly shrink in place and only drift slightly. To make the frame visibly travel toward the inventory slot (top-right, where the coin lives), use one of these:
- (a) If the layout allows absolute positioning, place the video so it ends near the top-right slot.
- (b) Composite a wider video in which each frame's sprite is shifted progressively toward the top-right. A **400×175 canvas** is exactly 70,000 px, the largest allowed. Keep the sprite at ×2 or ×3 so the movement fits.
- (c) Simplest: play it in place over the crop zone, then show the coin slot briefly flashing (one extra `send()` with the coin highlighted).

**If a Video cannot be layered over an Image:**
- In animated states, drop `reticle_main` and show only the 256×256 bracket/capture video centred on black. The bracket centre dot still marks the aimpoint.
- Alternatively, bake a scaled-down reticle into the video frames. A 256×256 video can't hold the full 512 reticle, so this works only for the inner part.

---

## 6. Design rules to keep when adding more assets

- Pure black background; bright colours only (cyan, magenta, yellow, lime, white). Dark colours disappear on the display.
- Outlines, not filled panels. Filled areas wash out the real-world view.
- Whole-number nearest-neighbour scaling only.
- Keep the centre clear except for the aimpoint. Feedback animations should be under ~0.5 s.
- Each animation is one MP4, ≤400 px per side, ≤70,000 px, one playing at a time.
