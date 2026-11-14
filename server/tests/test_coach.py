"""Tests for coach.py and the /money and /coach endpoints. No network; a fake model and temp money data."""

import csv

import pytest
from fastapi.testclient import TestClient

import money
from main import app
from nemotron import NemotronError, NemotronTimeout
from test_money import customer, month
from test_price import FakeNemotron, jpeg, wait_for_price
from test_products import FakeShop, chair_offers, shop_hits


@pytest.fixture
def book(tmp_path):
    cols = ["Salary", "Housing", "Utilities", "Groceries", "Transportation", "Health", "Home & Tech", "Restaurants", "Entertainment", "Lifestyle", "Travel", "Invest Deposit"]
    with open(tmp_path / "customers.csv", "w", encoding="utf-8-sig", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["customer_id", "customer_age", "customer_postal_code", "last_balance_eur", "lowest_balance_eur", "share_overdrawn"])
        for i, age in enumerate([23, 27, 31, 45], start=1):
            w.writerow([f"CUST{i:05d}", age, "00100", 1500, -50, 0.02])
    with open(tmp_path / "monthly.csv", "w", encoding="utf-8-sig", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["customer_id", "month"] + cols)
        for i in range(1, 5):
            for m in range(12):
                row = month(salary=1500 + 400 * i)
                w.writerow([f"CUST{i:05d}", f"2026-{m + 1:02d}"] + [row.get(c, 0.0) for c in cols])
    return money.MoneyBook(tmp_path)


class RecordingModel:
    def __init__(self, text="Your everyday leaks are the basket that matters here. Try setting aside one coffee a week."):
        self.text, self.prompts, self.systems = text, [], []

    async def chat(self, prompt, **kw):
        self.prompts.append(prompt)
        self.systems.append(kw.get("system"))
        from nemotron import NemotronReply

        return NemotronReply(text=self.text, model="fake", cached=False, attempts=1, latency_s=0.1)

    async def aclose(self):
        pass


class FailingModel:
    async def chat(self, prompt, **kw):
        raise NemotronTimeout("slow")

    async def aclose(self):
        pass


@pytest.fixture(autouse=True)
def _restore_app_state():
    """These tests swap fakes onto the shared app: put everything back so other test files see what they expect."""
    names = ("money", "nemotron", "price_source", "looks")
    missing = object()
    saved = {n: getattr(app.state, n, missing) for n in names}
    yield
    for n, v in saved.items():
        if v is missing:
            if hasattr(app.state, n):
                delattr(app.state, n)
        else:
            setattr(app.state, n, v)


def test_personas_and_profile(book):
    with TestClient(app) as c:
        app.state.money = book
        personas = c.get("/money/personas").json()
        assert personas["personas"] and "synthetic" in personas["data"]
        cid = personas["personas"][0]["customer_id"]
        profile = c.get("/money/profile", params={"customer_id": cid}).json()
        assert profile["customer_id"] == cid and profile["per_month"]["income"] > 0
        assert c.get("/money/profile").json()["customer_id"]  # no id: the "typical" persona
        assert c.get("/money/profile", params={"customer_id": "NOPE"}).status_code == 404


def test_money_data_missing_is_a_clear_503(tmp_path, monkeypatch):
    with TestClient(app) as c:
        app.state.money = None
        monkeypatch.setattr(money, "DATA_DIR", tmp_path)
        r = c.get("/money/personas")
        assert r.status_code == 503 and "build_money_profiles" in r.json()["detail"]["message"]


def test_context_for_a_price(book):
    with TestClient(app) as c:
        app.state.money = book
        r = c.post("/money/context", json={"customer_id": "CUST00002", "price_eur": 299, "kind": "headphones", "name": "Sony WH-1000XM5"})
        body = r.json()
        assert r.status_code == 200 and body["context"]["price_eur"] == 299 and body["context"]["basket"]["id"] == "leaks"
        assert body["context"]["summary"].startswith("€299 is ") and body["profile"]["customer_id"] == "CUST00002"
        assert c.post("/money/context", json={"customer_id": "CUST00002"}).status_code == 422  # no price
        assert c.post("/money/context", json={"customer_id": "CUST00002", "price_eur": -5}).status_code == 422


def test_context_for_a_finished_look_uses_its_median(book):
    chair = (
        '{"kind":"item","make":null,"model":"wooden dining chair","variant":null,"year_range":null,'
        '"search_fi":"tammi ruokapöydän tuoli","confidence":0.6,"description":"An oak chair."}'
    )
    with TestClient(app) as c:
        app.state.money = book
        app.state.nemotron = FakeNemotron(chair)
        app.state.price_source = FakeShop(shop_hits("sotka.fi"), {"https://sotka.fi/tuote/x": chair_offers(10)})
        look = c.post("/look", content=jpeg(), headers={"Content-Type": "image/jpeg"}).json()
        early = c.post("/money/context", json={"customer_id": "CUST00001", "look_id": look["look_id"]})
        final = wait_for_price(c, look["look_id"])
        r = c.post("/money/context", json={"customer_id": "CUST00001", "look_id": look["look_id"]})
        assert r.status_code == 200
        ctx = r.json()["context"]
        assert ctx["price_eur"] == final["price"]["range"]["median"] and ctx["kind"] == "item" and ctx["name"] == "wooden dining chair"
        assert early.status_code in (200, 409)  # 409 while no range yet, 200 once the first pages answered
        assert c.post("/money/context", json={"customer_id": "CUST00001", "look_id": "nope"}).status_code == 404


def test_coach_answers_from_the_model_and_shows_its_numbers(book):
    model = RecordingModel()
    with TestClient(app) as c:
        app.state.money, app.state.nemotron = book, model
        r = c.post("/coach", json={"customer_id": "CUST00002", "question": "Can I afford these headphones?", "price_eur": 299, "kind": "headphones", "name": "Sony WH-1000XM5"})
        body = r.json()
        assert r.status_code == 200 and body["source"] == "nemotron" and body["answer"].startswith("Your everyday leaks")
        assert body["basket"]["id"] == "leaks" and body["context"]["price_eur"] == 299
        assert body["numbers"]["typical_month"]["money_in_per_month"] == 2300
        assert body["numbers"]["thing_being_considered"]["in_short"] == body["context"]["summary"]
        # the model was given the facts and told not to calculate
        prompt, system = model.prompts[0], model.systems[0]
        assert '"price_eur": 299' in prompt and "what_if_savings_per_month" in prompt and "Can I afford these headphones?" in prompt
        assert "NEVER do arithmetic" in system and "must agree with it" in system and "in_short" in prompt


def test_coach_without_a_price_talks_about_the_month(book):
    model = RecordingModel("You have a bit of room each month.")
    with TestClient(app) as c:
        app.state.money, app.state.nemotron = book, model
        body = c.post("/coach", json={"customer_id": "CUST00002", "question": "What kind of spender am I?"}).json()
        assert body["source"] == "nemotron" and body["basket"] is None and body["context"] is None
        assert "thing_being_considered" not in body["numbers"] and "typical_month" in body["numbers"]


def test_coach_falls_back_to_the_computed_sentence(book):
    with TestClient(app) as c:
        app.state.money, app.state.nemotron = book, FailingModel()
        body = c.post("/coach", json={"customer_id": "CUST00002", "question": "Can I afford it?", "price_eur": 299, "kind": "headphones"}).json()
        assert body["source"] == "fallback" and body["answer"] == body["context"]["summary"] and "unavailable" in body["note"]
        app.state.nemotron = None
        body = c.post("/coach", json={"customer_id": "CUST00002", "question": "How am I doing?"}).json()
        assert body["source"] == "fallback" and "comes in" in body["answer"]


def test_coach_validates_input(book):
    with TestClient(app) as c:
        app.state.money, app.state.nemotron = book, RecordingModel()
        assert c.post("/coach", json={"customer_id": "CUST00002", "question": "x"}).status_code == 422
        assert c.post("/coach", json={"customer_id": "NOPE", "question": "hello there"}).status_code == 404


def test_facts_contain_only_computed_numbers(book):
    import coach

    profile = book.profile("CUST00002")
    block = coach.facts(profile, money.price_context(profile, 299, "headphones", "Sony"))
    table = block["what_if_savings_per_month"]
    assert set(table) >= {"Restaurants", "Entertainment", "Lifestyle", "Travel", "all everyday leaks"}
    assert table["Restaurants"]["20%"] == round(profile["leaks_by_category"]["Restaurants"] * 0.2)
    assert block["thing_being_considered"]["basket"] == "Everyday leaks"
