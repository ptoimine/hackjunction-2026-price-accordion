"""Tests for price.py, looks.py and the price part of /look. No network, no credits: the listing
source is a fake and the price cache is redirected to a temp folder.

Run: cd server && uv run pytest -q
"""

import asyncio
import io
import time

import pytest
from fastapi.testclient import TestClient
from PIL import Image

import price
from looks import LookStore, price_eligibility
from main import app
from nemotron import NemotronReply
from price import Hit, Listing, SourceError, compute_range, percentile, pick_urls, price_car, price_car_cached, trim_outliers


@pytest.fixture(autouse=True)
def _isolated_cache(tmp_path, monkeypatch):
    monkeypatch.setattr(price, "CACHE_DIR", tmp_path / "price-cache")


def car(n, price_eur, year=2018, km=100_000, site="a.fi", title=None):
    return Listing(
        title=title or f"Honda HR-V 1.5 #{n}",
        year=year,
        km=km + n,  # distinct mileage so listings are not merged as duplicates
        price_eur=price_eur,
        url=f"https://{site}/car/{n}",
        source=site,
    )


def many(count, low=14_000, high=16_000, **kw):
    step = (high - low) / max(1, count - 1)
    return [car(i, int(low + step * i), **kw) for i in range(count)]


class FakeSource:
    """pages: url -> list of listings, an Exception, or (delay_seconds, list)."""

    def __init__(self, hits, pages):
        self.hits, self.pages, self.queries, self.scraped = hits, pages, [], []

    async def search(self, query):
        self.queries.append(query)
        if isinstance(self.hits, Exception):
            raise self.hits
        return self.hits

    async def scrape(self, url):
        self.scraped.append(url)
        spec = self.pages[url]
        delay, result = spec if isinstance(spec, tuple) else (0, spec)
        if delay:
            await asyncio.sleep(delay)
        if isinstance(result, Exception):
            raise result
        return result

    async def aclose(self):
        pass


async def collect(agen):
    return [snap async for snap in agen]


def category_hits(*sites):
    return [Hit(url=f"https://{s}/vaihtoautot/honda/hr-v") for s in sites]


# ------------------------------------------------------------------------- statistics


def test_percentile_and_trim():
    assert percentile([1, 2, 3, 4, 5], 0.5) == 3
    assert percentile([10, 20], 0.5) == 15
    assert percentile([7], 0.9) == 7
    prices = [100, 102, 98, 101, 99, 103, 97, 100, 5000]  # one absurd price
    assert 5000 not in trim_outliers(prices)
    assert trim_outliers([1, 2, 3]) == [1, 2, 3]  # too few to trim


def test_range_basic():
    r = compute_range(many(20), "Honda", "HR-V", None)
    assert r["range"]["currency"] == "EUR"
    assert r["range"]["low"] < r["range"]["median"] < r["range"]["high"]
    assert 14_000 <= r["range"]["low"] and r["range"]["high"] <= 16_000
    assert r["n_listings"] == 20 and r["range"]["basis"].startswith("10th")


def test_few_listings_use_min_max():
    r = compute_range(many(5), "Honda", "HR-V", None)
    assert r["range"]["low"] == 14_000 and r["range"]["high"] == 16_000
    assert "few listings" in r["range"]["basis"]


def test_insufficient_below_three():
    r = compute_range(many(2), "Honda", "HR-V", None)
    assert r["range"] is None and any("not enough" in n for n in r["notes"])


def test_year_window_applied():
    cheap_old = many(10, 8_000, 9_000, year=2012)
    right = many(10, 15_000, 17_000, year=2018)
    for i, x in enumerate(right):  # keep urls distinct from the other group
        right[i] = Listing(x.title + "R", x.year, x.km + 5_000, x.price_eur, x.url + "r", x.source)
    r = compute_range(cheap_old + right, "Honda", "HR-V", (2017, 2019))
    assert r["year_filter"] == {"applied": True, "years": [2016, 2020], "n_in_window": 10}
    assert r["range"]["low"] >= 15_000  # the 2012 cars are excluded


def test_wrong_years_never_fall_back_to_all_years():
    """The Octavia bug: only 2007-2008 listings were found for a 2017-2020 car, and the range
    came out at 550-1,100 EUR. Now it must say it cannot price those years."""
    old_cars = many(20, 500, 1_100, year=2008)
    r = compute_range([Listing(x.title.replace("Honda HR-V", "Skoda Octavia"), x.year, x.km, x.price_eur, x.url, x.source) for x in old_cars],
                      "Skoda", "Octavia", (2017, 2020))
    assert r["range"] is None
    assert r["year_filter"]["n_in_window"] == 0
    assert sum("not enough to price that year range" in n for n in r["notes"]) == 1  # said once


def test_thin_year_window_is_flagged_rough():
    recent = many(5, 15_000, 17_000, year=2018)
    others = [Listing(f"Honda HR-V old {i}", 2009, 200_000 + i, 4_000 + i, f"https://a.fi/old/{i}", "a.fi") for i in range(10)]
    r = compute_range(recent + others, "Honda", "HR-V", (2017, 2019))
    assert r["range"] is not None and r["range"]["low"] >= 15_000  # old cars still excluded
    assert any("range is rough" in n for n in r["notes"])
    assert "few listings" in r["range"]["basis"]


def test_other_models_and_bad_prices_ignored():
    items = many(10) + [
        car(100, 90_000, title="Honda CR-V 2.0"),
        car(101, 3, title="Honda HR-V part"),  # absurd price
    ]
    r = compute_range(items, "Honda", "HR-V", None)
    assert r["n_found"] == 10 and any("other models" in n for n in r["notes"])


def test_short_model_names_also_need_the_make():
    bmw = Listing("BMW i3 94Ah", 2018, 50_000, 20_000, "https://a.fi/1", "a.fi")
    other = Listing("Hyundai i30 1.4", 2018, 60_000, 12_000, "https://a.fi/2", "a.fi")  # contains no "i3"? it does: "i30"
    assert price.matches_model(bmw, "BMW", "i3")
    assert not price.matches_model(other, "BMW", "i3")  # "i30" contains "i3" but the make is not BMW


def test_cross_site_duplicates_merged():
    a = Listing("Honda HR-V 1,5 Executive", 2016, 135_000, 15_700, "https://a.fi/1", "a.fi")
    b = Listing("HONDA HR-V 1.5", 2016, 135_000, 15_700, "https://b.fi/9", "b.fi")  # same car, other site
    c = Listing("Honda HR-V 1,5 Executive", 2016, None, 15_700, "https://c.fi/5", "c.fi")  # copy without km
    r = compute_range([a, b, c] + many(8), "Honda", "HR-V", None)
    assert r["n_found"] == 9 and any("merged 2" in n for n in r["notes"])


def test_disagreeing_sources_reported():
    cheap = [car(i, 9_000 + i * 10, site="cheap.fi") for i in range(5)]
    dear = [car(50 + i, 16_000 + i * 10, site="dear.fi") for i in range(5)]
    r = compute_range(cheap + dear, "Honda", "HR-V", None)
    assert any("disagree" in n and "cheap.fi" in n for n in r["notes"])


# ----------------------------------------------------------------------------- pick_urls


def test_pick_urls_prefers_category_pages_one_per_site():
    hits = [
        Hit("https://www.ford.kayttoauto.fi/ajoneuvot/varasto/1290612/honda-hr-v-1-5"),  # one advert
        Hit("https://www.nettiauto.com/honda/hr-v"),
        Hit("https://www.nettiauto.com/en/honda/hr-v"),  # same site again
        Hit("https://www.autotie.fi/vaihtoautot/honda/hr-v"),
        Hit("https://www.kamux.fi/cars/honda/hr-v/"),
    ]
    picked = pick_urls(hits, "Honda", "HR-V", max_pages=3)
    assert picked == [
        "https://www.nettiauto.com/honda/hr-v",
        "https://www.autotie.fi/vaihtoautot/honda/hr-v",
        "https://www.kamux.fi/cars/honda/hr-v/",
    ]
    assert len(pick_urls(hits, "Honda", "HR-V", max_pages=10)) == 4  # one per site: 4 sites


# ----------------------------------------------------------------------------- the stream


def test_stream_progress_and_final_range():
    hits = category_hits("a.fi", "b.fi", "c.fi")
    pages = {
        "https://a.fi/vaihtoautot/honda/hr-v": many(12, site="a.fi"),
        "https://b.fi/vaihtoautot/honda/hr-v": (0.05, [car(200 + i, 15_000 + i, site="b.fi") for i in range(6)]),
        "https://c.fi/vaihtoautot/honda/hr-v": (0.10, SourceError("blocked")),
    }
    src = FakeSource(hits, pages)
    snaps = asyncio.run(collect(price_car(src, "Honda", "HR-V", (2017, 2019))))
    statuses = [s["status"] for s in snaps]
    assert statuses[0] == "searching" and statuses[1] == "reading" and statuses[-1] == "done"
    final = snaps[-1]
    assert final["range"] and final["n_found"] == 18  # all matching adverts; outlier trimming may keep fewer
    assert final["sources_total"] == 3 and final["sources_done"] == 3
    states = {s["domain"]: s["status"] for s in final["sources"]}
    assert states == {"a.fi": "ok", "b.fi": "ok", "c.fi": "failed"}
    assert any("1 of 3 pages could not be read" in n for n in final["notes"])
    assert final["fetched_at"] and final["cached"] is False
    assert src.queries == ["Honda HR-V vaihtoauto myytävänä"]
    # the range appears before the last page answers (the accordion squeezes progressively)
    assert any(s["status"] == "reading" and s["range"] for s in snaps)


def test_stream_all_pages_failing_is_failed():
    src = FakeSource(category_hits("a.fi"), {"https://a.fi/vaihtoautot/honda/hr-v": SourceError("blocked")})
    final = asyncio.run(collect(price_car(src, "Honda", "HR-V")))[-1]
    assert final["status"] == "failed" and final["range"] is None


def test_stream_too_few_listings_is_insufficient():
    src = FakeSource(category_hits("a.fi"), {"https://a.fi/vaihtoautot/honda/hr-v": many(2, site="a.fi")})
    final = asyncio.run(collect(price_car(src, "Honda", "HR-V")))[-1]
    assert final["status"] == "insufficient" and final["range"] is None


def test_stream_search_failure_and_no_hits():
    final = asyncio.run(collect(price_car(FakeSource(RuntimeError("quota"), {}), "Honda", "HR-V")))[-1]
    assert final["status"] == "failed" and any("search failed" in n for n in final["notes"])
    final = asyncio.run(collect(price_car(FakeSource([], {}), "Honda", "HR-V")))[-1]
    assert final["status"] == "failed" and "no listing pages found" in final["notes"]


def test_stream_deadline_keeps_what_answered():
    pages = {
        "https://a.fi/vaihtoautot/honda/hr-v": many(12, site="a.fi"),
        "https://b.fi/vaihtoautot/honda/hr-v": (5.0, many(12, site="b.fi")),  # far too slow
    }
    src = FakeSource(category_hits("a.fi", "b.fi"), pages)
    t0 = time.time()
    final = asyncio.run(collect(price_car(src, "Honda", "HR-V", deadline_s=0.3)))[-1]
    assert time.time() - t0 < 2
    states = {s["domain"]: s["status"] for s in final["sources"]}
    assert states == {"a.fi": "ok", "b.fi": "timeout"}
    assert final["status"] == "done" and final["range"] is not None


# -------------------------------------------------------------------------------- cache


def test_cache_serves_second_call_without_scraping():
    pages = {"https://a.fi/vaihtoautot/honda/hr-v": many(12, site="a.fi")}
    src = FakeSource(category_hits("a.fi"), pages)
    first = asyncio.run(collect(price_car_cached(src, "Honda", "HR-V", (2017, 2019))))[-1]
    assert first["cached"] is False and len(src.scraped) == 1

    again = asyncio.run(collect(price_car_cached(src, "honda", "hr-v", (2017, 2019))))
    assert len(again) == 1 and again[0]["cached"] is True and again[0]["range"] == first["range"]
    assert again[0]["fetched_at"] == first["fetched_at"]  # original fetch time is kept
    assert len(src.scraped) == 1  # nothing was scraped again

    other_years = asyncio.run(collect(price_car_cached(src, "Honda", "HR-V", (2010, 2012))))[-1]
    assert other_years["cached"] is False  # different year range = different cache entry


def test_cache_ignores_expired_and_never_stores_failures():
    price.cache_put("Honda", "HR-V", None, {"status": "failed", "range": None})
    assert price.cache_get("Honda", "HR-V", None) is None
    price.cache_put("Honda", "HR-V", None, {"status": "done", "range": {"low": 1}})
    assert price.cache_get("Honda", "HR-V", None) is not None
    assert price.cache_get("Honda", "HR-V", None, ttl_s=-1) is None  # expired


# ------------------------------------------------------------------- eligibility, store


def test_price_eligibility():
    ok = {"kind": "car", "make": "Honda", "model": "HR-V", "confidence": 0.8}
    assert price_eligibility(ok) is None
    assert "flats and houses are not priced yet" in price_eligibility({**ok, "kind": "building"})
    assert "does not look like something with a shop price" in price_eligibility({**ok, "kind": "other"})
    assert price_eligibility({**ok, "kind": "headphones", "make": "Sony", "model": "WH-1000XM5"}) is None
    assert "make and model" in price_eligibility({**ok, "model": None})
    assert "not confident" in price_eligibility({**ok, "confidence": 0.3})


def test_store_expiry_and_cap():
    s = LookStore(ttl_s=0.05, max_items=3)
    rec = s.create({}, {}, {"status": "x"})
    assert s.get(rec["look_id"]) is rec
    time.sleep(0.08)
    assert s.get(rec["look_id"]) is None  # expired
    s2 = LookStore(max_items=2)
    ids = [s2.create({}, {}, {})["look_id"] for _ in range(4)]
    assert s2.get(ids[0]) is None and s2.get(ids[-1]) is not None  # oldest dropped


# --------------------------------------------------------------------------- endpoints

GOOD_CAR = '{"kind":"car","make":"Honda","model":"HR-V","year_range":[2016,2021],"confidence":0.9,"description":"A grey SUV."}'
A_PLANT = '{"kind":"other","make":null,"model":null,"year_range":null,"confidence":0.9,"description":"A plant."}'


class FakeNemotron:
    def __init__(self, text):
        self.text = text

    async def chat(self, prompt, **kw):
        return NemotronReply(text=self.text, model="fake", cached=False, attempts=1, latency_s=0.1)

    async def aclose(self):
        pass


def jpeg():
    buf = io.BytesIO()
    Image.new("RGB", (64, 48), (120, 130, 140)).save(buf, "JPEG")
    return buf.getvalue()


def wait_for_price(c, look_id, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        body = c.get(f"/look/{look_id}").json()
        if body["price"]["status"] not in ("searching", "reading"):
            return body
        time.sleep(0.05)
    raise AssertionError("price job did not finish")


def test_look_starts_a_price_job_and_get_look_returns_it():
    pages = {"https://a.fi/vaihtoautot/honda/hr-v": many(12, site="a.fi")}
    with TestClient(app) as c:  # one event loop for the whole block, so the job keeps running
        app.state.nemotron = FakeNemotron(GOOD_CAR)
        app.state.price_source = FakeSource(category_hits("a.fi"), pages)
        r = c.post("/look", content=jpeg(), headers={"Content-Type": "image/jpeg"})
        assert r.status_code == 200
        first = r.json()
        assert first["price"]["status"] == "searching" and first["look_id"]
        final = wait_for_price(c, first["look_id"])
        assert final["price"]["status"] == "done"
        assert final["price"]["range"]["low"] < final["price"]["range"]["high"]
        assert final["identification"]["make"] == "Honda"
        assert final["price"]["sources"][0]["domain"] == "a.fi"


def test_look_skips_pricing_when_not_a_confident_car():
    with TestClient(app) as c:
        app.state.nemotron = FakeNemotron(A_PLANT)
        src = FakeSource(category_hits("a.fi"), {})
        app.state.price_source = src
        body = c.post("/look", content=jpeg(), headers={"Content-Type": "image/jpeg"}).json()
        assert body["price"]["status"] == "skipped" and "shop price" in body["price"]["reason"]
        assert src.queries == []  # no Context.dev credits spent
        assert c.get(f"/look/{body['look_id']}").json()["price"]["status"] == "skipped"


def test_get_look_unknown_id_is_404():
    with TestClient(app) as c:
        assert c.get("/look/nope").status_code == 404
