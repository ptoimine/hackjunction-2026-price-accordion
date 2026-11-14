"""Tests for money.py: baskets, robust monthly figures, what a price means. No network, synthetic rows."""

import csv

import pytest

import money
from money import (
    BASKETS,
    Customer,
    MoneyBook,
    age_band,
    basket_of,
    build_profile,
    duration,
    item_basket,
    monthly_figures,
    price_context,
    typical,
    what_if,
)


def month(salary=2000.0, housing=800.0, utilities=100.0, groceries=300.0, transport=100.0, health=50.0, tech=50.0,
          restaurants=150.0, entertainment=80.0, lifestyle=60.0, travel=10.0, invest=0.0):
    return {
        "Salary": salary, "Housing": housing, "Utilities": utilities, "Groceries": groceries, "Transportation": transport,
        "Health": health, "Home & Tech": tech, "Restaurants": restaurants, "Entertainment": entertainment,
        "Lifestyle": lifestyle, "Travel": travel, "Invest Deposit": invest,
    }


def customer(months=None, age=28, balance=1500.0, cid="CUST00001"):
    return Customer(cid, age, "00100", balance, 100.0, 0.0, months if months is not None else [month() for _ in range(12)])


# ------------------------------------------------------------------------- arithmetic


def test_every_spending_category_is_in_exactly_one_basket():
    cats = [c for cs in BASKETS.values() for c in cs]
    assert len(cats) == len(set(cats)) == 10
    assert basket_of("Groceries") == "regular" and basket_of("Health") == "irregular" and basket_of("Restaurants") == "leaks"
    assert basket_of("Salary") is None and basket_of("Invest Deposit") is None  # income and savings are not spending


def test_typical_leaves_out_one_off_spikes():
    assert typical([100] * 11 + [15000]) == 100  # one 15,000 EUR month does not become the "typical" month
    assert typical([100, 120, 80]) == 100
    assert typical([]) == 0.0
    assert typical([0, 0, 0, 500]) == pytest.approx(125)  # median 0: nothing is dropped


def test_age_bands():
    assert [age_band(a) for a in (18, 24, 25, 34, 35, 64, 65, 90)] == ["18-24", "18-24", "25-34", "25-34", "35-44", "55-64", "65+", "65+"]


def test_monthly_figures_and_spare_money():
    f = monthly_figures([month() for _ in range(12)])
    assert f["income"] == 2000
    assert f["baskets"] == {"regular": 1300, "irregular": 100, "leaks": 300}
    assert f["spare"] == 300  # 2000 - 1300 - 100 - 300 - 0 saved


def test_savings_are_not_spare_money():
    f = monthly_figures([month(invest=200) for _ in range(12)])
    assert f["saved"] == 200 and f["spare"] == 100


def test_profile_shape_and_weekly_figures():
    p = build_profile(customer())
    assert p["per_month"]["spare"] == 300 and p["per_month"]["leaks"] == 300
    assert p["per_week"]["leaks"] == round(300 / (52 / 12)) == 69
    assert [b["id"] for b in p["baskets"]] == ["regular", "irregular", "leaks"]
    assert p["baskets"][2]["share_of_income_pct"] == 15
    assert any("synthetic" in n for n in p["notes"])
    assert p["balance_eur"] == 1500 and p["months_used"] == 12


def test_profile_with_short_history_and_no_spare_money_says_so():
    p = build_profile(customer([month(salary=1500) for _ in range(5)]))
    assert p["months_used"] == 5 and any("only 5 months" in n for n in p["notes"])
    assert p["per_month"]["spare"] < 0 and any("no spare money" in n for n in p["notes"])
    assert p["per_week"]["spare"] == 0  # never a negative allowance


def test_peer_comparison():
    peers = {"25-34": {"leaks_median": 200.0, "n": 600}}
    p = build_profile(customer(), peers)
    assert p["peers"]["leaks_vs_peers_pct"] == 50  # 300 vs 200
    assert "peers" not in build_profile(customer(age=70), peers)


# ------------------------------------------------------------------ what a price means


def test_item_baskets_are_a_rule_of_thumb():
    assert item_basket("car", 20000)["id"] == "irregular"
    assert item_basket("headphones", 299)["id"] == "leaks"
    assert item_basket("phone", 800)["id"] == "irregular" and item_basket("phone", 150)["id"] == "leaks"
    assert item_basket("item", 40)["id"] == "leaks" and item_basket("item", 400)["id"] == "irregular"
    assert all(item_basket(k, 100)["why"] for k in ("car", "phone", "laptop", "headphones", "item"))


def test_what_if_cutting_leaks():
    p = build_profile(customer())
    out = what_if(p, 20, price_eur=720)
    assert out["saving_per_month"] == 60 and out["saving_per_year"] == 720
    assert out["months_to_afford"] == 2.0  # 720 / (300 spare + 60)
    broke = what_if(build_profile(customer([month(salary=100)] * 12)), 20, 120)  # no spare money at all
    assert broke["months_to_afford"] == 2.0  # only the freed 60 a month counts, never a negative spare


def test_verdicts_from_cheap_to_out_of_reach():
    p = build_profile(customer())  # spare 300 a month, 69 a week
    assert price_context(p, 50, "item")["verdict"] == "fits-this-week"
    assert price_context(p, 250, "item")["verdict"] == "fits-this-month"
    assert price_context(p, 900, "item")["verdict"] == "save-up"
    assert price_context(p, 5000, "item")["verdict"] == "out-of-reach"
    assert price_context(build_profile(customer([month(salary=1000)] * 12)), 50, "item")["verdict"] == "no-room"


def test_context_numbers():
    p = build_profile(customer())
    c = price_context(p, 299, "headphones", "Sony WH-1000XM5")
    assert c["basket"]["id"] == "leaks" and c["name"] == "Sony WH-1000XM5"
    assert c["weeks_of_leaks"] == round(299 / 69, 1) == 4.3
    assert c["pct_of_monthly_income"] == 15 and c["pct_of_spare_money"] == 100 and c["months_to_save"] == 1.0
    assert c["leaks_time"] == "about 4 weeks" and c["save_time"] == "about 4 weeks"
    assert price_context(build_profile(customer([month(salary=1000)] * 12)), 50, "item")["save_time"] is None  # no spare money
    assert c["balance_after_purchase_eur"] == 1201 and c["would_overdraw"] is False
    assert c["what_if_cut_leaks_20"]["saving_per_month"] == 60


def test_overdraft_is_flagged():
    c = price_context(build_profile(customer(balance=100)), 299, "headphones")
    assert c["would_overdraw"] is True and "below zero" in c["summary"]


def test_summary_reads_like_a_person_and_uses_sensible_units():
    p = build_profile(customer())
    assert price_context(p, 299, "headphones")["summary"].startswith("€299 is about 4 weeks of what you spend on everyday leaks.")
    assert "years" in price_context(p, 28500, "car")["summary"]
    assert "less than a week" in price_context(p, 20, "item")["summary"]
    s = price_context(p, 900, "item")["summary"]
    assert "saving" in s and "Cutting everyday leaks by 20% would free €60 a month" in s


def test_duration_wording():
    assert duration(0.1) == "less than a week" and duration(0.25) == "a week" and duration(1.0) == "4 weeks"
    assert duration(5) == "5 months" and duration(30) == "2.5 years" and duration(200) == "17 years"


# ------------------------------------------------------------------------------- data


@pytest.fixture
def data_dir(tmp_path):
    with open(tmp_path / "customers.csv", "w", encoding="utf-8-sig", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["customer_id", "customer_age", "customer_postal_code", "last_balance_eur", "lowest_balance_eur", "share_overdrawn"])
        for i, age in enumerate([23, 27, 31, 45, 70], start=1):
            w.writerow([f"CUST{i:05d}", age, "00100", 1000 + i, -50, 0.02])
    with open(tmp_path / "monthly.csv", "w", encoding="utf-8-sig", newline="") as fh:
        cols = ["Salary", "Housing", "Utilities", "Groceries", "Transportation", "Health", "Home & Tech", "Restaurants", "Entertainment", "Lifestyle", "Travel", "Invest Deposit"]
        w = csv.writer(fh)
        w.writerow(["customer_id", "month"] + cols)
        for i in range(1, 6):
            for m in range(12):
                row = month(salary=1800 + 300 * i, restaurants=100 + 40 * i)
                w.writerow([f"CUST{i:05d}", f"2026-{m + 1:02d}"] + [row.get(c, 0.0) for c in cols])
    return tmp_path


def test_loading_and_profiles(data_dir):
    book = MoneyBook(data_dir)
    assert len(book.customers) == 5 and len(book.customers["CUST00002"].months) == 12
    p = book.profile("CUST00002")
    assert p["customer_id"] == "CUST00002" and p["per_month"]["income"] == 2400 and p["age"] == 27
    assert book.profile("CUST99999") is None
    assert book.profile("CUST00002") is book.profile("CUST00002")  # cached
    assert p["peers"]["age_band"] == "25-34" and p["peers"]["n"] == 2


def test_personas_are_young_adults_ordered_by_spare_money(data_dir):
    book = MoneyBook(data_dir)
    assert {p["slot"] for p in book.personas} <= {"tight", "typical", "comfortable"}
    assert all(22 <= p["age"] <= 34 for p in book.personas)  # the 45 and 70 year olds are never picked
    spare = [p["spare_per_month"] for p in book.personas]
    assert spare == sorted(spare)
