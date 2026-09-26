# Data

The raw data is **not** stored in this repo (the transactions file alone is ~3.5 GB).

## Source

**H&M Personalized Fashion Recommendations** (Kaggle), public data released by H&M Group:
https://www.kaggle.com/competitions/h-and-m-personalized-fashion-recommendations/data

## Setup

1. Accept the competition rules on Kaggle and download the data.
2. Place these files in `data/raw/`:

| File | Rows | Used for |
|---|---|---|
| `transactions_train.csv` | 31,788,324 | Sales facts: date, customer, article, price, channel |
| `articles.csv` | 105,542 | Product hierarchy & attributes |
| `customers.csv` | 1,371,980 | Data-quality check only (customer IDs resolve) |
| `sample_submission.csv` | - | Not used (Kaggle competition file) |

3. From the repo root run `.\run_all.ps1` (or run the files in `sql/` in order with the DuckDB CLI).

## Notes on the data

- **One row = one unit.** There is no quantity column; the same item bought twice in one purchase appears as two identical rows.
- **Prices are scaled.** H&M transformed the `price` column, so it is not a real currency amount. "Sales" in this project is a relative index.
- **Date range:** 2018-09-20 to 2020-09-22 (734 days, no missing days).
- **Channels:** `sales_channel_id` 1 = Store, 2 = Online (common interpretation; not officially documented by H&M).
