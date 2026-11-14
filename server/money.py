"""money: what a price means for *your* money (S-Pankki synthetic data, pure Python).

CLAUDE.md rule 2: every figure here is plain arithmetic on the customer's own monthly history; the language
model (coach.py) only explains these numbers, it never computes them. The data is synthetic (Junction 2026
S-Pankki challenge): never describe it as real customers.

The three baskets of the teaching model are OUR mapping from the dataset's 15 categories:
  regular    mandatory, every month: housing, utilities, groceries, transportation
  irregular  mandatory, lumpy: health, home & tech (the broken washing machine, the dentist)
  leaks      everyday leaks / discretionary: restaurants, entertainment, lifestyle, travel
Savings moves (investment deposits) and income are kept apart: they are not spending.
"""

from __future__ import annotations

import csv
import statistics
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = REPO_ROOT / "data" / "spankki"

BASKETS: dict[str, tuple[str, ...]] = {
    "regular": ("Housing", "Utilities", "Groceries", "Transportation"),
    "irregular": ("Health", "Home & Tech"),
    "leaks": ("Restaurants", "Entertainment", "Lifestyle", "Travel"),
}
BASKET_TITLES = {
    "regular": "Mandatory, regular",
    "irregular": "Mandatory, irregular",
    "leaks": "Everyday leaks",
}
INCOME_COLUMNS = ("Salary", "Other Income")
SAVING_COLUMN = "Invest Deposit"
MONTHS_USED = 12  # the latest twelve months of the history
OUTLIER_FACTOR = 3.0  # a month above 3x the median is a one-off (a 15,000 EUR purchase) and left out of "typical"
WEEKS_PER_MONTH = 52 / 12


# ---------------------------------------------------------------------------- arithmetic


def typical(values: list[float]) -> float:
    """A typical month: the mean of the months, leaving out one-off spikes (above 3x the median)."""
    values = [float(v) for v in values]
    if not values:
        return 0.0
    median = statistics.median(values)
    kept = [v for v in values if median <= 0 or v <= median * OUTLIER_FACTOR] or values
    return sum(kept) / len(kept)


def age_band(age: int) -> str:
    for upper, label in ((24, "18-24"), (34, "25-34"), (44, "35-44"), (54, "45-54"), (64, "55-64")):
        if age <= upper:
            return label
    return "65+"


def basket_of(category: str) -> str | None:
    for basket, categories in BASKETS.items():
        if category in categories:
            return basket
    return None


@dataclass
class Customer:
    customer_id: str
    age: int
    postal_code: str
    last_balance_eur: float
    lowest_balance_eur: float
    share_overdrawn: float
    months: list[dict[str, float]] = field(default_factory=list)  # newest last; category -> euros that month

    def recent(self, n: int = MONTHS_USED) -> list[dict[str, float]]:
        return self.months[-n:]


def monthly_figures(months: list[dict[str, float]]) -> dict:
    """Income, the three baskets and what is left, per month, from the customer's recent months."""
    income = typical([sum(m.get(c, 0.0) for c in INCOME_COLUMNS) for m in months])
    baskets = {b: typical([sum(m.get(c, 0.0) for c in cats) for m in months]) for b, cats in BASKETS.items()}
    saved = typical([m.get(SAVING_COLUMN, 0.0) for m in months])
    spare = income - sum(baskets.values()) - saved
    leaks_by_category = {c: typical([m.get(c, 0.0) for m in months]) for c in BASKETS["leaks"]}
    return {"income": income, "baskets": baskets, "saved": saved, "spare": spare, "leaks_by_category": leaks_by_category}


def build_profile(customer: Customer, peers: dict | None = None) -> dict:
    """Everything the phone and the coach need about one customer's typical month."""
    months = customer.recent()
    f = monthly_figures(months)
    leaks_week = f["baskets"]["leaks"] / WEEKS_PER_MONTH
    notes: list[str] = ["synthetic data: the Junction 2026 S-Pankki challenge dataset, not a real customer"]
    if len(months) < MONTHS_USED:
        notes.append(f"only {len(months)} months of history")
    if f["spare"] <= 0:
        notes.append("a typical month leaves no spare money after the must-pay costs, everyday spending and savings")
    profile = {
        "customer_id": customer.customer_id,
        "age": customer.age,
        "age_band": age_band(customer.age),
        "months_used": len(months),
        "currency": "EUR",
        "per_month": {
            "income": round(f["income"]),
            "regular": round(f["baskets"]["regular"]),
            "irregular": round(f["baskets"]["irregular"]),
            "leaks": round(f["baskets"]["leaks"]),
            "saved": round(f["saved"]),
            "spare": round(f["spare"]),
        },
        "baskets": [
            {
                "id": b,
                "title": BASKET_TITLES[b],
                "per_month": round(f["baskets"][b]),
                "share_of_income_pct": round(100 * f["baskets"][b] / f["income"]) if f["income"] > 0 else None,
                "categories": list(BASKETS[b]),
            }
            for b in ("regular", "irregular", "leaks")
        ],
        "per_week": {"leaks": round(leaks_week), "spare": round(max(0.0, f["spare"]) / WEEKS_PER_MONTH)},
        "leaks_by_category": {c: round(v) for c, v in f["leaks_by_category"].items()},
        "balance_eur": round(customer.last_balance_eur),
        "share_of_days_overdrawn_pct": round(100 * customer.share_overdrawn),
        "notes": notes,
    }
    if peers and customer.age and peers.get(age_band(customer.age)):
        median_leaks = peers[age_band(customer.age)]["leaks_median"]
        profile["peers"] = {
            "age_band": age_band(customer.age),
            "leaks_median_per_month": round(median_leaks),
            "leaks_vs_peers_pct": round(100 * (f["baskets"]["leaks"] - median_leaks) / median_leaks) if median_leaks > 0 else None,
            "n": peers[age_band(customer.age)]["n"],
        }
    return profile


# ----------------------------------------------------------------- what a price means


def item_basket(kind: str, price_eur: float) -> dict:
    """Which basket a purchase belongs to: a rule of thumb for teaching, not a verdict."""
    if kind == "car":
        return {"id": "irregular", "title": BASKET_TITLES["irregular"], "why": "a big, lumpy cost: plan for it instead of letting it slip through"}
    if kind in ("phone", "laptop") and price_eur >= 250:
        return {"id": "irregular", "title": BASKET_TITLES["irregular"], "why": "a replacement you may really need, but it arrives as one lump"}
    if kind == "item" and price_eur >= 100:
        return {"id": "irregular", "title": BASKET_TITLES["irregular"], "why": "a lumpy purchase: plan for it"}
    return {"id": "leaks", "title": BASKET_TITLES["leaks"], "why": "a want more than a need: this is the money that slips through your fingers"}


def what_if(profile: dict, cut_pct: float, price_eur: float | None = None) -> dict:
    """Cut everyday leaks by `cut_pct` percent: what that frees per month and per year (and months to afford the price)."""
    leaks = profile["per_month"]["leaks"]
    saving = leaks * cut_pct / 100
    out = {"cut_pct": cut_pct, "saving_per_month": round(saving), "saving_per_year": round(saving * 12)}
    if price_eur is not None:
        spare_after = max(0.0, profile["per_month"]["spare"]) + saving
        out["months_to_afford"] = round(price_eur / spare_after, 1) if spare_after > 0 else None
    return out


WHAT_IF_PERCENTS = (10, 20, 30, 50)


def what_if_table(profile: dict) -> dict:
    """Every what-if the coach may quote, precomputed: cutting each leak category (or all of them) by 10-50 %.
    The model only ever reads this table, so a "what if I cut dining out by 20%?" answer is arithmetic done here."""
    table: dict[str, dict[str, int]] = {}
    for category, monthly in profile.get("leaks_by_category", {}).items():
        table[category] = {f"{pct}%": round(monthly * pct / 100) for pct in WHAT_IF_PERCENTS}
    table["all everyday leaks"] = {f"{pct}%": round(profile["per_month"]["leaks"] * pct / 100) for pct in WHAT_IF_PERCENTS}
    return table


def price_context(profile: dict, price_eur: float, kind: str = "item", name: str | None = None, basis: str = "new") -> dict:
    """What a price means for this customer: basket, weeks of leaks, share of spare money, a verdict, the what-if."""
    per_month, per_week = profile["per_month"], profile["per_week"]
    income, spare, leaks_week = per_month["income"], per_month["spare"], per_week["leaks"]
    basket = item_basket(kind, price_eur)

    weeks_of_leaks = round(price_eur / leaks_week, 1) if leaks_week > 0 else None
    pct_of_income = round(100 * price_eur / income) if income > 0 else None
    pct_of_spare = round(100 * price_eur / spare) if spare > 0 else None
    months_to_save = round(price_eur / spare, 1) if spare > 0 else None

    if spare <= 0:
        verdict = "no-room"
    elif price_eur <= per_week["spare"]:
        verdict = "fits-this-week"
    elif price_eur <= spare:
        verdict = "fits-this-month"
    elif price_eur <= spare * 6:
        verdict = "save-up"
    else:
        verdict = "out-of-reach"

    balance_after = profile["balance_eur"] - price_eur
    cut = what_if(profile, 20, price_eur)
    ctx = {
        "price_eur": round(price_eur),
        "name": name,
        "kind": kind,
        "price_basis": basis,
        "basket": basket,
        "weeks_of_leaks": weeks_of_leaks,
        # ready-made phrases ("about 4 weeks"), so every screen words the same numbers the same way
        "leaks_time": _about(duration(weeks_of_leaks / WEEKS_PER_MONTH)) if weeks_of_leaks is not None else None,
        "save_time": _about(duration(months_to_save)) if months_to_save is not None else None,
        "pct_of_monthly_income": pct_of_income,
        "pct_of_spare_money": pct_of_spare,
        "months_to_save": months_to_save,
        "verdict": verdict,
        "balance_after_purchase_eur": round(balance_after),
        "would_overdraw": balance_after < 0,
        "what_if_cut_leaks_20": cut,
    }
    ctx["summary"] = summarize(profile, ctx)
    return ctx


def duration(months: float) -> str:
    """'3 weeks', '5 months', '16 years': a length of time a person can picture."""
    if months < 2:
        weeks = months * WEEKS_PER_MONTH
        return f"{weeks:.0f} weeks" if weeks >= 1.5 else "a week" if weeks >= 0.75 else "less than a week"
    if months < 24:
        return f"{months:.0f} months"
    years = months / 12
    return f"{years:.0f} years" if years >= 10 else f"{years:.1f} years"


def _about(text: str) -> str:
    return text if text.startswith("less than") else f"about {text}"


def summarize(profile: dict, ctx: dict) -> str:
    """A ready-made, plain-language answer built only from the numbers above (the phone and the lens read it)."""
    per_month = profile["per_month"]
    price = f"€{ctx['price_eur']:,}"
    parts: list[str] = []
    if ctx["weeks_of_leaks"] is not None:
        parts.append(f"{price} is {_about(duration(ctx['weeks_of_leaks'] / WEEKS_PER_MONTH))} of what you spend on everyday leaks")
    else:
        parts.append(f"{price} is {ctx['pct_of_monthly_income']}% of a month's income")
    verdict = ctx["verdict"]
    if verdict == "no-room":
        parts.append("A typical month leaves you no spare money, so it would come from savings or an overdraft")
    elif verdict == "fits-this-week":
        parts.append(f"It fits in this week's spare money (about €{profile['per_week']['spare']})")
    elif verdict == "fits-this-month":
        parts.append(f"It takes {ctx['pct_of_spare_money']}% of your spare €{per_month['spare']} a month")
    elif verdict == "save-up":
        parts.append(f"With €{per_month['spare']} spare a month, that is {_about(duration(ctx['months_to_save']))} of saving")
    else:
        parts.append(f"With €{per_month['spare']} spare a month it is out of reach for now ({duration(ctx['months_to_save'])} of saving)")
    cut = ctx["what_if_cut_leaks_20"]
    if verdict in ("save-up", "out-of-reach", "no-room") and cut["saving_per_month"] > 0:
        tail = f", so it would take {_about(duration(cut['months_to_afford']))}" if cut.get("months_to_afford") else ""
        parts.append(f"Cutting everyday leaks by 20% would free €{cut['saving_per_month']} a month{tail}")
    if ctx["would_overdraw"]:
        parts.append("Paying now would put your account below zero")
    return ". ".join(parts) + "."


# ------------------------------------------------------------------------------ data


def load_customers(data_dir: Path | None = None) -> dict[str, Customer]:
    """Read the two small tables made by scripts/build_money_profiles.py."""
    base = data_dir or DATA_DIR
    customers: dict[str, Customer] = {}
    with open(base / "customers.csv", encoding="utf-8-sig", newline="") as fh:
        for row in csv.DictReader(fh):
            customers[row["customer_id"]] = Customer(
                customer_id=row["customer_id"],
                age=int(float(row["customer_age"] or 0)),
                postal_code=row.get("customer_postal_code", ""),
                last_balance_eur=float(row.get("last_balance_eur") or 0),
                lowest_balance_eur=float(row.get("lowest_balance_eur") or 0),
                share_overdrawn=float(row.get("share_overdrawn") or 0),
            )
    with open(base / "monthly.csv", encoding="utf-8-sig", newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            customer = customers.get(row["customer_id"])
            if customer is None:
                continue
            customer.months.append({k: float(v) for k, v in row.items() if k not in ("customer_id", "month") and v not in ("", None)})
    return customers


def peer_stats(customers: dict[str, Customer]) -> dict[str, dict]:
    """Median everyday-leaks spend per age band, from the customers' own typical months."""
    by_band: dict[str, list[float]] = {}
    for c in customers.values():
        if c.months and c.age:
            by_band.setdefault(age_band(c.age), []).append(monthly_figures(c.recent())["baskets"]["leaks"])
    return {b: {"leaks_median": statistics.median(v), "n": len(v)} for b, v in by_band.items() if v}


PERSONA_SLOTS = (("tight", 0.15, "Tight month"), ("typical", 0.5, "Typical"), ("comfortable", 0.85, "Comfortable"))


def pick_personas(customers: dict[str, Customer], min_age: int = 22, max_age: int = 34) -> list[dict]:
    """Three young adults (22-34) for the demo, from tight to comfortable spare money (deterministic)."""
    young = [c for c in customers.values() if min_age <= c.age <= max_age and len(c.months) >= MONTHS_USED]
    if not young:
        return []
    scored = sorted(((monthly_figures(c.recent())["spare"], c) for c in young), key=lambda t: (t[0], t[1].customer_id))
    personas, used = [], set()
    for slot, quantile, label in PERSONA_SLOTS:
        spare, customer = scored[min(len(scored) - 1, int(quantile * len(scored)))]
        if customer.customer_id in used:
            continue
        used.add(customer.customer_id)
        personas.append({"slot": slot, "label": label, "customer_id": customer.customer_id, "age": customer.age, "spare_per_month": round(spare)})
    return personas


class MoneyBook:
    """The loaded data: profiles by customer id, peers and the demo personas. Built once, then read-only."""

    def __init__(self, data_dir: Path | None = None) -> None:
        self.customers = load_customers(data_dir)
        self.peers = peer_stats(self.customers)
        self.personas = pick_personas(self.customers)
        self._profiles: dict[str, dict] = {}

    def profile(self, customer_id: str) -> dict | None:
        customer = self.customers.get(customer_id)
        if customer is None or not customer.months:
            return None
        if customer_id not in self._profiles:
            self._profiles[customer_id] = build_profile(customer, self.peers)
        return self._profiles[customer_id]
