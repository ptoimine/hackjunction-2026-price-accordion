"""Clean the generated 8-bit HUD art for the additive Meta Ray-Ban Display (see HUD_ASSETS.md).

    cd server && uv run python ../design/glasses/process_assets.py

Reads the renamed originals in design/glasses/originals and writes ready-to-ship frames into
ios-app/PriceSense/Glasses/HUD: flattened on pure black, grey borders removed, near-black crushed to
#000000, nearest-neighbour scaled by whole numbers. One PNG per frame (the app composes whole
600x600 screens itself).

The art came as a zip with truncated file names (see HUD_ASSETS.md). If you unpack such a zip into
design/glasses/_unzipped the script reads from there instead, refreshes originals/, and also checks
that every sprite sheet matches its GIF frame by frame (that check passed on the original zip).
"""

import glob
import json
import shutil
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "_unzipped"
ORIG = ROOT / "originals"
OUT = ROOT.parent.parent / "ios-app" / "PriceSense" / "Glasses" / "HUD"
CRUSH = 40  # max(R,G,B) below this becomes true black

# new name -> (source glob id, kind, tile, scale, border ring to blank, frame_ms, loops)
ASSETS = {
    "reticle": ("607252072-0", "still", 128, 4, 0, None, False),
    "brackets_base": ("478341533-0", "still", 64, 4, 8, None, False),
    "capture_frame": ("1899263131-0", "still", 64, 4, 0, None, False),
    "coin": ("1505616123-0", "still", 32, 1, 0, None, False),
    "icon_camera": ("1083876033-0", "still", 32, 1, 0, None, False),
    "screen_border": ("1156975705-0", "still", 32, 1, 0, None, False),
    "idle": ("1142282831-1", "sheet", 64, 4, 8, 150, True),
    "lockon": ("2035052563-1", "sheet", 64, 4, 8, 60, False),
    "success": ("922775017-1", "sheet", 64, 4, 0, 60, False),
    "coin_spin": ("1696542234-1", "sheet", 32, 1, 0, 100, True),
    "coin_spin_alt": ("1134448828-1", "sheet", 32, 1, 0, 100, True),
}


def find(pattern):
    hits = glob.glob(str(SRC / f"*{pattern}.png"))
    assert len(hits) == 1, (pattern, hits)
    return Path(hits[0])


def clean(img: Image.Image, tile: int, scale: int, ring: int, name_is_bracket: bool = False) -> Image.Image:
    img = img.convert("RGBA")
    flat = Image.new("RGBA", img.size, (0, 0, 0, 255))
    flat.alpha_composite(img)  # real transparency (capture_success) lands on black
    rgb = flat.convert("RGB")
    px = rgb.load()
    for y in range(tile):
        for x in range(tile):
            r, g, b = px[x, y]
            blank = ring and (x < ring or y < ring or x >= tile - ring or y >= tile - ring)
            grey_haze = max(r, g, b) < 130 and max(r, g, b) - min(r, g, b) <= 14  # dull grey = a glowing smudge on the lens
            if blank or max(r, g, b) < CRUSH or (grey_haze and name_is_bracket):
                px[x, y] = (0, 0, 0)
    return rgb.resize((tile * scale, tile * scale), Image.NEAREST)


def bright_extent(img: Image.Image):
    box = img.convert("L").point(lambda v: 255 if v else 0).getbbox()
    return list(box) if box else None


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    ORIG.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for name, (pid, kind, tile, scale, ring, frame_ms, loops) in ASSETS.items():
        saved = ORIG / f"{name}{'_sheet' if kind == 'sheet' else ''}.png"
        if SRC.exists():
            path = find(pid)
            shutil.copy(path, saved)
        else:
            path = saved
            assert path.exists(), f"missing {path}: put the original art in design/glasses/originals"
        sheet = Image.open(path)
        if kind == "still":
            frames = [clean(sheet, tile, scale, ring, name.startswith('brackets'))]
        else:
            cols = sheet.width // tile
            rows = sheet.height // tile
            frames = []
            for i in range(cols * rows):
                x, y = (i % cols) * tile, (i // cols) * tile
                frames.append(clean(sheet.crop((x, y, x + tile, y + tile)), tile, scale, ring, name in ('idle', 'lockon')))
        for i, frame in enumerate(frames):
            frame.save(OUT / (f"hud_{name}.png" if kind == "still" else f"hud_{name}_{i}.png"))
        corners = [frames[0].getpixel(p) for p in [(0, 0), (frames[0].width - 1, frames[0].height - 1)]]
        manifest[name] = {
            "frames": len(frames),
            "size": frames[0].width,
            "frame_ms": frame_ms,
            "loops": loops,
            "bright_extent": bright_extent(frames[0]),
            "corners_black": all(c == (0, 0, 0) for c in corners),
        }
    # the GIFs are the reference for frame order: check the sheets match them frame by frame
    gifs = [("idle", "1142282831-0"), ("lockon", "2035052563-0"), ("success", "922775017-0"), ("coin_spin", "1696542234-0")]
    for name, gif_id in (gifs if SRC.exists() else []):
        gif = Image.open(glob.glob(str(SRC / f"*{gif_id}.gif"))[0])
        tile, scale, ring = ASSETS[name][2], ASSETS[name][3], ASSETS[name][4]
        same = 0
        for i in range(manifest[name]["frames"]):
            gif.seek(i)
            a = clean(gif.convert("RGBA"), tile, scale, ring, name in ('idle', 'lockon'))
            b = Image.open(OUT / f"hud_{name}_{i}.png")
            same += a.tobytes() == b.tobytes()
        manifest[name]["gif_frames_identical"] = f"{same}/{manifest[name]['frames']}"
    (OUT / "hud_manifest.json").write_text(json.dumps(manifest, indent=2))
    print(json.dumps(manifest, indent=2))

    # contact sheet on mid-grey so the black (= transparent on the glasses) is visible
    names = [n for n in ASSETS if n not in ("coin_spin_alt",)]
    sheet = Image.new("RGB", (8 * 140, len(names) * 140), (60, 60, 70))
    for r, name in enumerate(names):
        for i in range(manifest[name]["frames"]):
            f = Image.open(OUT / (f"hud_{name}.png" if ASSETS[name][1] == "still" else f"hud_{name}_{i}.png"))
            f = f.resize((128, 128), Image.NEAREST) if f.width >= 64 else f.resize((128, 128), Image.NEAREST)
            sheet.paste(f, (i * 140 + 6, r * 140 + 6))
    sheet.save(ROOT / "contact_sheet.png")


if __name__ == "__main__":
    main()
