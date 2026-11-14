"""products: price headphones, phones, laptops and any other shop item from Finnish shops and price-comparison sites.

Search (price-comparison pages and shops) -> scrape ~6 pages concurrently with structured JSON
extraction (Context.dev) -> clean -> TWO ranges computed in plain Python (CLAUDE.md rule 2):
  * `range`      the NEW retail price (what you would pay in a shop). This is the guess target.
  * `used_range` used or refurbished offers (Swappie, Tori, Back Market ...), shown as a second line.

Same grounding rules as cars: every snapshot lists its sources and a fetched_at time; failed pages,
mixed storage sizes, thin data and disagreeing sources are stated in `notes`.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import re
import time
from typing import AsyncIterator, Protocol

import price
from price import (
    DEADLINE_S,
    DISAGREE_RATIO,
    MIN_LISTINGS,
    Hit,
    Offer,
    domain_of,
    norm,
    percentile,
    registered_domain,
    trim_outliers,
)

log = logging.getLogger("products")

MAX_PAGES = 6  # pages scraped per lookup (5 Context.dev credits each)
MAX_USED_PAGES = 2  # of those, at most this many from used / refurbished markets
MIN_OFFER, MAX_OFFER = 1.0, 20_000.0  # sanity bounds for a consumer-electronics price in EUR

# Markets that sell used or refurbished goods: an offer with no condition label counts as used there.
USED_SITES = {
    "swappie.com", "mresell.fi", "backmarket.fi", "backmarket.com", "tori.fi", "huuto.net",
    "vaihtokapula.fi", "recommerce.fi", "kierratyskeskus.fi", "refurbed.fi",
}
# Pages that talk about products but are not shops (forums, reviews, video, encyclopaedias).
SKIP_SITES = {
    "io-tech.fi", "mobiili.fi", "youtube.com", "reddit.com", "facebook.com", "wikipedia.org",
    "gsmarena.com", "tekniikanmaailma.fi", "pinterest.com", "instagram.com",
    # shop pages that timed out or failed on every attempt (3 of 3): they only slow a lookup down
    "dna.fi",
}
# A word right after the model that makes it a different (pricier or cheaper) model.
_VARIANT_WORDS = {"pro", "plus", "max", "ultra", "mini", "lite", "fe", "se"}
_STOP_WORDS = {
    "the", "and", "for", "with", "new", "used", "uusi", "kaytetty", "käytetty", "hinta", "ja", "kpl", "set", "sale",
}
_STORAGE = re.compile(r"(\d+)\s*(gb|gt|tb|tt)\b", re.IGNORECASE)  # Finnish: Gt = GB, Tt = TB


class OfferSource(Protocol):
    async def search(self, query: str) -> list[Hit]: ...
    async def scrape_offers(self, url: str) -> list[Offer]: ...


# ----------------------------------------------------------------------------- helpers


def tokens(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", (text or "").lower())


def tokens_u(text: str) -> list[str]:
    """Like tokens(), but keeps Finnish letters (a, o with dots) inside words."""
    return re.findall(r"[^\W_]+", (text or "").lower())


def matches_generic(name: str, query: str) -> bool:
    """A generic item ("wooden dining chair", "tammi ruokapöydän tuoli"): the offer's name shares at
    least half of the query's words. Words match on their first four letters, so Finnish word forms
    (tuoli / tuolit / tuolia) and compounds still match."""
    wanted = [t for t in tokens_u(query) if len(t) >= 3 and t not in _STOP_WORDS]
    if not wanted:
        return True
    have = [t for t in tokens_u(name) if len(t) >= 3]
    hits = sum(1 for t in wanted if any(a.startswith(t[:4]) or t.startswith(a[:4]) for a in have))
    return hits / len(wanted) >= 0.5


def storages(text: str) -> set[str]:
    """Storage sizes mentioned in a name: '128 Gt' and '128GB' both become '128gb'."""
    found = set()
    for number, unit in _STORAGE.findall(text or ""):
        unit = "gb" if unit.lower() in ("gb", "gt") else "tb"
        found.add(f"{int(number)}{unit}")
    return found


def _gb(size: str) -> int:
    return int(size[:-2]) * (1024 if size.endswith("tb") else 1)


def main_storage(text: str) -> str | None:
    """The largest storage figure in a name: the SSD of a laptop, the storage of a phone."""
    found = storages(text)
    return max(found, key=_gb) if found else None


def matches_product(name: str, model: str) -> bool:
    """The offer is for the identified model, not for a sibling ("iPhone 15" is not "iPhone 15 Pro")."""
    name_t, model_t = tokens(name), tokens(model)
    if not model_t:
        return False
    n = len(model_t)
    sibling = False
    for i in range(len(name_t) - n + 1):
        if name_t[i : i + n] == model_t:
            following = name_t[i + n] if i + n < len(name_t) else None
            if following in _VARIANT_WORDS and following not in model_t:
                sibling = True  # "iPhone 15 Pro": a different model, and the fallback below must not undo that
                continue
            return True
    if sibling:
        return False
    # Long, specific names ("MacBook Air 13 M2") are written in many orders ("MacBook Air M2 13,6"):
    # accept all of their words in any order, unless the offer adds a sibling word (Pro, Max, Ultra ...).
    if len(model_t) >= 3:
        present = set(name_t)
        if all(t in present for t in model_t) and not (present & _VARIANT_WORDS) - set(model_t):
            return True
    # "WH-1000XM5" versus "WH1000XM5": compare with separators removed (long names only, to stay safe)
    joined = norm(model)
    return len(joined) >= 5 and joined in norm(name)


def variant_ok(name: str, variant: str | None) -> bool:
    """With a storage size given, drop offers that clearly name a different one."""
    if not variant:
        return True
    want, have = storages(variant), storages(name)
    return not (want and have and not (want & have))


def bucket(offer: Offer) -> str:
    """'new' or 'used'. Unlabelled offers follow the site: used markets are used, shops are new."""
    if offer.condition in ("used", "refurbished"):
        return "used"
    if offer.condition == "new":
        return "new"
    return "used" if registered_domain("https://" + offer.source) in USED_SITES else "new"


def pick_product_urls(hits: list[Hit], max_pages: int = MAX_PAGES) -> list[str]:
    """One page per site, shops and comparison sites first, with room for a couple of used markets."""
    seen: set[str] = set()
    shops: list[str] = []
    used: list[str] = []
    for hit in hits:
        host, site = domain_of(hit.url), registered_domain(hit.url)
        if site in seen or site in SKIP_SITES or host.startswith("yrityksille."):  # business prices differ
            continue
        seen.add(site)
        (used if site in USED_SITES else shops).append(hit.url)
    used = used[:MAX_USED_PAGES]
    return (shops[: max_pages - len(used)] + used)[:max_pages]


def _range_of(prices: list[float]) -> dict | None:
    prices = sorted(trim_outliers([round(p) for p in prices]))
    if len(prices) < MIN_LISTINGS:
        return None
    if len(prices) >= 10:
        low, high, basis = percentile(prices, 0.10), percentile(prices, 0.90), "10th-90th percentile"
    else:
        low, high, basis = float(prices[0]), float(prices[-1]), "min-max (few offers)"
    return {
        "low": _round(low),
        "median": _round(percentile(prices, 0.5)),
        "high": _round(high),
        "currency": "EUR",
        "basis": basis,
        "n": len(prices),
    }


def _round(value: float) -> int:
    """Whole euros under 1,000, nearest 10 above."""
    return int(round(value)) if value < 1_000 else int(round(value / 10.0) * 10)


# ------------------------------------------------------------------------- statistics


def compute_product_range(
    offers: list[Offer], model: str, variant: str | None = None, generic_query: str | None = None
) -> dict:
    """Pure-Python new and used ranges from the cleaned offers. Never raises; explains itself in `notes`.

    With `generic_query` (kind "item": a name, not an exact model) offers are kept when they are about the
    same kind of thing, and the answer says it is a rough estimate."""
    notes: list[str] = []
    seen: set[tuple] = set()
    unique: list[Offer] = []
    for o in offers:
        key = (o.source, norm(o.name), round(o.price_eur))
        if MIN_OFFER <= o.price_eur <= MAX_OFFER and key not in seen:
            seen.add(key)
            unique.append(o)

    generic = generic_query is not None
    if generic:
        matched = [o for o in unique if matches_generic(o.name, generic_query) or matches_generic(o.name, model)]
    else:
        matched = [o for o in unique if matches_product(o.name, model)]
    unfiltered = generic and len(matched) < MIN_LISTINGS <= len(unique)
    if unfiltered:
        # the name (often English, typed by the user) shares no words with the offers' titles: judging
        # relevance would throw everything away, so keep what the search returned
        matched = unique
    other = len(unique) - len(matched)
    if other:
        notes.append(f"ignored {other} offers for unrelated products" if generic else f"ignored {other} offers for other models or accessories")
    if generic:
        notes.append("a rough estimate for this kind of item: brand, size and quality move the price a lot")
        if unfiltered:
            notes.append("could not check that every offer is the same kind of item: treat this as very rough")
    sized = [o for o in matched if variant_ok(o.name, variant)]
    if len(matched) - len(sized):
        notes.append(f"ignored {len(matched) - len(sized)} offers for a different size than {variant}")

    if not variant and not generic:
        # one size per offer: its largest figure (a laptop name carries RAM and SSD, "8 Gt · 256 Gt")
        sizes = sorted({m for o in sized if (m := main_storage(o.name))}, key=_gb)
        if len(sizes) > 1:
            notes.append(f"offers cover several sizes ({', '.join(sizes)}); say which one for a tighter range")

    new_offers = [o for o in sized if bucket(o) == "new"]
    used_offers = [o for o in sized if bucket(o) == "used"]
    new_range = _range_of([o.price_eur for o in new_offers])
    used_range = _range_of([o.price_eur for o in used_offers])

    # An older model can be gone from the shops and sold only used or refurbished: then the used
    # price is the one worth guessing, and the answer says so.
    price_basis, basis_offers = "new", new_offers
    if new_range is None and used_range is not None:
        new_range, used_range, price_basis, basis_offers = used_range, None, "used", used_offers
        notes.append(
            "no new offers found: this model seems to be sold only used or refurbished now, "
            "so this is the used price"
        )
    elif new_range is None:
        notes.append(f"only {len(new_offers)} new offers; not enough for a price range")

    sample: list[dict] = []
    if new_range:
        median = new_range["median"]
        nearest = sorted(basis_offers, key=lambda o: abs(o.price_eur - median))[:5]
        sample = [
            {"name": o.name, "price_eur": o.price_eur, "condition": bucket(o), "url": o.url, "source": o.source}
            for o in nearest
        ]
        by_site: dict[str, list[float]] = {}
        for o in basis_offers:
            by_site.setdefault(o.source, []).append(o.price_eur)
        medians = {s: percentile(sorted(v), 0.5) for s, v in by_site.items() if len(v) >= MIN_LISTINGS}
        if len(medians) >= 2 and max(medians.values()) / min(medians.values()) > DISAGREE_RATIO:
            detail = ", ".join(f"{s} {round(m)} EUR" for s, m in sorted(medians.items(), key=lambda kv: kv[1]))
            notes.append(f"sources disagree on the typical price ({detail})")

    return {
        "range": new_range,
        "price_basis": price_basis,  # "new" normally; "used" when the model is only sold used now
        "used_range": used_range,
        "n_found": len(sized),
        "n_listings": new_range["n"] if new_range else 0,
        "n_used": used_range["n"] if used_range else len(used_offers),
        "sample": sample,
        "notes": notes,
    }


# ------------------------------------------------------------------------------ engine


def _generic_query(kind: str, make: str, model: str, search: str | None) -> str | None:
    """What an offer must be about for a generic item (None for the exact-model kinds)."""
    return " ".join(p for p in (make, search or model) if p) if kind == "item" else None


def _snapshot(
    status: str,
    kind: str,
    make: str,
    model: str,
    variant: str | None,
    sources: list[dict],
    total: int,
    offers: list[Offer],
    extra_notes: list[str] | None = None,
    search: str | None = None,
) -> dict:
    stats = compute_product_range(offers, model, variant, _generic_query(kind, make, model, search)) if offers else {
        "range": None, "price_basis": "new", "used_range": None, "n_found": 0, "n_listings": 0, "n_used": 0,
        "sample": [], "notes": [],
    }
    return {
        "status": status,
        "kind": kind,
        "make": make,
        "model": model,
        "variant": variant,
        **stats,
        "sources": sources,
        "sources_total": total,
        "sources_done": sum(1 for s in sources if s["status"] != "reading"),
        "notes": (extra_notes or []) + stats["notes"],
        "fetched_at": price._now(),
        "cached": False,
    }


async def price_product(
    source: OfferSource,
    kind: str,
    make: str,
    model: str,
    variant: str | None = None,
    *,
    search: str | None = None,
    max_pages: int = MAX_PAGES,
    deadline_s: float = DEADLINE_S,
) -> AsyncIterator[dict]:
    """Yield snapshots: searching -> reading (once per page that answers) -> done / insufficient / failed.

    `search` is the Finnish shopper phrase for a generic item; the name is searched when it is missing."""
    yield _snapshot("searching", kind, make, model, variant, [], 0, [], search=search)

    query = " ".join(p for p in ((make, search or model) if kind == "item" else (make, model)) + (variant, "hinta") if p)
    try:
        hits = await source.search(query)
    except Exception as exc:
        log.warning("search failed: %s", exc)
        yield _snapshot("failed", kind, make, model, variant, [], 0, [], [f"price search failed: {type(exc).__name__}"], search)
        return

    urls = pick_product_urls(hits, max_pages)
    if not urls:
        yield _snapshot("failed", kind, make, model, variant, [], 0, [], ["no shop pages found"], search)
        return

    sources = [{"domain": domain_of(u), "url": u, "status": "reading", "n_listings": 0} for u in urls]
    by_url = {s["url"]: s for s in sources}
    offers: list[Offer] = []
    yield _snapshot("reading", kind, make, model, variant, sources, len(urls), offers, search=search)

    tasks = {asyncio.ensure_future(source.scrape_offers(u)): u for u in urls}
    pending = set(tasks)
    loop = asyncio.get_running_loop()
    deadline = loop.time() + deadline_s
    try:
        while pending:
            done, pending = await asyncio.wait(
                pending, timeout=max(0.0, deadline - loop.time()), return_when=asyncio.FIRST_COMPLETED
            )
            if not done:
                break
            for fut in done:
                entry = by_url[tasks[fut]]
                try:
                    items = fut.result()
                    entry["status"], entry["n_listings"] = "ok", len(items)
                    offers.extend(items)
                except Exception as exc:
                    entry["status"], entry["error"] = "failed", str(exc)[:120] or type(exc).__name__
            if pending:
                yield _snapshot("reading", kind, make, model, variant, sources, len(urls), offers, search=search)
    finally:
        for fut in pending:
            fut.cancel()
            by_url[tasks[fut]]["status"] = "timeout"

    failed = [s for s in sources if s["status"] in ("failed", "timeout")]
    notes = [f"{len(failed)} of {len(sources)} pages could not be read"] if failed else []
    final = _snapshot("done", kind, make, model, variant, sources, len(urls), offers, notes, search)
    if not any(s["status"] == "ok" for s in sources):
        final["status"] = "failed"
    elif final["range"] is None:
        final["status"] = "insufficient"
    yield final


# -------------------------------------------------------------------------------- cache


def _cache_path(kind: str, make: str, model: str, variant: str | None, search: str | None = None):
    key = json.dumps([kind, norm(make), norm(model), norm(variant or ""), norm(search or "")])
    return price.CACHE_DIR / "products" / f"{hashlib.sha256(key.encode()).hexdigest()}.json"


def cache_get(
    kind: str, make: str, model: str, variant: str | None, ttl_s: float | None = None, search: str | None = None
) -> dict | None:
    path = _cache_path(kind, make, model, variant, search)
    ttl = price.CACHE_TTL_S if ttl_s is None else ttl_s
    try:
        if time.time() - path.stat().st_mtime > ttl:
            return None
        snap = json.loads(path.read_text("utf-8"))
    except (OSError, ValueError):
        return None
    snap["cached"] = True
    return snap


def cache_put(kind: str, make: str, model: str, variant: str | None, snapshot: dict, search: str | None = None) -> None:
    if snapshot.get("status") != "done":  # never cache failures or thin results
        return
    try:
        path = _cache_path(kind, make, model, variant, search)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(snapshot, ensure_ascii=False), "utf-8")
        tmp.replace(path)
    except OSError as exc:
        log.warning("product price cache write failed: %s", exc)


async def price_product_cached(
    source: OfferSource, kind: str, make: str, model: str, variant: str | None = None, *,
    search: str | None = None, **kw
) -> AsyncIterator[dict]:
    """Like price_product, but answers instantly from the local cache while it is fresh (30 min)."""
    hit = cache_get(kind, make, model, variant, search=search)
    if hit is not None:
        yield hit
        return
    last: dict | None = None
    async for snap in price_product(source, kind, make, model, variant, search=search, **kw):
        last = snap
        yield snap
    if last is not None:
        cache_put(kind, make, model, variant, last, search)
