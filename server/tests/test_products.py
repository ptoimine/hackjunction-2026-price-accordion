"""Tests for products.py (headphones, phones, laptops) and POST /confirm. No network, no credits."""

import asyncio
import time

import pytest
from fastapi.testclient import TestClient

import price
import products
from main import app
from price import Hit, Listing, Offer, SourceError
from products import (
    bucket,
    compute_product_range,
    matches_generic,
    matches_product,
    pick_product_urls,
    price_product,
    price_product_cached,
    storages,
    variant_ok,
)
from test_price import FakeNemotron, jpeg, many, wait_for_price


@pytest.fixture(autouse=True)
def _isolated_cache(tmp_path, monkeypatch):
    monkeypatch.setattr(price, "CACHE_DIR", tmp_path / "price-cache")


def offer(i, price_eur, name="Sony WH-1000XM5 langattomat kuulokkeet", site="hinta.fi", cond=None):
    return Offer(name=f"{name} #{i}", price_eur=price_eur, condition=cond, url=f"https://{site}/p/{i}", source=site)


def offers(count, low=270, high=330, **kw):
    step = (high - low) / max(1, count - 1)
    return [offer(i, round(low + step * i), **kw) for i in range(count)]


def shop_hits(*sites):
    return [Hit(url=f"https://{s}/tuote/x") for s in sites]


class FakeShop:
    """Both a car listing source and a product offer source."""

    def __init__(self, hits, offer_pages=None, car_pages=None):
        self.hits, self.offer_pages, self.car_pages = hits, offer_pages or {}, car_pages or {}
        self.queries, self.scraped = [], []

    async def search(self, query):
        self.queries.append(query)
        if isinstance(self.hits, Exception):
            raise self.hits
        return self.hits

    async def scrape_offers(self, url):
        self.scraped.append(url)
        spec = self.offer_pages[url]
        delay, result = spec if isinstance(spec, tuple) else (0, spec)
        if delay:
            await asyncio.sleep(delay)
        if isinstance(result, Exception):
            raise result
        return result

    async def scrape(self, url):
        spec = self.car_pages[url]
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


# ------------------------------------------------------------------------------ matching


def test_model_matching_does_not_confuse_siblings():
    assert matches_product("Apple iPhone 15 128 Gt musta", "iPhone 15")
    assert not matches_product("Apple iPhone 15 Pro Max 256GB", "iPhone 15")
    assert not matches_product("Apple iPhone 15 Plus 128GB", "iPhone 15")
    assert matches_product("Apple iPhone 15 Pro 128GB", "iPhone 15 Pro")
    assert not matches_product("Apple iPhone 15 Pro Max", "iPhone 15 Pro")
    assert not matches_product("Apple iPhone 14 128GB", "iPhone 15")
    assert matches_product("MacBook Air 13 M2 256GB", "MacBook Air 13 M2")
    assert not matches_product("MacBook Air 13 M3 256GB", "MacBook Air 13 M2")
    # shops write long names in other orders; a sibling word still disqualifies the offer
    assert matches_product('Apple MacBook Air M2 13,6" 256GB hopea', "MacBook Air 13 M2")
    assert matches_product("Apple MacBook Air 13 tuumaa (M2) 8/256", "MacBook Air 13 M2")
    assert not matches_product("Apple MacBook Pro 13 M2", "MacBook Air 13 M2")
    assert not matches_product("Apple MacBook Air M2 15 Pro", "MacBook Air 15 M2")  # an extra "Pro" is a sibling


def test_model_matching_ignores_separators_and_case():
    assert matches_product("SONY WH-1000XM5 Wireless", "WH-1000XM5")
    assert matches_product("Sony WH1000XM5B musta", "WH-1000XM5")  # joined fallback also covers colour suffixes
    assert matches_product("Sony wh1000xm5 black", "WH-1000XM5")  # separators removed
    assert not matches_product("Sony WH-1000XM4 black", "WH-1000XM5")
    assert not matches_product("anything", "")


def test_storage_parsing_and_variant_filter():
    assert storages("iPhone 15 128 Gt") == {"128gb"}
    assert storages("MacBook 1 TB, 16GB RAM") == {"1tb", "16gb"}
    assert variant_ok("iPhone 15 128GB", "128GB")
    assert not variant_ok("iPhone 15 256GB", "128GB")
    assert variant_ok("iPhone 15 musta", "128GB")  # no size named: cannot tell, keep
    assert variant_ok("anything 512GB", None)


def test_condition_bucket_follows_label_then_site():
    assert bucket(offer(1, 100, cond="refurbished")) == "used"
    assert bucket(offer(1, 100, cond="new", site="swappie.com")) == "new"  # an explicit label wins
    assert bucket(offer(1, 100, site="swappie.com")) == "used"  # unlabelled on a used market
    assert bucket(offer(1, 100, site="hinta.fi")) == "new"  # unlabelled in a shop


def test_page_picking():
    hits = shop_hits(
        "www.hinta.fi", "bbs.io-tech.fi", "yrityksille.elisa.fi", "kauppa.dna.fi", "www.hintaopas.fi", "hintaopas.fi",
        "www.swappie.com", "www.tori.fi", "www.backmarket.fi", "www.verkkokauppa.com",
    )
    picked = pick_product_urls(hits, max_pages=5)
    sites = [price.domain_of(u) for u in picked]
    assert "bbs.io-tech.fi" not in sites and "yrityksille.elisa.fi" not in sites  # forum and business prices
    assert "kauppa.dna.fi" not in sites  # known to time out
    assert sites.count("hintaopas.fi") == 1  # one page per site
    used = [s for s in sites if s in ("swappie.com", "tori.fi", "backmarket.fi")]
    assert 1 <= len(used) <= products.MAX_USED_PAGES
    assert len(picked) == 5 and sites[0] == "hinta.fi"  # shops first


# ----------------------------------------------------------------------------- statistics


def test_new_and_used_ranges_are_separate():
    new = offers(12, 270, 330)
    used = offers(5, 150, 190, site="swappie.com")
    r = compute_product_range(new + used, "WH-1000XM5")
    assert 270 <= r["range"]["low"] < r["range"]["median"] < r["range"]["high"] <= 330
    assert r["used_range"] and r["used_range"]["high"] <= 190
    assert r["n_listings"] == 12 and r["n_used"] == 5


def test_other_models_and_bad_prices_ignored():
    items = offers(10) + [
        offer(100, 400, name="Sony WH-1000XM4 kuulokkeet"),
        offer(101, 25, name="Sony WH-1000XM5 korvatyynyt"),  # a cheap accessory still matches the text...
        offer(102, 0.5, name="Sony WH-1000XM5"),  # ...an absurd price does not
    ]
    r = compute_product_range(items, "WH-1000XM5")
    assert any("other models or accessories" in n for n in r["notes"])
    assert r["range"]["low"] >= 200  # the accessory is trimmed as an outlier or excluded


def test_variant_filter_and_mixed_size_note():
    mixed = (
        [offer(i, 700 + i, name="Apple iPhone 15 128 Gt") for i in range(5)]
        + [offer(10 + i, 850 + i, name="Apple iPhone 15 256 Gt") for i in range(5)]
    )
    open_ended = compute_product_range(mixed, "iPhone 15")
    assert any("several sizes (128gb, 256gb)" in n for n in open_ended["notes"])
    asked = compute_product_range(mixed, "iPhone 15", "128GB")
    assert asked["range"]["high"] < 800 and any("different size" in n for n in asked["notes"])


def test_duplicate_offers_merged_and_thin_data_reported():
    dup = [offer(1, 299), offer(1, 299), offer(2, 310)]  # the first two: same site, name and price
    r = compute_product_range(dup, "WH-1000XM5")
    assert r["n_found"] == 2  # the duplicate counted once
    assert r["range"] is None and any("not enough for a price range" in n for n in r["notes"])


def test_disagreeing_shops_are_reported():
    cheap = offers(4, 190, 210, site="cheap.fi")
    dear = offers(4, 380, 400, site="dear.fi")
    r = compute_product_range(cheap + dear, "WH-1000XM5")
    assert any("disagree" in n and "cheap.fi" in n for n in r["notes"])


# --------------------------------------------------------------------------------- engine


def test_stream_progress_and_final():
    hits = shop_hits("hinta.fi", "hintaopas.fi", "verkkokauppa.com", "swappie.com")
    pages = {
        "https://hinta.fi/tuote/x": offers(12, site="hinta.fi"),
        "https://hintaopas.fi/tuote/x": (0.05, offers(6, 275, 320, site="hintaopas.fi")),
        "https://verkkokauppa.com/tuote/x": (0.1, SourceError("blocked")),
        "https://swappie.com/tuote/x": (0.02, offers(4, 140, 180, site="swappie.com")),
    }
    src = FakeShop(hits, pages)
    snaps = asyncio.run(collect(price_product(src, "headphones", "Sony", "WH-1000XM5")))
    assert [s["status"] for s in snaps][:2] == ["searching", "reading"] and snaps[-1]["status"] == "done"
    final = snaps[-1]
    assert final["range"] and final["used_range"] and final["kind"] == "headphones"
    assert {s["domain"]: s["status"] for s in final["sources"]} == {
        "hinta.fi": "ok", "hintaopas.fi": "ok", "verkkokauppa.com": "failed", "swappie.com": "ok",
    }
    assert any("1 of 4 pages could not be read" in n for n in final["notes"])
    assert src.queries == ["Sony WH-1000XM5 hinta"]
    assert any(s["status"] == "reading" and s["range"] for s in snaps)  # squeezes before the last page answers


def test_stream_query_includes_the_variant():
    src = FakeShop(shop_hits("hinta.fi"), {"https://hinta.fi/tuote/x": offers(5, site="hinta.fi")})
    asyncio.run(collect(price_product(src, "phone", "Apple", "iPhone 15", "128GB")))
    assert src.queries == ["Apple iPhone 15 128GB hinta"]


def test_stream_failure_modes():
    failed = asyncio.run(collect(price_product(FakeShop(RuntimeError("quota")), "phone", "Apple", "iPhone 15")))[-1]
    assert failed["status"] == "failed" and any("search failed" in n for n in failed["notes"])
    none = asyncio.run(collect(price_product(FakeShop([]), "phone", "Apple", "iPhone 15")))[-1]
    assert none["status"] == "failed" and "no shop pages found" in none["notes"]
    blocked = FakeShop(shop_hits("hinta.fi"), {"https://hinta.fi/tuote/x": SourceError("blocked")})
    assert asyncio.run(collect(price_product(blocked, "phone", "Apple", "iPhone 15")))[-1]["status"] == "failed"
    thin = FakeShop(shop_hits("hinta.fi"), {"https://hinta.fi/tuote/x": offers(2, site="hinta.fi")})
    assert asyncio.run(collect(price_product(thin, "phone", "Apple", "iPhone 15")))[-1]["status"] == "insufficient"


def test_stream_deadline_keeps_what_answered():
    pages = {"https://hinta.fi/tuote/x": offers(12, site="hinta.fi"), "https://slow.fi/tuote/x": (5.0, offers(12))}
    src = FakeShop(shop_hits("hinta.fi", "slow.fi"), pages)
    t0 = time.time()
    final = asyncio.run(collect(price_product(src, "laptop", "Apple", "MacBook Air 13 M2", deadline_s=0.3)))[-1]
    assert time.time() - t0 < 2
    assert {s["domain"]: s["status"] for s in final["sources"]} == {"hinta.fi": "ok", "slow.fi": "timeout"}


def test_product_cache_is_keyed_by_variant():
    pages = {"https://hinta.fi/tuote/x": offers(12, site="hinta.fi")}
    src = FakeShop(shop_hits("hinta.fi"), pages)
    first = asyncio.run(collect(price_product_cached(src, "headphones", "Sony", "WH-1000XM5")))[-1]
    again = asyncio.run(collect(price_product_cached(src, "headphones", "sony", "wh-1000xm5")))
    assert first["cached"] is False and len(again) == 1 and again[0]["cached"] is True
    assert again[0]["fetched_at"] == first["fetched_at"] and len(src.scraped) == 1
    other = asyncio.run(collect(price_product_cached(src, "headphones", "Sony", "WH-1000XM5", "black")))[-1]
    assert other["cached"] is False  # a different variant is a different entry


# ----------------------------------------------------------------------------- endpoints

HEADPHONES = (
    '{"kind":"headphones","make":"Sony","model":"WH-1000XM5","variant":null,"year_range":null,'
    '"confidence":0.8,"description":"White headphones."}'
)
UNSURE_OTHER = (
    '{"kind":"other","make":null,"model":null,"variant":null,"year_range":null,"confidence":0.9,'
    '"description":"A white over-ear headphone."}'
)
CAR = (
    '{"kind":"car","make":"Honda","model":"Crosstour","variant":null,"year_range":[2012,2015],'
    '"confidence":0.75,"description":"A grey hatchback."}'
)


def product_shop():
    pages = {"https://hinta.fi/tuote/x": offers(12, site="hinta.fi")}
    return FakeShop(shop_hits("hinta.fi"), pages)


def look(c):
    return c.post("/look", content=jpeg(), headers={"Content-Type": "image/jpeg"}).json()


def test_look_prices_a_product_and_reports_new_and_used():
    with TestClient(app) as c:
        app.state.nemotron = FakeNemotron(HEADPHONES)
        app.state.price_source = product_shop()
        first = look(c)
        assert first["identification"]["kind"] == "headphones" and first["confirmed"] is False
        assert first["price"]["status"] == "searching"
        final = wait_for_price(c, first["look_id"])
        assert final["price"]["status"] == "done" and final["price"]["range"]["low"] >= 270
        assert final["price"]["kind"] == "headphones"


def test_confirm_with_the_same_identification_keeps_the_running_lookup():
    with TestClient(app) as c:
        app.state.nemotron = FakeNemotron(HEADPHONES)
        shop = product_shop()
        app.state.price_source = shop
        look_id = look(c)["look_id"]
        r = c.post("/confirm", json={"look_id": look_id, "make": "Sony", "model": "WH-1000XM5"})
        assert r.status_code == 200 and r.json()["confirmed"] is True
        wait_for_price(c, look_id)
        assert len(shop.queries) == 1  # not searched a second time


def test_correcting_a_wrong_identification_restarts_the_lookup():
    with TestClient(app) as c:
        app.state.nemotron = FakeNemotron(CAR)  # the model said Honda Crosstour
        shop = FakeShop(
            [Hit("https://a.fi/vaihtoautot/honda/crosstour"), Hit("https://hinta.fi/tuote/x")],
            offer_pages={"https://hinta.fi/tuote/x": offers(12, site="hinta.fi")},
            car_pages={"https://a.fi/vaihtoautot/honda/crosstour": []},
        )
        app.state.price_source = shop
        look_id = look(c)["look_id"]
        # it is really a pair of headphones: correct it
        r = c.post("/confirm", json={"look_id": look_id, "kind": "headphones", "make": "Sony", "model": "WH-1000XM5"})
        assert r.status_code == 200
        body = r.json()
        assert body["confirmed"] is True and body["identification"]["kind"] == "headphones"
        assert body["identification"]["confidence"] == 1.0 and body["identification"]["year_range"] is None
        final = wait_for_price(c, look_id)
        assert final["price"]["status"] == "done" and final["price"]["kind"] == "headphones"
        assert shop.queries[-1] == "Sony WH-1000XM5 hinta"


def test_user_can_name_something_the_model_could_not():
    with TestClient(app) as c:
        app.state.nemotron = FakeNemotron(UNSURE_OTHER)
        app.state.price_source = product_shop()
        first = look(c)
        assert first["price"]["status"] == "skipped"
        # the kind is needed because the model said "other"
        assert c.post("/confirm", json={"look_id": first["look_id"], "make": "Sony", "model": "WH-1000XM5"}).status_code == 422
        r = c.post("/confirm", json={"look_id": first["look_id"], "kind": "headphones", "make": "Sony", "model": "WH-1000XM5", "variant": " black "})
        assert r.status_code == 200 and r.json()["price"]["status"] == "searching"
        assert r.json()["identification"]["variant"] == "black"
        assert wait_for_price(c, first["look_id"])["price"]["status"] == "done"


def test_correcting_a_car_sets_the_year_range():
    with TestClient(app) as c:
        app.state.nemotron = FakeNemotron(CAR)
        app.state.price_source = FakeShop([], {}, {})
        look_id = look(c)["look_id"]
        r = c.post("/confirm", json={"look_id": look_id, "make": "Honda", "model": "HR-V", "year_from": 2022, "year_to": 2016}).json()
        assert r["identification"]["model"] == "HR-V" and r["identification"]["year_range"] == [2016, 2022]
        assert r["identification"]["variant"] is None


def test_confirm_is_refused_after_the_guess_and_validates_input():
    with TestClient(app) as c:
        app.state.nemotron = FakeNemotron(HEADPHONES)
        app.state.price_source = product_shop()
        look_id = look(c)["look_id"]
        assert c.post("/confirm", json={"look_id": "nope", "make": "a", "model": "b"}).status_code == 404
        for bad in (
            {"look_id": look_id, "make": "  ", "model": "x"},
            {"look_id": look_id, "make": "x", "model": ""},
            {"look_id": look_id, "kind": "toaster", "make": "x", "model": "y"},
            {"look_id": look_id, "make": "x", "model": "y", "year_from": 1500},
        ):
            assert c.post("/confirm", json=bad).status_code == 422, bad
        assert c.post("/guess", json={"look_id": look_id, "guess_eur": 250}).status_code == 200
        locked = c.post("/confirm", json={"look_id": look_id, "make": "Bose", "model": "QC45"})
        assert locked.status_code == 409 and locked.json()["detail"]["status"] == "already_guessed"
        wait_for_price(c, look_id)


def test_discontinued_model_falls_back_to_the_used_price():
    """MacBook Air M2 in late 2026: no shop sells it new any more, only used and refurbished sellers."""
    used = offers(6, 520, 600, name="MacBook Air 13 M2 256GB", site="mresell.fi", cond="refurbished")
    other_new = offers(8, 1200, 1500, name="MacBook Air 13 M5 512GB", site="hintaopas.fi")  # a newer model
    r = compute_product_range(used + other_new, "MacBook Air 13 M2")
    assert r["price_basis"] == "used" and r["range"] and r["range"]["high"] <= 600
    assert r["used_range"] is None  # not shown twice
    assert any("only used or refurbished" in n for n in r["notes"])
    assert all(s["condition"] == "used" for s in r["sample"])


def test_new_offers_win_when_both_exist():
    r = compute_product_range(offers(8, 270, 330) + offers(5, 150, 190, site="swappie.com"), "WH-1000XM5")
    assert r["price_basis"] == "new" and r["range"]["low"] >= 270 and r["used_range"]


def test_nothing_at_all_is_still_insufficient():
    r = compute_product_range(offers(2, site="swappie.com"), "WH-1000XM5")
    assert r["range"] is None and r["price_basis"] == "new"


def test_laptop_ram_is_not_mistaken_for_a_second_size():
    laptops = [offer(i, 900 + i, name="MacBook Air 13 M2 8 Gt 256 Gt") for i in range(5)] + [
        offer(10 + i, 1000 + i, name="MacBook Air 13 M2 8 Gt 256 Gt") for i in range(3)
    ]
    r = compute_product_range(laptops, "MacBook Air 13 M2")
    assert not any("several sizes" in n for n in r["notes"])  # 8 Gt is RAM, every offer is the 256 Gt model
    assert products.main_storage("MacBook Air 8 Gt 1 Tt SSD") == "1tb"


# ------------------------------------------------------------------ generic items (any shop item)

CHAIR = (
    '{"kind":"item","make":null,"model":"wooden dining chair","variant":null,"year_range":null,'
    '"search_fi":"tammi ruokapöydän tuoli","confidence":0.6,"description":"A light oak dining chair with a curved back."}'
)
CHAIR_NAME = "Tammi ruokapöydän tuoli {}"


def chair_offers(count, low=40, high=160):
    return [offer(i, round(low + (high - low) * i / max(1, count - 1)), name=CHAIR_NAME.format(i), site="sotka.fi") for i in range(count)]


def test_generic_matching_handles_finnish_word_forms():
    q = "tammi ruokapöydän tuoli"
    assert matches_generic("Ruokapöydän tuolit tammi, 2 kpl", q)  # tuolit / tuoli
    assert matches_generic("Tammi tuoli Aino", q)  # half of the words are enough
    assert not matches_generic("Samsung televisio 55 tuumaa", q)
    assert not matches_generic("Pöytälamppu musta", q)
    assert matches_generic("anything at all", "")  # nothing to match against: keep it


def test_generic_item_range_is_marked_rough_and_drops_unrelated_offers():
    good = chair_offers(8)
    junk = [offer(i, 999, name="Samsung televisio", site="sotka.fi") for i in range(3)]
    out = compute_product_range(good + junk, "wooden dining chair", None, generic_query="tammi ruokapöydän tuoli")
    assert out["range"] and out["range"]["high"] < 999
    assert any("rough estimate" in n for n in out["notes"]) and any("unrelated" in n for n in out["notes"])


def test_item_stream_searches_the_finnish_phrase_and_prices_it():
    shop = FakeShop(shop_hits("sotka.fi"), {"https://sotka.fi/tuote/x": chair_offers(10)})
    snaps = asyncio.run(collect(price_product(shop, "item", "", "wooden dining chair", None, search="tammi ruokapöydän tuoli")))
    assert shop.queries == ["tammi ruokapöydän tuoli hinta"]
    assert snaps[-1]["status"] == "done" and snaps[-1]["range"]["n"] >= 8


def test_item_without_a_finnish_phrase_searches_by_name_and_brand():
    shop = FakeShop(shop_hits("sotka.fi"), {"https://sotka.fi/tuote/x": chair_offers(10)})
    asyncio.run(collect(price_product(shop, "item", "Brompton", "C Line folding bike")))
    assert shop.queries == ["Brompton C Line folding bike hinta"]


def test_look_prices_any_item_live():
    with TestClient(app) as c:
        app.state.nemotron = FakeNemotron(CHAIR)
        shop = FakeShop(shop_hits("sotka.fi"), {"https://sotka.fi/tuote/x": chair_offers(10)})
        app.state.price_source = shop
        first = look(c)
        assert first["identification"]["kind"] == "item" and first["identification"]["search_fi"] == "tammi ruokapöydän tuoli"
        assert first["price"]["status"] == "searching"  # a generic name is enough: no brand or model needed
        final = wait_for_price(c, first["look_id"])
        assert final["price"]["status"] == "done" and final["price"]["kind"] == "item"
        assert shop.queries == ["tammi ruokapöydän tuoli hinta"]


def test_an_unnamed_item_is_not_priced_but_can_be_named():
    unnamed = '{"kind":"item","make":null,"model":null,"variant":null,"year_range":null,"search_fi":null,"confidence":0.9,"description":"Something metal."}'
    with TestClient(app) as c:
        app.state.nemotron = FakeNemotron(unnamed)
        app.state.price_source = FakeShop(shop_hits("sotka.fi"), {"https://sotka.fi/tuote/x": chair_offers(10)})
        first = look(c)
        assert first["price"]["status"] == "skipped" and "tell me what it is" in first["price"]["reason"]
        # naming it needs no brand
        r = c.post("/confirm", json={"look_id": first["look_id"], "kind": "item", "model": "wooden dining chair"})
        assert r.status_code == 200 and r.json()["price"]["status"] == "searching"
        assert wait_for_price(c, first["look_id"])["price"]["status"] == "done"
        # brand is still required for the exact-model kinds
        other = look(c)
        assert c.post("/confirm", json={"look_id": other["look_id"], "kind": "headphones", "model": "WH-1000XM5"}).status_code == 422


def test_correcting_the_name_of_an_item_drops_the_old_search_phrase():
    with TestClient(app) as c:
        app.state.nemotron = FakeNemotron(CHAIR)
        shop = FakeShop(shop_hits("sotka.fi"), {"https://sotka.fi/tuote/x": chair_offers(10)})
        app.state.price_source = shop
        look_id = look(c)["look_id"]
        r = c.post("/confirm", json={"look_id": look_id, "kind": "item", "model": "bar stool"})
        assert r.json()["identification"]["search_fi"] is None
        wait_for_price(c, look_id)
        assert shop.queries[-1] == "bar stool hinta"
