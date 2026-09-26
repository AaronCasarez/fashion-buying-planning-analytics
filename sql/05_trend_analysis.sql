-- =====================================================================
-- 05_trend_analysis.sql
-- Q: Which products / categories are growing or declining?
--
--   L4W = last 4 weeks        (weeks_ago 0-3,  2020-08-26 .. 2020-09-22)
--   P4W = previous 4 weeks    (weeks_ago 4-7,  2020-07-29 .. 2020-08-25)
--   LY4W = same 4 weeks last year (weeks_ago 52-55)
--
-- The data ends in late September, when the assortment shifts from
-- summer to autumn. L4W vs P4W therefore mixes real momentum with
-- seasonality, so category trends are also shown vs. LY to separate the two.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Category momentum: L4W vs P4W and L4W vs LY
--    Conditional aggregation: COUNT(CASE WHEN <period> THEN 1 END)
--    counts only the rows in that period, so all three periods are
--    calculated side by side in one pass.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS category_momentum;
CREATE TABLE category_momentum AS
WITH levels AS (
    SELECT 'Department' AS level, department_name AS category, weeks_ago FROM fact_sales WHERE weeks_ago <= 55
    UNION ALL
    SELECT 'Garment Group',       garment_group_name,          weeks_ago FROM fact_sales WHERE weeks_ago <= 55
    UNION ALL
    SELECT 'Product Type',        product_type_name,           weeks_ago FROM fact_sales WHERE weeks_ago <= 55
),
agg AS (
    SELECT
        level, category,
        COUNT(CASE WHEN weeks_ago BETWEEN 0  AND 3  THEN 1 END) AS units_l4w,
        COUNT(CASE WHEN weeks_ago BETWEEN 4  AND 7  THEN 1 END) AS units_p4w,
        COUNT(CASE WHEN weeks_ago BETWEEN 52 AND 55 THEN 1 END) AS units_ly4w
    FROM levels
    GROUP BY level, category
)
SELECT
    *,
    units_l4w - units_p4w                                            AS units_change,
    ROUND(100.0 * (1.0 * units_l4w / NULLIF(units_p4w, 0) - 1), 1)   AS pct_vs_p4w,
    ROUND(100.0 * (1.0 * units_l4w / NULLIF(units_ly4w, 0) - 1), 1)  AS pct_vs_ly,
    CASE
        WHEN units_l4w > units_p4w AND units_l4w > units_ly4w  THEN 'Growing (both)'
        WHEN units_l4w < units_p4w AND units_l4w < units_ly4w  THEN 'Declining (both)'
        WHEN units_l4w < units_p4w AND units_l4w >= units_ly4w THEN 'Seasonal dip (up vs LY)'
        ELSE 'Seasonal lift (down vs LY)'
    END                                                              AS trend_read
FROM agg;

-- Material product types (>= 2,000 units in P4W): biggest movers
SELECT category AS product_type, units_p4w, units_l4w, units_change, pct_vs_p4w, pct_vs_ly, trend_read
FROM category_momentum
WHERE level = 'Product Type' AND units_p4w >= 2000
ORDER BY pct_vs_p4w DESC;

-- Departments that are declining on BOTH comparisons (not just seasonal)
SELECT category AS department, units_ly4w, units_p4w, units_l4w, pct_vs_p4w, pct_vs_ly
FROM category_momentum
WHERE level = 'Department'
  AND trend_read = 'Declining (both)'
  AND units_p4w >= 2000
ORDER BY units_change
LIMIT 15;

-- ---------------------------------------------------------------------
-- 2. SKU momentum: L4W vs P4W
--    Aggregate per article_id, then join articles for names/categories.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS sku_momentum;
CREATE TABLE sku_momentum AS
WITH sku_units AS (
    SELECT
        article_id,
        COUNT(CASE WHEN weeks_ago BETWEEN 0 AND 3 THEN 1 END) AS units_l4w,
        COUNT(CASE WHEN weeks_ago BETWEEN 4 AND 7 THEN 1 END) AS units_p4w
    FROM fact_sales
    WHERE weeks_ago <= 7
    GROUP BY article_id
)
SELECT
    s.article_id,
    a.prod_name,
    a.product_type_name,
    a.department_name,
    s.units_l4w,
    s.units_p4w,
    ROUND(100.0 * (1.0 * s.units_l4w / NULLIF(s.units_p4w, 0) - 1), 1) AS pct_change
FROM sku_units s
JOIN articles a ON s.article_id = a.article_id;

-- Fastest-growing SKUs (by absolute unit gain).
-- Minimum 50 units in either period so small bases don't produce
-- meaningless +500% swings.
SELECT article_id, prod_name, product_type_name, department_name,
       units_p4w, units_l4w, units_l4w - units_p4w AS unit_gain, pct_change
FROM sku_momentum
WHERE units_l4w >= 50 OR units_p4w >= 50
ORDER BY unit_gain DESC
LIMIT 20;

-- Fastest-declining SKUs (by absolute unit loss)
SELECT article_id, prod_name, product_type_name, department_name,
       units_p4w, units_l4w, units_l4w - units_p4w AS unit_change, pct_change
FROM sku_momentum
WHERE units_l4w >= 50 OR units_p4w >= 50
ORDER BY unit_change
LIMIT 20;

-- ---------------------------------------------------------------------
-- 3. Rolling 4-week trend by index group (for trend lines)
--    The window averages this week and the 3 weeks before it.
-- ---------------------------------------------------------------------
WITH weekly AS (
    SELECT week_start, index_group_name, COUNT(*) AS units
    FROM fact_sales
    WHERE weeks_ago <= 25
    GROUP BY week_start, index_group_name
)
SELECT
    week_start,
    index_group_name,
    units,
    ROUND(AVG(units) OVER (PARTITION BY index_group_name ORDER BY week_start
                           ROWS BETWEEN 3 PRECEDING AND CURRENT ROW), 0) AS units_rolling_4w
FROM weekly
ORDER BY index_group_name, week_start;
