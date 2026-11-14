"""Smoke test for Context.dev: search used listings, then structured extraction.

Step 1  web.search  -> used listings of one car model in Finland (country=fi)
Step 2  web.scrape  -> format `json` with a JSON Schema, on result pages until one
                       has listings; prints them as [{title, year, km, price_eur, url}]

Run from server/:
    uv run python scripts/smoke_contextdev.py
    uv run python scripts/smoke_contextdev.py --model "Toyota Corolla" --max-pages 5

CLAUDE.md rule 5: a 200 can still fail, so every output's `success` flag is checked,
and listings are scraped with max_age_ms=0 (fresh). Costs a few credits per run.
"""

import argparse
import json
import os
import sys
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent.parent / ".env")

from context.dev import ContextDev, ContextDevError  # noqa: E402

LISTING_SCHEMA = {
    "type": "object",
    "properties": {
        "listings": {
            "type": "array",
            "description": "Every used car advert shown on the page, in page order. Empty if there are none.",
            "items": {
                "type": "object",
                "properties": {
                    "title": {"type": ["string", "null"], "description": "Advert title, e.g. 'Honda HR-V 1.5 i-VTEC Elegance'."},
                    "year": {"type": ["integer", "null"], "description": "Registration / model year of the car."},
                    "km": {"type": ["integer", "null"], "description": "Odometer reading in kilometres."},
                    "price_eur": {"type": ["integer", "null"], "description": "Asking price in euros, whole number, no currency symbol."},
                    "url": {"type": ["string", "null"], "description": "Absolute URL of this car's own advert page."},
                },
                "required": ["title", "year", "km", "price_eur", "url"],
            },
        }
    },
    "required": ["listings"],
}
INSTRUCTIONS = (
    "The page is a Finnish used-car site (Finnish: 'hinta' = price, 'mittarilukema' = km, "
    "'vuosimalli' = year). It may be one advert or a list of adverts: return one entry per car "
    "actually offered for sale on the page, ignoring ads, financing offers and related-model carousels. "
    "Use null for anything not shown; never guess."
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--model", default="Honda HR-V", help="car make and model to search for")
    parser.add_argument("--max-pages", type=int, default=3, help="max result pages to try extracting from")
    parser.add_argument("--num-results", type=int, default=8)
    parser.add_argument("--show", type=int, default=5, help="how many extracted listings to print")
    args = parser.parse_args()

    if not os.getenv("CONTEXT_DEV_API_KEY"):
        print("config error: CONTEXT_DEV_API_KEY is not set (put it in .env)", file=sys.stderr)
        return 2
    client = ContextDev(timeout=60.0, max_retries=2)

    # ---- 1. search -----------------------------------------------------------
    query = f"{args.model} käytetty myytävänä hinta km"
    print(f"--- search: {query!r} (country=fi) ---")
    try:
        search = client.web.search(query=query, country="fi", languages=["fi"], num_results=args.num_results)
    except ContextDevError as exc:
        print(f"search FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    if not search.results:
        print("search returned no results", file=sys.stderr)
        return 1
    for i, r in enumerate(search.results, 1):
        print(f"{i:>2}. [{r.relevance}] {r.title[:70]}\n    {r.url}")
    if search.key_metadata:
        print(f"credits: used {search.key_metadata.credits_consumed}, left {search.key_metadata.credits_remaining}")

    # ---- 2. structured extraction -------------------------------------------
    for result in search.results[: args.max_pages]:
        print(f"\n--- extract: {result.url} ---")
        try:
            page = client.web.scrape(
                url=result.url,
                formats={"json": True},
                json_params={"schema": LISTING_SCHEMA, "instructions": INSTRUCTIONS},
                max_age_ms=0,
            )
        except ContextDevError as exc:
            print(f"scrape FAILED: {type(exc).__name__}: {exc}")
            continue

        out = page.json_
        if not out.success:  # a 200 can still fail
            print(f"extraction failed: error_code={out.error_code} message={out.message}")
            continue
        data = out.data or {}
        if out.is_truncated:
            print("note: page was truncated, some values may be missing")
        listings = [x for x in data.get("listings", []) if x.get("price_eur") is not None]
        if not listings:
            print("no listings with a price on this page, skipping")
            continue

        print(f"{len(listings)} listings with a price; showing up to {args.show}:")
        print(json.dumps(listings[: args.show], ensure_ascii=False, indent=2))
        prices = sorted(x["price_eur"] for x in listings)
        print(f"price range on this page: {prices[0]} - {prices[-1]} EUR (median {prices[len(prices) // 2]})")
        return 0

    print("\nno usable listing found in the pages tried (try --max-pages 6 or another --model)", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
