"""Boil the 346 MB S-Pankki transaction file down to two small tables the coach reads.

    cd server && uv run python scripts/build_money_profiles.py

Writes (git-ignored, under data/spankki/):
  monthly.csv    one row per customer and month: money in and out per category (spend as positive euros)
  customers.csv  one row per customer: age, postal code, last balance, lowest balance, share of days overdrawn

The data is synthetic (Junction 2026 S-Pankki challenge). Python does all later arithmetic from these tables
(CLAUDE.md rule 2); no per-request scan of the raw rows.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "data" / "spankki"


def main() -> int:
    tx_path = SRC / "tx_junction_transactions.csv"
    if not tx_path.exists() or tx_path.stat().st_size < 1_000_000:
        print(f"{tx_path} is missing or only a Git LFS pointer; download the real file first", file=sys.stderr)
        return 1
    tx = pd.read_csv(
        tx_path,
        encoding="utf-8-sig",
        usecols=["customer_id", "tx_date", "category", "tx_amount_eur", "balance_after_eur"],
        dtype={"customer_id": "string", "category": "string", "tx_date": "string"},
    )
    tx["month"] = tx["tx_date"].str.slice(0, 7)
    # spend is positive euros out; income and transfers keep their own columns (savings moves are not spending)
    monthly = (
        tx.pivot_table(index=["customer_id", "month"], columns="category", values="tx_amount_eur", aggfunc="sum", fill_value=0.0)
        .reset_index()
    )
    income_cols = ["Salary", "Other Income", "Invest Withdraw"]
    transfer_cols = ["Invest Deposit", "Salary Sweep"]
    for col in monthly.columns[2:]:
        if col not in income_cols:
            monthly[col] = -monthly[col]  # out as positive
    for col in income_cols + transfer_cols:
        if col not in monthly.columns:
            monthly[col] = 0.0
    monthly = monthly.round(2)
    monthly.to_csv(SRC / "monthly.csv", index=False)

    tx = tx.sort_values(["customer_id", "tx_date"], kind="stable")
    last = tx.groupby("customer_id")["balance_after_eur"].last().rename("last_balance_eur")
    low = tx.groupby("customer_id")["balance_after_eur"].min().rename("lowest_balance_eur")
    overdrawn = (tx["balance_after_eur"] < 0).groupby(tx["customer_id"]).mean().rename("share_overdrawn")
    customers = pd.read_csv(SRC / "tx_customers_junction.csv", encoding="utf-8-sig", dtype={"customer_id": "string", "customer_postal_code": "string"})
    customers = customers.merge(pd.concat([last, low, overdrawn], axis=1).reset_index(), on="customer_id", how="left")
    customers.round(3).to_csv(SRC / "customers.csv", index=False)
    print(f"monthly.csv: {len(monthly):,} rows, {monthly['month'].min()} .. {monthly['month'].max()}; customers.csv: {len(customers):,} rows")
    print("columns:", list(monthly.columns))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
