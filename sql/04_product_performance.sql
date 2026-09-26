-- =====================================================================
-- 04_product_performance.sql
-- Q: Which individual SKUs drive the most demand? Which have low sales
--    velocity?
--
-- SKU = article_id (a specific style + colour).
-- Sales velocity = units / weeks on sale, where weeks on sale counts from
-- the SKU's first sale in the window through the final week. This avoids
-- penalising new launches that have only been on sale for a few weeks.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. SKU-level metrics for the last 12 weeks (current-season view)
--    Step 1: aggregate sales per article_id.
--    Step 2: join to the articles table to get product names/categories.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS sku_performance_l12w;
CREATE TABLE sku_performance_l12w AS
WITH sku_sales AS (
    SELECT
        article_id,
        COUNT(*)                    AS units,
        SUM(price)                  AS sales,
        MAX(weeks_ago) + 1          AS weeks_on_sale,   -- weeks since first sale in window
        COUNT(DISTINCT week_start)  AS weeks_with_sales
    FROM fact_sales
    WHERE weeks_ago <= 11
    GROUP BY article_id
),
sku AS (
    SELECT
        s.article_id,
        a.prod_name,
        a.product_type_name,
        a.department_name,
        a.section_name,
        a.garment_group_name,
        a.colour_group_name,
        s.units,
        s.sales,
        s.weeks_on_sale,
        s.weeks_with_sales,
        1.0 * s.units / s.weeks_on_sale AS velocity
    FROM sku_sales s
    JOIN articles a ON s.article_id = a.article_id
)
SELECT
    article_id, prod_name, product_type_name, department_name, section_name,
    garment_group_name, colour_group_name, units, sales, weeks_on_sale, weeks_with_sales,
    ROUND(velocity, 2)                                               AS units_per_week,
    ROUND(sales / units, 5)                                          AS asp,
    RANK()         OVER (ORDER BY units DESC)                        AS units_rank,
    -- 0 = slowest SKU, 1 = fastest SKU
    ROUND(PERCENT_RANK() OVER (ORDER BY velocity), 3)                AS velocity_pctile,
    -- running total of units, biggest sellers first, as a % of all units
    ROUND(100.0 * SUM(units) OVER (ORDER BY units DESC ROWS UNBOUNDED PRECEDING)
                / SUM(units) OVER (), 2)                             AS cumulative_units_pct
FROM sku;

-- ---------------------------------------------------------------------
-- 2. Top 25 demand drivers
-- ---------------------------------------------------------------------
SELECT units_rank, article_id, prod_name, product_type_name, department_name,
       colour_group_name, units, units_per_week, asp
FROM sku_performance_l12w
ORDER BY units_rank
LIMIT 25;

-- ---------------------------------------------------------------------
-- 3. Demand concentration (Pareto): how many SKUs make up 50% / 80%
--    of units?
-- ---------------------------------------------------------------------
SELECT
    COUNT(*)                                                   AS active_skus,
    COUNT(CASE WHEN cumulative_units_pct <= 50 THEN 1 END)     AS skus_for_50pct_units,
    COUNT(CASE WHEN cumulative_units_pct <= 80 THEN 1 END)     AS skus_for_80pct_units,
    ROUND(100.0 * COUNT(CASE WHEN cumulative_units_pct <= 80 THEN 1 END) / COUNT(*), 1) AS pct_skus_for_80pct_units
FROM sku_performance_l12w;

-- ---------------------------------------------------------------------
-- 4. Low-velocity SKUs: on sale >= 4 weeks and in the bottom 20% of
--    weekly velocity
-- ---------------------------------------------------------------------
SELECT
    COUNT(*)                          AS low_velocity_skus,
    ROUND(AVG(units_per_week), 2)     AS avg_units_per_week,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM sku_performance_l12w), 1) AS pct_of_active_skus
FROM sku_performance_l12w
WHERE weeks_on_sale >= 4
  AND velocity_pctile < 0.20;

-- Which departments carry the most low-velocity SKUs (share of their range)?
SELECT
    department_name,
    COUNT(*)                                                                    AS active_skus,
    COUNT(CASE WHEN weeks_on_sale >= 4 AND velocity_pctile < 0.20 THEN 1 END)   AS low_velocity_skus,
    ROUND(100.0 * COUNT(CASE WHEN weeks_on_sale >= 4 AND velocity_pctile < 0.20 THEN 1 END)
          / COUNT(*), 1)                                                        AS low_velocity_pct
FROM sku_performance_l12w
GROUP BY department_name
HAVING COUNT(*) >= 100
ORDER BY low_velocity_pct DESC
LIMIT 15;
