-- =====================================================================
-- 01_data_quality_checks.sql
-- Audits the raw H&M data before any business analysis.
-- Each check documents WHAT is tested; findings and handling are
-- summarized in README.md (Data Quality section).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Row counts & grain
--    If row_count = distinct_keys, the ID column is a true unique key.
-- ---------------------------------------------------------------------
SELECT 'articles' AS table_name, COUNT(*) AS row_count, COUNT(DISTINCT article_id) AS distinct_keys FROM articles
UNION ALL
SELECT 'customers', COUNT(*), COUNT(DISTINCT customer_id) FROM customers
UNION ALL
SELECT 'transactions', COUNT(*), NULL FROM transactions;

-- ---------------------------------------------------------------------
-- 2. Duplicates
--    The transactions file has no quantity column: each row is one unit.
--    Identical rows (same day, customer, article, price, channel) are
--    therefore most likely multi-unit purchases, not load errors.
-- ---------------------------------------------------------------------
WITH dup_groups AS (
    SELECT t_dat, customer_id, article_id, price, sales_channel_id,
           COUNT(*) AS n
    FROM transactions
    GROUP BY t_dat, customer_id, article_id, price, sales_channel_id
    HAVING COUNT(*) > 1
)
SELECT COUNT(*)                 AS duplicate_groups,
       SUM(n)                   AS rows_in_duplicate_groups,
       SUM(n - 1)               AS extra_rows_beyond_first,
       MAX(n)                   AS max_units_same_line,
       ROUND(100.0 * SUM(n - 1) / (SELECT COUNT(*) FROM transactions), 2) AS pct_extra_rows
FROM dup_groups;

-- Distribution of repeat counts (are these plausible basket quantities?)
SELECT n AS units_on_same_line, COUNT(*) AS groups
FROM (
    SELECT COUNT(*) AS n
    FROM transactions
    GROUP BY t_dat, customer_id, article_id, price, sales_channel_id
) AS line_counts
WHERE n > 1
GROUP BY n
ORDER BY n
LIMIT 10;

-- ---------------------------------------------------------------------
-- 3. Missing IDs
-- ---------------------------------------------------------------------
SELECT
    SUM(CASE WHEN customer_id IS NULL OR customer_id = '' THEN 1 ELSE 0 END) AS missing_customer_id,
    SUM(CASE WHEN article_id  IS NULL OR article_id  = '' THEN 1 ELSE 0 END) AS missing_article_id,
    SUM(CASE WHEN t_dat       IS NULL THEN 1 ELSE 0 END)                     AS missing_date,
    SUM(CASE WHEN price       IS NULL THEN 1 ELSE 0 END)                     AS missing_price,
    SUM(CASE WHEN sales_channel_id IS NULL THEN 1 ELSE 0 END)                AS missing_channel
FROM transactions;

-- ---------------------------------------------------------------------
-- 4. Referential integrity - transactions that don't map to master data
--    LEFT JOIN keeps every transaction; if nothing matched on the right
--    side, the right-side ID is NULL -> that row is an orphan.
-- ---------------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM transactions t
       LEFT JOIN articles a ON t.article_id = a.article_id
      WHERE a.article_id IS NULL)                         AS txn_article_not_in_articles,
    (SELECT COUNT(*) FROM transactions t
       LEFT JOIN customers c ON t.customer_id = c.customer_id
      WHERE c.customer_id IS NULL)                        AS txn_customer_not_in_customers,
    (SELECT COUNT(*) FROM articles a
      WHERE NOT EXISTS (SELECT 1 FROM transactions t WHERE t.article_id = a.article_id))
                                                          AS articles_never_sold;

-- ---------------------------------------------------------------------
-- 5. Missing / placeholder product classifications
-- ---------------------------------------------------------------------
SELECT
    SUM(CASE WHEN department_name   IS NULL THEN 1 ELSE 0 END)                                  AS null_department,
    SUM(CASE WHEN garment_group_name IS NULL OR garment_group_name = 'Unknown' THEN 1 ELSE 0 END) AS unknown_garment_group,
    SUM(CASE WHEN section_name      IS NULL THEN 1 ELSE 0 END)                                  AS null_section,
    SUM(CASE WHEN product_type_name IS NULL OR product_type_name = 'Unknown' THEN 1 ELSE 0 END)  AS unknown_product_type,
    SUM(CASE WHEN product_group_name IN ('Unknown', 'Undefined') THEN 1 ELSE 0 END)             AS unknown_product_group,
    SUM(CASE WHEN colour_group_name IN ('Unknown', 'Undefined') THEN 1 ELSE 0 END)              AS unknown_colour,
    SUM(CASE WHEN detail_desc       IS NULL THEN 1 ELSE 0 END)                                  AS missing_description
FROM articles;

-- ---------------------------------------------------------------------
-- 6. Dates - range, gaps, and anything unexpected
--    Subtracting two dates gives the number of days between them.
-- ---------------------------------------------------------------------
SELECT MIN(t_dat)                   AS first_date,
       MAX(t_dat)                   AS last_date,
       COUNT(DISTINCT t_dat)        AS days_with_sales,
       MAX(t_dat) - MIN(t_dat) + 1  AS calendar_days
FROM transactions;

-- Lowest-volume days (possible gaps / partial loads / store closures)
SELECT t_dat, COUNT(*) AS units
FROM transactions
GROUP BY t_dat
ORDER BY units
LIMIT 5;

-- ---------------------------------------------------------------------
-- 7. Prices - zero / negative / distribution
--    NOTE: H&M scaled the price column; it is NOT a real currency amount.
--    PERCENTILE_CONT(0.5) = the median.
-- ---------------------------------------------------------------------
SELECT
    SUM(CASE WHEN price <= 0 THEN 1 ELSE 0 END)            AS zero_or_negative_price,
    MIN(price)                                              AS min_price,
    PERCENTILE_CONT(0.01) WITHIN GROUP (ORDER BY price)     AS p01,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY price)     AS median,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY price)     AS p99,
    MAX(price)                                              AS max_price
FROM transactions;

-- ---------------------------------------------------------------------
-- 8. Price outliers - IQR rule, and articles whose price varies wildly
-- ---------------------------------------------------------------------
WITH quartiles AS (
    SELECT PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY price) AS q1,
           PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY price) AS q3
    FROM transactions
)
SELECT
    SUM(CASE WHEN t.price > q.q3 + 3 * (q.q3 - q.q1) THEN 1 ELSE 0 END) AS extreme_high_price_rows,
    ROUND(100.0 * SUM(CASE WHEN t.price > q.q3 + 3 * (q.q3 - q.q1) THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_rows
FROM transactions t
CROSS JOIN quartiles q;   -- quartiles has one row, so this just attaches q1/q3 to every transaction

-- Articles sold at very different prices (markdowns vs. data issues?)
SELECT a.article_id, a.prod_name, a.product_type_name,
       COUNT(*)                              AS units,
       ROUND(MIN(t.price), 4)                AS min_price,
       ROUND(MAX(t.price), 4)                AS max_price,
       ROUND(MAX(t.price) / MIN(t.price), 1) AS max_to_min_ratio
FROM transactions t
JOIN articles a ON t.article_id = a.article_id
GROUP BY a.article_id, a.prod_name, a.product_type_name
HAVING COUNT(*) >= 100
ORDER BY max_to_min_ratio DESC
LIMIT 10;

-- Rows priced far below the article's own median price.
-- <10% of median is too deep to be a normal markdown -> treat as suspect.
WITH article_median AS (
    SELECT article_id,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY price) AS median_price
    FROM transactions
    GROUP BY article_id
)
SELECT
    SUM(CASE WHEN t.price < 0.10 * m.median_price THEN 1 ELSE 0 END) AS rows_below_10pct_of_median,
    SUM(CASE WHEN t.price < 0.25 * m.median_price THEN 1 ELSE 0 END) AS rows_below_25pct_of_median,
    ROUND(100.0 * SUM(CASE WHEN t.price < 0.10 * m.median_price THEN 1 ELSE 0 END) / COUNT(*), 3) AS pct_suspect
FROM transactions t
JOIN article_median m ON t.article_id = m.article_id;

-- ---------------------------------------------------------------------
-- 9. Sales channel values
-- ---------------------------------------------------------------------
SELECT sales_channel_id, COUNT(*) AS units,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_units
FROM transactions
GROUP BY sales_channel_id
ORDER BY sales_channel_id;

-- =====================================================================
-- HANDLING -> build the clean analysis table used by files 02-06
--
--   * Duplicate rows are KEPT: with no quantity column, repeated lines
--     represent multiple units in the same purchase.
--   * Rows priced < 10% of the article's median price are EXCLUDED
--     (~0.03% of rows) as suspect price records.
--   * "Unknown" product classifications are KEPT as their own bucket.
--   * Weeks are counted backwards from the last date in the data, so the
--     most recent week (weeks_ago = 0) is a full 7 days.
-- =====================================================================
DROP TABLE IF EXISTS fact_sales;
CREATE TABLE fact_sales AS
WITH article_median AS (
    SELECT article_id,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY price) AS median_price
    FROM transactions
    GROUP BY article_id
),
last_date AS (
    SELECT MAX(t_dat) AS max_date FROM transactions      -- 2020-09-22
),
with_weeks AS (
    SELECT
        t.*,
        -- days before the last date, divided into 7-day blocks: 0 = final week
        CAST(FLOOR((d.max_date - t.t_dat) / 7.0) AS INTEGER) AS weeks_ago,
        d.max_date
    FROM transactions t
    CROSS JOIN last_date d
)
SELECT
    w.t_dat                                                   AS sale_date,
    w.max_date - 6 - 7 * w.weeks_ago                          AS week_start,   -- first day of that 7-day week
    CAST(DATE_TRUNC('month', w.t_dat) AS DATE)                AS month_start,
    w.weeks_ago,
    w.customer_id,
    w.article_id,
    w.price,
    CASE w.sales_channel_id WHEN 1 THEN 'Store' WHEN 2 THEN 'Online' END AS channel,
    a.prod_name,
    a.product_type_name,
    a.product_group_name,
    a.colour_group_name,
    a.perceived_colour_master_name,
    a.graphical_appearance_name,
    a.department_name,
    a.section_name,
    a.garment_group_name,
    a.index_group_name
FROM with_weeks w
JOIN article_median m ON w.article_id = m.article_id    -- to filter out suspect prices
JOIN articles a       ON w.article_id = a.article_id    -- to attach product attributes
WHERE w.price >= 0.10 * m.median_price;

SELECT COUNT(*) AS clean_rows,
       (SELECT COUNT(*) FROM transactions) - COUNT(*) AS excluded_rows,
       MIN(week_start) AS first_week, MAX(week_start) AS last_week
FROM fact_sales;

-- ---------------------------------------------------------------------
-- 10. Classification drift - are newer sales missing product types?
--     Compares the share of units with an "Unknown" product type in the
--     last 4 weeks vs. the same 4 weeks a year earlier.
-- ---------------------------------------------------------------------
SELECT
    CASE WHEN weeks_ago BETWEEN 0 AND 3 THEN 'Last 4 weeks'
         ELSE 'Same 4 weeks last year' END                                        AS period,
    COUNT(*)                                                                      AS units,
    ROUND(100.0 * SUM(CASE WHEN product_type_name = 'Unknown' THEN 1 ELSE 0 END)
          / COUNT(*), 2)                                                          AS pct_units_unknown_type,
    COUNT(DISTINCT CASE WHEN product_type_name = 'Unknown' THEN article_id END)   AS unknown_type_skus
FROM fact_sales
WHERE weeks_ago BETWEEN 0 AND 3
   OR weeks_ago BETWEEN 52 AND 55
GROUP BY CASE WHEN weeks_ago BETWEEN 0 AND 3 THEN 'Last 4 weeks'
              ELSE 'Same 4 weeks last year' END
ORDER BY period;
