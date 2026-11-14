"""price: turn an identification (make, model, year range) into a real price range.

Live used-car listings from Finnish dealer sites via Context.dev:
  search (find listing pages) -> scrape each page with structured JSON extraction (concurrently)
  -> filter/clean -> range, median, sources.

CLAUDE.md rules honoured here:
  * No LLM arithmetic: every number below is computed in plain Python.
  * Grounding: every result lists its sources (URL, how many listings, ok/failed) and a
    "fetched_at" time; failures, thin data and disagreeing sources are stated in `notes`.
  * Context.dev: the `success` flag of every extraction is checked (a 200 can still fail) and
    listing pages are scraped with max_age_ms=0 (fresh).

The engine is a stream of snapshots, so the accordion can squeeze as each source answers.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
import re
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import AsyncIterator, Protocol
from urllib.parse import urlparse

from nemotron import REPO_ROOT

log = logging.getLogger("price")

MAX_PAGES = 6  # listing pages scraped per lookup (5 Context.dev credits each)
PAGE_TIMEOUT_S = 30.0  # one page, counted from when it actually starts (not from when it queued)
DEADLINE_S = 75.0  # overall cap for the scraping phase, generous because pages can queue behind others
MIN_LISTINGS = 3  # below this there is no honest range
MIN_FOR_YEAR_FILTER = 8  # fewer listings than this in the year window -> the range is flagged as rough
YEAR_MARGIN = 1  # accept listings within +-1 year of the identified range
MIN_PRICE, MAX_PRICE = 500, 1_000_000  # sanity bounds for a car price in EUR
DISAGREE_RATIO = 1.4  # source medians further apart than this are reported
CACHE_DIR = REPO_ROOT / "cache" / "price"
CACHE_TTL_S = float(os.getenv("PRICE_CACHE_TTL_S", "1800"))


# ----------------------------------------------------------------------------- data


@dataclass(frozen=True)
class Listing:
    title: str
    year: int | None
    km: int | None
    price_eur: int
    url: str
    source: str  # domain the listing came from


@dataclass(frozen=True)
class Offer:
    """One shop offer for a product (headphones, phone, laptop), see products.py."""

    name: str
    price_eur: float
    condition: str | None  # "new" | "used" | "refurbished" | None when the page does not say
    url: str
    source: str  # domain the offer came from


@dataclass(frozen=True)
class Hit:
    url: str
    title: str = ""


class SourceError(Exception):
    """A page could not be read (blocked, extraction failed, timeout...)."""


class ListingSource(Protocol):
    async def search(self, query: str) -> list[Hit]: ...
    async def scrape(self, url: str) -> list[Listing]: ...


# --------------------------------------------------------------------------- helpers


def norm(text: str) -> str:
    return re.sub(r"[^a-z0-9]", "", (text or "").lower())


def domain_of(url: str) -> str:
    host = urlparse(url).netloc.lower()
    return host[4:] if host.startswith("www.") else host


def registered_domain(url: str) -> str:
    parts = domain_of(url).split(".")
    return ".".join(parts[-2:]) if len(parts) >= 2 else ".".join(parts)


def pick_urls(hits: list[Hit], make: str, model: str, max_pages: int = MAX_PAGES) -> list[str]:
    """Choose the listing pages worth scraping.

    Category pages (path ends with the model slug, e.g. /honda/hr-v) hold many cars, single advert
    pages hold one. Prefer the former, and take at most one page per site.
    """
    model_n = norm(model)

    def is_category(url: str) -> bool:
        last = urlparse(url).path.rstrip("/").rsplit("/", 1)[-1]
        return norm(last) == model_n

    seen_sites: set[str] = set()
    ordered = sorted(enumerate(hits), key=lambda ih: (not is_category(ih[1].url), ih[0]))
    picked: list[str] = []
    for _, hit in ordered:
        site = registered_domain(hit.url)
        if site in seen_sites:
            continue
        seen_sites.add(site)
        picked.append(hit.url)
        if len(picked) == max_pages:
            break
    return picked


def percentile(sorted_values: list[float], q: float) -> float:
    """Linear-interpolated percentile of an already sorted list (q in 0..1)."""
    if not sorted_values:
        raise ValueError("empty")
    pos = (len(sorted_values) - 1) * q
    lo, hi = int(pos), min(int(pos) + 1, len(sorted_values) - 1)
    return sorted_values[lo] + (sorted_values[hi] - sorted_values[lo]) * (pos - lo)


def trim_outliers(prices: list[int]) -> list[int]:
    """Drop prices outside the Tukey fences (needs >= 8 values, else returns them unchanged)."""
    if len(prices) < 8:
        return sorted(prices)
    s = sorted(prices)
    q1, q3 = percentile(s, 0.25), percentile(s, 0.75)
    iqr = q3 - q1
    lo, hi = q1 - 1.5 * iqr, q3 + 1.5 * iqr
    return [p for p in s if lo <= p <= hi]


def round10(x: float) -> int:
    return int(round(x / 10.0) * 10)


def matches_model(listing: Listing, make: str, model: str) -> bool:
    """Related-model carousels sneak into category pages; keep only the identified model."""
    title_n, model_n = norm(listing.title), norm(model)
    if not model_n or model_n not in title_n:
        return False
    if len(model_n) <= 3:  # short names like "i3" or "up" also need the make
        return norm(make) in title_n or norm(make) in norm(listing.url)
    return True


# ------------------------------------------------------------------------- statistics


def compute_range(
    listings: list[Listing], make: str, model: str, year_range: tuple[int, int] | None
) -> dict:
    """Pure-Python range from the cleaned listings. Never raises; says what it did in `notes`."""
    notes: list[str] = []
    # One entry per advert: by URL first, then by fingerprint, because dealers and aggregators
    # republish the same car (same year, mileage and price) on several sites.
    by_url: dict[str, Listing] = {}
    for item in listings:
        if MIN_PRICE <= item.price_eur <= MAX_PRICE and item.url not in by_url:
            by_url[item.url] = item
    unique: dict[tuple, Listing] = {}
    for item in by_url.values():
        fingerprint = (
            (item.year, item.km, item.price_eur) if item.km else (item.year, item.price_eur, norm(item.title))
        )
        unique.setdefault(fingerprint, item)
    # A copy without mileage of a car that another site lists with mileage: same year and price.
    with_km = {(x.year, x.price_eur) for x in unique.values() if x.km}
    unique = {k: x for k, x in unique.items() if x.km or (x.year, x.price_eur) not in with_km}
    duplicates = len(by_url) - len(unique)
    if duplicates:
        notes.append(f"merged {duplicates} adverts that appear on several sites")
    matched = [x for x in unique.values() if matches_model(x, make, model)]
    dropped_other_model = len(unique) - len(matched)
    if dropped_other_model:
        notes.append(f"ignored {dropped_other_model} listings of other models")

    year_info: dict = {"applied": False, "years": None, "n_in_window": None}
    pool = matched
    if year_range:
        lo, hi = year_range[0] - YEAR_MARGIN, year_range[1] + YEAR_MARGIN
        pool = [x for x in matched if x.year is not None and lo <= x.year <= hi]
        year_info = {"applied": True, "years": [lo, hi], "n_in_window": len(pool)}
        if len(pool) < MIN_LISTINGS:
            # Never fall back to "all years": a range of cars from the wrong years would look
            # confident and be wrong (a 2018 car priced from 2007 listings).
            notes.append(
                f"only {len(pool)} of {len(matched)} listings are from {lo}-{hi}; "
                "not enough to price that year range"
            )
        elif len(pool) < MIN_FOR_YEAR_FILTER:
            notes.append(f"only {len(pool)} listings from {lo}-{hi}, so the range is rough")

    prices = trim_outliers([x.price_eur for x in pool])
    trimmed = len(pool) - len(prices)
    if trimmed:
        notes.append(f"dropped {trimmed} price outliers")

    result: dict = {
        "range": None,
        "n_found": len(matched),
        "n_listings": len(prices),
        "year_filter": year_info,
        "sample": [],
        "notes": notes,
    }
    if len(prices) < MIN_LISTINGS:
        if not any("not enough to price" in n for n in notes):
            notes.append(f"only {len(prices)} usable listings; not enough for a price range")
        return result

    if len(prices) >= 10:
        low, high = percentile(prices, 0.10), percentile(prices, 0.90)
        basis = "10th-90th percentile"
    else:
        low, high = float(prices[0]), float(prices[-1])
        basis = "min-max (few listings)"
    median = percentile(prices, 0.5)
    result["range"] = {
        "low": round10(low),
        "median": round10(median),
        "high": round10(high),
        "currency": "EUR",
        "basis": basis,
    }

    kept = {p for p in prices}
    nearest = sorted((x for x in pool if x.price_eur in kept), key=lambda x: abs(x.price_eur - median))[:5]
    result["sample"] = [
        {"title": x.title, "year": x.year, "km": x.km, "price_eur": x.price_eur, "url": x.url, "source": x.source}
        for x in nearest
    ]

    by_source: dict[str, list[int]] = {}
    for x in pool:
        if x.price_eur in kept:
            by_source.setdefault(x.source, []).append(x.price_eur)
    medians = {s: percentile(sorted(v), 0.5) for s, v in by_source.items() if len(v) >= MIN_LISTINGS}
    if len(medians) >= 2 and max(medians.values()) / min(medians.values()) > DISAGREE_RATIO:
        detail = ", ".join(f"{s} {round10(m)} EUR" for s, m in sorted(medians.items(), key=lambda kv: kv[1]))
        notes.append(f"sources disagree on the typical price ({detail})")
    return result


# ---------------------------------------------------------------------------- the engine


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _snapshot(
    status: str,
    make: str,
    model: str,
    year_range: tuple[int, int] | None,
    sources: list[dict],
    total: int,
    listings: list[Listing],
    extra_notes: list[str] | None = None,
) -> dict:
    stats = compute_range(listings, make, model, year_range) if listings else {
        "range": None, "n_found": 0, "n_listings": 0,
        "year_filter": {"applied": False, "years": None, "n_in_window": None}, "sample": [], "notes": [],
    }
    done = sum(1 for s in sources if s["status"] != "reading")
    return {
        "status": status,
        "make": make,
        "model": model,
        "year_range": list(year_range) if year_range else None,
        **stats,
        "sources": sources,
        "sources_total": total,
        "sources_done": done,
        "notes": (extra_notes or []) + stats["notes"],
        "fetched_at": _now(),
        "cached": False,
    }


async def price_car(
    source: ListingSource,
    make: str,
    model: str,
    year_range: tuple[int, int] | None = None,
    *,
    max_pages: int = MAX_PAGES,
    deadline_s: float = DEADLINE_S,
) -> AsyncIterator[dict]:
    """Yield snapshots: searching -> reading (once per page that answers) -> done/insufficient/failed."""
    yield _snapshot("searching", make, model, year_range, [], 0, [])

    try:
        hits = await source.search(f"{make} {model} vaihtoauto myytävänä")
    except Exception as exc:  # network, quota, bad key...
        log.warning("search failed: %s", exc)
        yield _snapshot("failed", make, model, year_range, [], 0, [], [f"listing search failed: {type(exc).__name__}"])
        return

    urls = pick_urls(hits, make, model, max_pages)
    if not urls:
        yield _snapshot("failed", make, model, year_range, [], 0, [], ["no listing pages found"])
        return

    sources = [{"domain": domain_of(u), "url": u, "status": "reading", "n_listings": 0} for u in urls]
    by_url = {s["url"]: s for s in sources}
    listings: list[Listing] = []
    yield _snapshot("reading", make, model, year_range, sources, len(urls), listings)

    tasks = {asyncio.ensure_future(source.scrape(u)): u for u in urls}
    pending = set(tasks)
    loop = asyncio.get_running_loop()
    deadline = loop.time() + deadline_s
    try:
        while pending:
            done, pending = await asyncio.wait(
                pending, timeout=max(0.0, deadline - loop.time()), return_when=asyncio.FIRST_COMPLETED
            )
            if not done:
                break  # deadline: keep whatever answered
            for fut in done:
                entry = by_url[tasks[fut]]
                try:
                    items = fut.result()
                    entry["status"] = "ok"
                    entry["n_listings"] = len(items)
                    listings.extend(items)
                except Exception as exc:
                    entry["status"] = "failed"
                    entry["error"] = str(exc)[:120] or type(exc).__name__
            if pending:
                yield _snapshot("reading", make, model, year_range, sources, len(urls), listings)
    finally:
        for fut in pending:
            fut.cancel()
            by_url[tasks[fut]]["status"] = "timeout"

    failed = [s for s in sources if s["status"] in ("failed", "timeout")]
    notes = [f"{len(failed)} of {len(sources)} pages could not be read"] if failed else []
    final = _snapshot("done", make, model, year_range, sources, len(urls), listings, notes)
    if not any(s["status"] == "ok" for s in sources):
        final["status"] = "failed"
    elif final["range"] is None:
        final["status"] = "insufficient"
    yield final


# -------------------------------------------------------------------------------- cache


def _cache_path(make: str, model: str, year_range: tuple[int, int] | None) -> Path:
    key = json.dumps([norm(make), norm(model), list(year_range) if year_range else None])
    return CACHE_DIR / f"{hashlib.sha256(key.encode()).hexdigest()}.json"


def cache_get(make: str, model: str, year_range: tuple[int, int] | None, ttl_s: float = CACHE_TTL_S) -> dict | None:
    path = _cache_path(make, model, year_range)
    try:
        if time.time() - path.stat().st_mtime > ttl_s:
            return None
        snap = json.loads(path.read_text("utf-8"))
    except (OSError, ValueError):
        return None
    snap["cached"] = True
    return snap


def cache_put(make: str, model: str, year_range: tuple[int, int] | None, snapshot: dict) -> None:
    if snapshot.get("status") != "done":  # never cache failures or thin results
        return
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        path = _cache_path(make, model, year_range)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(snapshot, ensure_ascii=False), "utf-8")
        tmp.replace(path)
    except OSError as exc:
        log.warning("price cache write failed: %s", exc)


async def price_car_cached(
    source: ListingSource, make: str, model: str, year_range: tuple[int, int] | None = None, **kw
) -> AsyncIterator[dict]:
    """Like price_car, but answers instantly from the local cache while it is fresh (30 min)."""
    hit = cache_get(make, model, year_range)
    if hit is not None:
        yield hit
        return
    last: dict | None = None
    async for snap in price_car(source, make, model, year_range, **kw):
        last = snap
        yield snap
    if last is not None:
        cache_put(make, model, year_range, last)


# --------------------------------------------------------------------- Context.dev source

_SCHEMA = {
    "type": "object",
    "properties": {
        "listings": {
            "type": "array",
            "description": "Every used car advert offered for sale on the page, in page order.",
            "items": {
                "type": "object",
                "properties": {
                    "title": {"type": ["string", "null"]},
                    "year": {"type": ["integer", "null"]},
                    "km": {"type": ["integer", "null"]},
                    "price_eur": {"type": ["integer", "null"]},
                    "url": {"type": ["string", "null"]},
                },
                "required": ["title", "year", "km", "price_eur", "url"],
            },
        }
    },
    "required": ["listings"],
}
_INSTRUCTIONS = (
    "The page is a Finnish used-car site (Finnish: 'hinta' = price, 'mittarilukema' = km, "
    "'vuosimalli' = year). Return one entry per car actually offered for sale on the page; ignore "
    "ads, financing offers and related-model carousels. Use null for anything not shown; never guess."
)


_OFFER_SCHEMA = {
    "type": "object",
    "properties": {
        "offers": {
            "type": "array",
            "description": "Every shop offer shown for the searched product, in page order.",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": ["string", "null"]},
                    "price_eur": {"type": ["number", "null"]},
                    "condition": {"type": ["string", "null"], "enum": ["new", "used", "refurbished", None]},
                    "url": {"type": ["string", "null"]},
                },
                "required": ["name", "price_eur", "condition", "url"],
            },
        }
    },
    "required": ["offers"],
}
_OFFER_INSTRUCTIONS = (
    "The page is a Finnish web shop or price-comparison page (Finnish: 'hinta' = price, 'uusi' = new, "
    "'käytetty' = used, 'kunnostettu' = refurbished). Return one entry per offer actually shown for the "
    "searched product, with its price in euros. Ignore accessories, cases, ads, financing offers and unrelated "
    "products. Use null for anything not shown; never guess."
)


class ContextDevSource:
    """Real source: Context.dev web.search + web.scrape (structured JSON extraction)."""

    def __init__(
        self,
        api_key: str | None = None,
        timeout_s: float = 45.0,
        concurrency: int = 8,
        page_timeout_s: float = PAGE_TIMEOUT_S,
    ) -> None:
        from context.dev import AsyncContextDev  # imported here so tests need no SDK setup

        key = api_key or os.getenv("CONTEXT_DEV_API_KEY")
        if not key:
            raise RuntimeError("CONTEXT_DEV_API_KEY is not set (put it in .env)")
        self._client = AsyncContextDev(api_key=key, timeout=timeout_s, max_retries=1)
        self._sem = asyncio.Semaphore(concurrency)  # shared by every lookup: protects the API quota
        self._page_timeout_s = page_timeout_s

    async def search(self, query: str) -> list[Hit]:
        resp = await self._client.web.search(query=query, country="fi", languages=["fi"], num_results=10)
        return [Hit(url=r.url, title=r.title) for r in resp.results]

    async def scrape(self, url: str) -> list[Listing]:
        async with self._sem:
            # The clock starts here, after the queue: a page that waited for a free slot is not
            # penalised for it.
            try:
                page = await asyncio.wait_for(
                    self._client.web.scrape(
                        url=url,
                        formats={"json": True},
                        json_params={"schema": _SCHEMA, "instructions": _INSTRUCTIONS},
                        max_age_ms=0,  # CLAUDE.md rule 5: fresh listings
                    ),
                    timeout=self._page_timeout_s,
                )
            except asyncio.TimeoutError:
                raise SourceError(f"page took longer than {self._page_timeout_s:.0f}s") from None
        out = page.json_
        if not out.success:  # a 200 can still fail
            raise SourceError(f"{out.error_code or 'extraction failed'}: {(out.message or '')[:80]}")
        site = domain_of(url)
        listings: list[Listing] = []
        for item in (out.data or {}).get("listings", []):
            price = item.get("price_eur")
            if not isinstance(price, int) or price <= 0:
                continue
            link = item.get("url") or url
            listings.append(
                Listing(
                    title=str(item.get("title") or ""),
                    year=item.get("year") if isinstance(item.get("year"), int) else None,
                    km=item.get("km") if isinstance(item.get("km"), int) else None,
                    price_eur=price,
                    url=link,
                    source=site,
                )
            )
        return listings

    async def scrape_offers(self, url: str) -> list[Offer]:
        """Shop offers on a product or price-comparison page (products.py).

        Extraction is language-model based and occasionally returns nothing for a page that does
        have offers (seen on a used-phone market: 4 offers, then 0 on the next call), so an empty
        result is tried once more.
        """
        offers = await self._scrape_offers_once(url)
        if not offers:
            offers = await self._scrape_offers_once(url)
        return offers

    async def _scrape_offers_once(self, url: str) -> list[Offer]:
        async with self._sem:
            try:
                page = await asyncio.wait_for(
                    self._client.web.scrape(
                        url=url,
                        formats={"json": True},
                        json_params={"schema": _OFFER_SCHEMA, "instructions": _OFFER_INSTRUCTIONS},
                        max_age_ms=0,
                    ),
                    timeout=self._page_timeout_s,
                )
            except asyncio.TimeoutError:
                raise SourceError(f"page took longer than {self._page_timeout_s:.0f}s") from None
        out = page.json_
        if not out.success:  # a 200 can still fail
            raise SourceError(f"{out.error_code or 'extraction failed'}: {(out.message or '')[:80]}")
        site = domain_of(url)
        offers: list[Offer] = []
        for item in (out.data or {}).get("offers", []):
            price = item.get("price_eur")
            if not isinstance(price, (int, float)) or isinstance(price, bool) or price <= 0:
                continue
            condition = item.get("condition")
            offers.append(
                Offer(
                    name=str(item.get("name") or ""),
                    price_eur=float(price),
                    condition=condition if condition in ("new", "used", "refurbished") else None,
                    url=item.get("url") or url,
                    source=site,
                )
            )
        return offers

    async def aclose(self) -> None:
        await self._client.close()
