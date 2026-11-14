# S-Pankki synthetic data – summary

Source: Junction 2026 S-Pankki challenge dataset (synthetic, stored in `data/spankki/`, git-ignored).
Loaded with pandas, `encoding="utf-8-sig"` (every CSV starts with a UTF-8 BOM) and `dtype=str`
(postal codes have leading zeros, e.g. `00100`).

> **All four files are loaded.** `tx_junction_transactions.csv` was first only a 134-byte Git LFS
> pointer; the real file (362,796,501 bytes) was downloaded from the dataset's GitHub repo and its
> SHA-256 matches the pointer's `oid` (`49b3265d…1e63`).
>
> **Headline numbers:** 5,100 customers · **24 months** (2024-10-01 → 2026-09-30) · 3,626,755
> transactions · **15 categories** (10 spending, 5 income/transfer) · 36 MCC codes · 515 merchants.

## Files

| File | Rows | On disk | Contents |
| --- | ---: | --- | --- |
| `tx_customers_junction.csv` | 5,100 | OK | one row per customer |
| `mtg_tx_customer_link_and_final_mtg_infio.csv` | 200 | OK | 200 mortgage applications → customer, final outcome |
| `mtg_negotiation_history.csv` | 3,452 | OK | event log of those 200 applications |
| `tx_junction_transactions.csv` | 3,626,755 | OK (346 MB, verified) | account transactions, 24 months |

Join keys: `customer_id` (customers ↔ link ↔ transactions), `mortgage_customer_id` (link ↔ history).

## Customers (`tx_customers_junction.csv`)

| Column | Type | Notes |
| --- | --- | --- |
| `customer_id` | str | `CUST00001`…; 5,100 unique, no duplicates, no nulls |
| `customer_postal_code` | str (5 digits) | 290 distinct codes |
| `customer_age` | int | 18–90, mean 43.3, median 44 |

- **Number of customers: 5,100.**
- Age bands: 18–24: 419 · 25–34: 658 · 35–44: 1,616 · 45–54: 1,756 · 55–64: 376 · 65+: 275.
  So only **1,077 customers (21%) are under 35**, and the typical customer is in their 40s.
- Postal codes are all in the Helsinki region: `00xxx` 2,557 · `02xxx` 1,427 · `01xxx` 1,116.
  Most common codes: 00940 (99), 01300 (93), 02230 (86), 00980 (85), 01600 (72).

## Mortgage final outcome (`mtg_tx_customer_link_and_final_mtg_infio.csv`)

200 rows, one per `mortgage_customer_id` (`C0004`…), each linked to a distinct `customer_id`
(all 200 exist in the customers file). Mortgage customers are older than average: median 47, range 32–77.

| Column | Notes |
| --- | --- |
| `mortgage_customer_id`, `customer_id` | keys |
| `final_decision` | approved 150 · rejected 50 |
| `rejection_reason` | null for approved; else `insufficient_collateral` 34 · `insufficient_income` 8 · `insufficient_equity` 6 · `existing_debt` 2 |
| `final_property_price_eur` | 156,000 – 538,000 (median 255,750) |
| `final_requested_loan_eur` | 121,000 – 528,000 (median 230,250) |
| `final_equity_amount_eur` | 10,000 – 81,500 (median 34,750) |
| `final_collateral_value_eur` | 112,000 – 384,000 (median 185,000) |
| `required_monthly_income_eur` | 2,227 – 9,720 (median 4,239) |
| `lfinal_loan_to_value` | 0.76 – 0.98 (median 0.86); note the typo in the column name (`lfinal_`) |

## Mortgage negotiation history (`mtg_negotiation_history.csv`)

3,452 events for the same 200 applications (11–25 events each, mean 17.3).

| Column | Notes |
| --- | --- |
| `mortgage_customer_id` | key |
| `timestamp` | format `26MAY26:00:00:00` (`%d%b%y:%H:%M:%S`); range **2026-01-02 → 2026-09-10**, i.e. 9 calendar months (Sept has only 5 events) |
| `event_type` | `customer_contact` 791 · `expense_recorded` 495 · `property_added` 316 · `collateral_valuation` 314 · `application_created`, `loan_calculation`, `income_information_received`, `collateral_added`, `loan_decision` 200 each · `additional_collateral_requested` 192 · `property_price_updated` 188 · `document_received` 156 |
| `property_id`, `property_type` | `apartment` 477 · `terraced_house` 386 · `detached_house` 241 (null on other events) |
| `property_price_estimate`, `loan_amount`, `equity_amount` | EUR, only on the relevant events |
| `collateral_type`, `collateral_value`, `collateral_status` | `apartment` 600 · `other_apartment` 306; status `approved` 514 · `pending` 392 |
| `decision`, `rejection_reason` | on `loan_decision` events (approved 256 / rejected 80 across all rows) |
| `expense_type`, `expense_amount` | `valuation_fee`, `existing_loan`, `renovation`, `transfer_tax`, `maintenance_fee`, `bank_fee`; 0 – 30,000 EUR (median 450) |
| `note` | free text, 907 distinct English sentences |

This is a mortgage-process dataset; it is only loosely relevant to a spending coach.

## Transactions (`tx_junction_transactions.csv`)

3,626,755 rows, UTF-8 BOM, CRLF line endings, no exact duplicates, no unparseable dates.

| Column | Notes |
| --- | --- |
| `customer_id` | all 5,100 customers appear (and all exist in the customers file) |
| `bank_account_id` | `ACC000001`…; **exactly one account per customer** (5,100 accounts) |
| `tx_date` | `YYYY-MM-DD`, **2024-10-01 → 2026-09-30** |
| `tx_timestamp` | `03OCT24:09:04:04` (`%d%b%y:%H:%M:%S`); always the same day as `tx_date` |
| `category` | 15 values, see below |
| `tx_amount_eur` | signed: negative = money out (96.5% of rows), positive = money in; never 0 |
| `balance_after_eur` | account balance after the transaction. Verified: previous balance + amount = `balance_after_eur` for **every** row (per account, in time order) |
| `transaction_type` | 8 values; one per category, except `purchase` which covers 8 categories |
| `merchant_id`, `mcc_code` | only on `purchase` rows, and only on 94.6% of those (160,624 purchases have neither). Always both or neither |

**Months and customers:** 24 calendar months, ~150,000 transactions per month. 5,095 customers
have all 24 months, 5 have 23. Transactions per customer: median 700 (min 148, max 1,543).

### Categories (the "merchant categories")

| Category | Transactions | Avg amount | Customers | `transaction_type` |
| --- | ---: | ---: | ---: | --- |
| Groceries | 868,519 | -69.6 | 5,100 | purchase |
| Restaurants | 759,280 | -40.3 | 5,099 | purchase |
| Transportation | 626,930 | -45.3 | 5,100 | purchase |
| Utilities | 342,728 | -57.4 | 4,922 | `utilities_payment` (no merchant) |
| Entertainment | 302,691 | -59.7 | 5,095 | purchase |
| Health | 151,912 | -90.3 | 5,074 | purchase |
| Salary | 121,725 | +3,362 | 5,100 | `salary` |
| Home & Tech | 115,086 | -218.1 | 5,092 | purchase |
| Housing | 112,903 | -1,088.2 | 4,882 | `housing_payment` (no merchant) |
| Lifestyle | 110,916 | -202.0 | 5,100 | purchase |
| Travel | 65,377 | -242.8 | 5,040 | purchase |
| Invest Deposit | 35,668 | -358.0 | 1,500 | `investment_deposit` |
| Other Income | 6,299 | +2,656.8 | 2,401 | `other_income` |
| Salary Sweep | 6,189 | -3,825.5 | 264 | `salary_sweep` |
| Invest Withdraw | 532 | +1,567.7 | 435 | `investment_withdrawal` |

- **Spending categories (10):** Groceries, Restaurants, Transportation, Utilities, Entertainment,
  Health, Home & Tech, Housing, Lifestyle, Travel.
- **Income (2):** Salary, Other Income. **Transfers/saving (3):** Invest Deposit, Invest Withdraw,
  Salary Sweep. These should not be counted as spending.
- Merchants are `MRC-<3 letters>-<number>`; each merchant belongs to exactly one category (prefixes
  GRO, RES, TRN, ENT, HEA, HMT, LIF, TRV).
- The 36 MCC codes map to exactly one category each. Share of purchases without a merchant/MCC
  differs by category: Travel 14%, Transportation 12%, Health 12%, Lifestyle 6%, Home & Tech 6%,
  Entertainment 4%, Restaurants 2.5%, Groceries 1.5%. So **`category` is the reliable field; the
  merchant is optional.**

| Category | MCC codes (transactions with a merchant) |
| --- | --- |
| Groceries | 5411 (709k), 5499 (96k), 5422 (31k), 5451 (19k) |
| Restaurants | 5812 (439k), 5814 (255k), 5813 (47k) |
| Transportation | 7523 (134k), 5542 (134k), 4111 (113k), 5541 (112k), 4121 (59k) |
| Entertainment | 7922 (80k), 7999 (70k), 7832 (58k), 7991 (55k), 7996 (28k) |
| Health | 5912 (82k), 8011 (33k), 8099 (13k), 8021 (6k) |
| Home & Tech | 5200 (45k), 5732 (25k), 5251 (19k), 5712 (14k), 5734 (5k) |
| Lifestyle | 5941 (36k), 5651 (26k), 5999 (15k), 5691 (12k), 5942 (8k), 5945 (8k) |
| Travel | 4722 (18k), 4511 (16k), 7011 (15k), 7512 (7k) |

### What the amounts look like

- Purchases: median 47 EUR; 90% under 123; 99% under 550; 0.31% (9,325) over 1,000 and 104 over
  5,000, up to 30,935 (mostly Home & Tech, Lifestyle, Travel; also a handful of 15,000–20,000 EUR
  groceries/restaurant outliers). Outliers need handling before averages are shown.
- Within a category the average amount is almost the same for every MCC and merchant (e.g. all
  grocery MCCs average ~70 EUR). The data is synthetic: **spending depends on the category, not on
  which merchant**.
- **Salary:** exactly one payment per customer per month; median monthly salary per customer
  3,181 EUR (25%: 2,378, 75%: 4,037, max 15,062). Median monthly spending over the 10 spending
  categories: 2,723 EUR.
- **Housing:** one payment per month for the 4,882 customers who have it (218 have none, probably
  owners without a loan). Median 1,039 EUR/month. **Utilities:** usually three payments per
  month; median 159 EUR/month. Both are clean, recurring items.
- Median monthly spend by category (over customers): Housing 1,039 · Groceries 556 ·
  Transportation 329 · Restaurants 320 · Home & Tech 296 · Lifestyle 294 · Entertainment 264 ·
  Health 239 · Travel 233 · Utilities 159.
- **By age (median monthly salary / spending):** 18-24: 1,935 / 1,795 · 25-34: 2,242 / 2,010 ·
  35-44: 3,200 / 2,775 · 45-54: 3,661 / 3,166 · 55-64: 4,295 / 3,519 · 65+: 2,512 / 2,240.
  Young adults spend about 90% of their salary, which suits the coaching story.
- **Balances:** median balance 4,293 EUR, minimum -1,985. 2.5% of transactions leave a negative
  balance, and **3,526 customers (69%) are overdrawn at some point**.

### How the three baskets are mapped

The data has no basket field, so the mapping is our own (`server/money.py`, `BASKETS`): **regular mandatory** = Housing,
Utilities, Groceries, Transportation; **irregular mandatory** = Health, Home & Tech (lumpy); **everyday leaks** = Restaurants,
Entertainment, Lifestyle, Travel. Investment deposits are savings, not spending. The categories are coarse (15) and Groceries
and Transportation are arguably both needs and frequent small spend, so this is a judgement call, stated as one. Python does
all the arithmetic (CLAUDE.md rule 2).

## Things to keep in mind

- The data is synthetic; do not describe it as real customers.
- Age distribution skews older than the "young adults" persona, so the coach should not assume
  everyone is in their 20s; the 1,077 customers under 35 are the closest match.
- Transactions are large (346 MB, ~3.6M rows). Load once with explicit dtypes
  (`customer_id`, `bank_account_id`, `category`, `transaction_type`, `merchant_id`, `mcc_code` as str),
  and aggregate to a monthly per-customer table rather than querying the raw rows per request.
- Read with `utf-8-sig` and `dtype=str` for ids and postal codes.
