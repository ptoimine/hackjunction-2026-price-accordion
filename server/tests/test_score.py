"""Tests for score.py and POST /guess (no network)."""

import time

import pytest
from fastapi.testclient import TestClient

import score
from main import app
from test_price import GOOD_CAR, FakeNemotron, FakeSource, category_hits, jpeg, many, wait_for_price

RANGE = {"low": 13_000, "median": 15_700, "high": 18_900}


def test_exact_guess_scores_100_and_is_close():
    r = score.guess_result(15_700, RANGE)
    assert r["score"] == 100 and r["verdict"] == "close" and r["in_range"] is True
    assert r["gap_eur"] == 0 and r["gap_pct"] == 0.0


def test_within_five_percent_is_close():
    assert score.guess_result(16_400, RANGE)["verdict"] == "close"  # +4.5%
    assert score.guess_result(16_600, RANGE)["verdict"] == "high"  # +5.7%


def test_high_and_low_inside_the_range():
    hi = score.guess_result(18_000, RANGE)
    assert hi["verdict"] == "high" and hi["in_range"] and hi["gap_pct"] == pytest.approx(14.6, abs=0.1)
    assert "inside the real range, 15% above the median" in hi["summary"]
    lo = score.guess_result(13_500, RANGE)
    assert lo["verdict"] == "low" and lo["in_range"]
    assert "below the median" in lo["summary"]


def test_outside_the_range_says_how_far():
    r = score.guess_result(10_200, RANGE)  # 35% below 15,700
    assert r["verdict"] == "low" and r["in_range"] is False and r["gap_pct"] == pytest.approx(-35.0, abs=0.1)
    assert "You were 35% low." in r["summary"]
    assert r["gap_eur"] == -5_500


def test_score_is_zero_at_half_or_double_and_ordered_in_between():
    assert score.guess_result(7_850, RANGE)["score"] == 0  # half
    assert score.guess_result(31_400, RANGE)["score"] == 0  # double
    assert score.guess_result(100_000, RANGE)["score"] == 0  # absurd, never negative
    near, mid, far = (score.guess_result(g, RANGE)["score"] for g in (16_000, 20_000, 28_000))
    assert 100 > near > mid > far > 0


def test_summary_is_a_complete_sentence_with_rounded_numbers():
    s = score.guess_result(18_000, {"low": 12_980, "median": 15_700, "high": 18_860})["summary"]
    assert s.startswith("You guessed €18,000. The real range is €13,000 to €18,900, median €15,700.")


# ------------------------------------------------------------------------------ endpoint


def look_with_price(c):
    app.state.nemotron = FakeNemotron(GOOD_CAR)
    app.state.price_source = FakeSource(category_hits("a.fi"), {"https://a.fi/vaihtoautot/honda/hr-v": many(12, site="a.fi")})
    first = c.post("/look", content=jpeg(), headers={"Content-Type": "image/jpeg"}).json()
    return first["look_id"]


def test_guess_flow_before_and_after_the_price_is_final():
    with TestClient(app) as c:
        look_id = look_with_price(c)
        assert c.get(f"/look/{look_id}").json()["guess"] is None  # nothing guessed yet

        r = c.post("/guess", json={"look_id": look_id, "guess_eur": 18_000})
        assert r.status_code == 200 and r.json()["guess"]["guess_eur"] == 18_000

        final = wait_for_price(c, look_id)
        assert final["price"]["status"] == "done"
        guess = final["guess"]
        assert guess["guess_eur"] == 18_000
        assert guess["result"]["verdict"] in ("close", "high", "low")
        assert guess["result"]["summary"].startswith("You guessed €18,000.")
        assert 0 <= guess["result"]["score"] <= 100


def test_guess_cannot_be_changed_but_can_be_repeated():
    with TestClient(app) as c:
        look_id = look_with_price(c)
        assert c.post("/guess", json={"look_id": look_id, "guess_eur": 12_000}).status_code == 200
        assert c.post("/guess", json={"look_id": look_id, "guess_eur": 12_000}).status_code == 200  # retry is fine
        changed = c.post("/guess", json={"look_id": look_id, "guess_eur": 20_000})
        assert changed.status_code == 409 and changed.json()["detail"]["guess_eur"] == 12_000
        wait_for_price(c, look_id)
        assert c.get(f"/look/{look_id}").json()["guess"]["guess_eur"] == 12_000


@pytest.mark.parametrize("body", [{"look_id": "x", "guess_eur": 0}, {"look_id": "x", "guess_eur": -5}, {"look_id": "x", "guess_eur": 10**9}, {"look_id": "x"}, {"guess_eur": 5}])
def test_guess_validation(body):
    with TestClient(app) as c:
        assert c.post("/guess", json=body).status_code == 422


def test_guess_for_unknown_look_and_for_unpriceable_look():
    with TestClient(app) as c:
        assert c.post("/guess", json={"look_id": "nope", "guess_eur": 5_000}).status_code == 404
        app.state.nemotron = FakeNemotron('{"kind":"other","make":null,"model":null,"year_range":null,"confidence":0.9,"description":"A plant."}')
        app.state.price_source = FakeSource([], {})
        look_id = c.post("/look", content=jpeg(), headers={"Content-Type": "image/jpeg"}).json()["look_id"]
        r = c.post("/guess", json={"look_id": look_id, "guess_eur": 5_000})
        assert r.status_code == 400 and "no price to guess" in r.json()["detail"]


def test_summary_says_when_the_range_is_for_used_ones():
    used = score.guess_result(600, {"low": 500, "median": 550, "high": 600}, "used")["summary"]
    assert "The real range for used ones is €500 to €600, median €550." in used
    new = score.guess_result(600, {"low": 500, "median": 550, "high": 600})["summary"]
    assert "The real range is €500 to €600" in new
