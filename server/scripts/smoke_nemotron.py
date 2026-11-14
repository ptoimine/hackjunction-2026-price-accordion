"""Smoke test for the Nemotron client: one text prompt, one image prompt.

Run from server/:
    uv run python scripts/smoke_nemotron.py
    uv run python scripts/smoke_nemotron.py path/to/photo.jpg --no-cache

Without --image a small synthetic picture (a red car-like shape, no people) is
generated, so nothing personal is sent to NVIDIA's hosted API.
"""

import argparse
import asyncio
import io
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from PIL import Image, ImageDraw  # noqa: E402

from nemotron import NemotronClient, NemotronError  # noqa: E402


def synthetic_image() -> bytes:
    img = Image.new("RGB", (512, 320), (180, 215, 245))
    d = ImageDraw.Draw(img)
    d.rectangle((0, 230, 512, 320), fill=(90, 90, 95))  # road
    d.rounded_rectangle((70, 150, 440, 240), radius=24, fill=(200, 30, 35))  # body
    d.polygon([(140, 150), (190, 95), (330, 95), (385, 150)], fill=(200, 30, 35))  # cabin
    d.polygon([(158, 150), (198, 105), (255, 105), (255, 150)], fill=(190, 225, 245))
    d.polygon([(265, 150), (265, 105), (322, 105), (366, 150)], fill=(190, 225, 245))
    for cx in (140, 370):
        d.ellipse((cx - 38, 205, cx + 38, 281), fill=(25, 25, 25))
        d.ellipse((cx - 16, 227, cx + 16, 259), fill=(170, 170, 175))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=90)
    return buf.getvalue()


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("image", nargs="?", type=Path, help="JPEG/PNG to send (default: synthetic picture)")
    parser.add_argument("--image", dest="image_opt", type=Path, help="same as the positional argument")
    parser.add_argument("--no-cache", action="store_true", help="bypass the disk cache")
    args = parser.parse_args()
    args.image = args.image_opt or args.image

    if args.image and not args.image.is_file():
        print(f"image not found: {args.image}", file=sys.stderr)
        return 2
    image = args.image.read_bytes() if args.image else synthetic_image()
    mime = "image/png" if args.image and args.image.suffix.lower() == ".png" else "image/jpeg"

    try:
        client = NemotronClient()
    except NemotronError as exc:
        print(f"config error: {exc}", file=sys.stderr)
        return 2

    failures = 0
    try:
        tests = [
            ("text", dict(prompt="In one sentence: why is guessing a price before seeing it a good way to learn money sense?")),
            ("image", dict(prompt="What is in this picture? Answer in one short sentence.", image=image, image_mime=mime)),
        ]
        for name, kwargs in tests:
            print(f"--- {name} (model={client.model}) ---")
            try:
                reply = await client.chat(**kwargs, use_cache=not args.no_cache)
            except NemotronError as exc:
                failures += 1
                print(f"FAILED: {type(exc).__name__}: {exc}\n")
                continue
            print(reply.text)
            print(f"[cached={reply.cached} attempts={reply.attempts} latency={reply.latency_s:.1f}s]\n")
    finally:
        await client.aclose()
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
