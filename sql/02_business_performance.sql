-- =====================================================================
-- 02_business_performance.sql
-- Q: How are sales, transactions, active SKUs and average selling
--    price trending by week / month?
--
-- Definitions (see documentation/KPI_DEFINITIONS.md)
--   Sales        = SUM(price)            -- scaled index, not real currency
--   Units        = COUNT(*)              -- one row = one unit
--   Transactions = distinct customer + date + channel (proxy for a basket)
--   Active SKUs  = distinct article_id with >= 1 unit sold in the period
--   ASP          = Sales / Units
--   ATV          = Sales / Transactions
--   UPT          = Units / Transactions
--
-- Note: "1.0 *" in divisions forces decimal math. Without it, some
-- databases (PostgreSQL, SQL Server) divide whole numbers as integers,
-- e.g. 7 / 2 = 3.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Weekly KPIs with week-over-week change
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS kpi_weekly;
CREATE TABLE kpi_weekly AS
WITH weekly_sales AS (
    SELECT
        week_start,
        SUM(price)                   AS sales,
        COUNT(*)                     AS units,
        COUNT(DISTINCT article_id)   AS active_skus,
        COUNT(DISTINCT customer_id)  AS active_customers
    FROM fact_sales
    GROUP BY week_start
),
-- One row per basket: a customer shopping on a given day in a given channel
baskets AS (
    SELECT DISTINCT week_start, customer_id, sale_date, channel
    FROM fact_sales
),
weekly_transactions AS (
    SELECT week_start, COUNT(*) AS transactions
    FROM baskets
    GROUP BY week_start
),
weekly AS (
    SELECT s.*, t.transactions
    FROM weekly_sales s
    JOIN weekly_transactions t ON s.week_start = t.week_start
)
SELECT
    week_start,
    ROUND(sales, 2)                                  AS sales,
    units,
    transactions,
    active_skus,
    active_customers,
    ROUND(sales / units, 5)                          AS asp,
    ROUND(sales / transactions, 5)                   AS atv,
    ROUND(1.0 * units / transactions, 2)             AS upt,
    -- LAG(x) = the value from the previous row (previous week)
    ROUND(100.0 * (sales / LAG(sales) OVER (ORDER BY week_start) - 1), 1)                          AS sales_wow_pct,
    ROUND(100.0 * (1.0 * transactions / LAG(transactions) OVER (ORDER BY week_start) - 1), 1)      AS transactions_wow_pct,
    -- LAG(x, 52) = the value from 52 rows back (same week last year)
    ROUND(100.0 * (sales / LAG(sales, 52) OVER (ORDER BY week_start) - 1), 1)                      AS sales_yoy_pct
FROM weekly
ORDER BY week_start;

SELECT * FROM kpi_weekly ORDER BY week_start DESC LIMIT 12;

-- ---------------------------------------------------------------------
-- 2. Monthly KPIs with month-over-month and year-over-year change
--    The data starts 2018-09-20 and ends 2020-09-22, so Sep-2018 and
--    Sep-2020 are partial months and are not compared.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS kpi_monthly;
CREATE TABLE kpi_monthly AS
WITH monthly_sales AS (
    SELECT
        month_start,
        SUM(price)                  AS sales,
        COUNT(*)                    AS units,
        COUNT(DISTINCT article_id)  AS active_skus,
        COUNT(DISTINCT sale_date)   AS selling_days
    FROM fact_sales
    GROUP BY month_start
),
baskets AS (
    SELECT DISTINCT month_start, customer_id, sale_date, channel
    FROM fact_sales
),
monthly_transactions AS (
    SELECT month_start, COUNT(*) AS transactions
    FROM baskets
    GROUP BY month_start
),
monthly AS (
    SELECT s.*,
           t.transactions,
           CASE WHEN s.month_start IN (DATE '2018-09-01', DATE '2020-09-01') THEN 1 ELSE 0 END AS is_partial_month
    FROM monthly_sales s
    JOIN monthly_transactions t ON s.month_start = t.month_start
),
-- Flag comparisons where either month is partial (not like-for-like)
flagged AS (
    SELECT *,
           CASE WHEN is_partial_month = 1
                  OR LAG(is_partial_month) OVER (ORDER BY month_start) = 1
                THEN 1 ELSE 0 END AS mom_invalid,
           CASE WHEN is_partial_month = 1
                  OR LAG(is_partial_month, 12) OVER (ORDER BY month_start) = 1
                THEN 1 ELSE 0 END AS yoy_invalid
    FROM monthly
)
SELECT
    month_start,
    selling_days,
    is_partial_month,
    ROUND(sales, 2)                          AS sales,
    units,
    transactions,
    active_skus,
    ROUND(sales / units, 5)                  AS asp,
    ROUND(sales / transactions, 5)           AS atv,
    ROUND(1.0 * units / transactions, 2)     AS upt,
    CASE WHEN mom_invalid = 0
         THEN ROUND(100.0 * (sales / LAG(sales) OVER (ORDER BY month_start) - 1), 1) END      AS sales_mom_pct,
    CASE WHEN yoy_invalid = 0
         THEN ROUND(100.0 * (sales / LAG(sales, 12) OVER (ORDER BY month_start) - 1), 1) END  AS sales_yoy_pct,
    -- ASP is a ratio, so it is still comparable on partial months
    ROUND(100.0 * (sales / units)
          / (LAG(sales, 12) OVER (ORDER BY month_start) / LAG(units, 12) OVER (ORDER BY month_start)) - 100, 1) AS asp_yoy_pct
FROM flagged
ORDER BY month_start;

SELECT * FROM kpi_monthly;

-- ---------------------------------------------------------------------
-- 3. Year-over-year summary: last 52 weeks vs. prior 52 weeks
-- ---------------------------------------------------------------------
WITH labeled AS (
    SELECT
        CASE WHEN weeks_ago BETWEEN 0  AND 51  THEN 'L52W'
             WHEN weeks_ago BETWEEN 52 AND 103 THEN 'P52W' END AS period,
        customer_id, sale_date, channel, article_id, price
    FROM fact_sales
    WHERE weeks_ago <= 103
),
period_sales AS (
    SELECT period,
           SUM(price)                 AS sales,
           COUNT(*)                   AS units,
           COUNT(DISTINCT article_id) AS active_skus
    FROM labeled
    GROUP BY period
),
period_transactions AS (
    SELECT period, COUNT(*) AS transactions
    FROM (SELECT DISTINCT period, customer_id, sale_date, channel FROM labeled) AS baskets
    GROUP BY period
)
SELECT
    s.period,
    ROUND(s.sales, 0)                          AS sales,
    s.units,
    t.transactions,
    s.active_skus,
    ROUND(s.sales / s.units, 5)                AS asp,
    ROUND(1.0 * s.units / t.transactions, 2)   AS upt
FROM period_sales s
JOIN period_transactions t ON s.period = t.period
ORDER BY s.period;

-- ---------------------------------------------------------------------
-- 4. Channel mix by month (Store vs. Online)
-- ---------------------------------------------------------------------
SELECT
    month_start,
    ROUND(100.0 * SUM(CASE WHEN channel = 'Online' THEN price END) / SUM(price), 1) AS online_sales_share_pct,
    ROUND(SUM(CASE WHEN channel = 'Online' THEN price END) / COUNT(CASE WHEN channel = 'Online' THEN 1 END), 5) AS online_asp,
    ROUND(SUM(CASE WHEN channel = 'Store'  THEN price END) / COUNT(CASE WHEN channel = 'Store'  THEN 1 END), 5) AS store_asp
FROM fact_sales
GROUP BY month_start
ORDER BY month_start;
