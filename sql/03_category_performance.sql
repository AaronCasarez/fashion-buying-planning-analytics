-- =====================================================================
-- 03_category_performance.sql
-- Q: Which departments, garment groups, sections and product types are
--    performing best / worst?
--
-- Window: last 52 weeks (weeks_ago 0-51) vs. the prior 52 weeks.
-- "Productivity" = units per active SKU, so large categories don't win
-- just because they carry more options.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. One long table covering all four hierarchy levels
--    UNION ALL stacks the same sales four times, once per level, so a
--    single GROUP BY can summarize every level at once.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS category_performance;
CREATE TABLE category_performance AS
WITH levels AS (
    SELECT 'Department' AS level, department_name AS category, weeks_ago, article_id, price
    FROM fact_sales WHERE weeks_ago <= 103
    UNION ALL
    SELECT 'Garment Group', garment_group_name, weeks_ago, article_id, price
    FROM fact_sales WHERE weeks_ago <= 103
    UNION ALL
    SELECT 'Section', section_name, weeks_ago, article_id, price
    FROM fact_sales WHERE weeks_ago <= 103
    UNION ALL
    SELECT 'Product Type', product_type_name, weeks_ago, article_id, price
    FROM fact_sales WHERE weeks_ago <= 103
),
agg AS (
    SELECT
        level,
        category,
        SUM(CASE WHEN weeks_ago <= 51 THEN price END)                   AS sales_l52w,
        COUNT(CASE WHEN weeks_ago <= 51 THEN 1 END)                     AS units_l52w,
        COUNT(DISTINCT CASE WHEN weeks_ago <= 51 THEN article_id END)   AS active_skus_l52w,
        SUM(CASE WHEN weeks_ago >= 52 THEN price END)                   AS sales_p52w
    FROM levels
    GROUP BY level, category
)
SELECT
    level,
    category,
    ROUND(sales_l52w, 2)                                                     AS sales_l52w,
    units_l52w,
    active_skus_l52w,
    ROUND(1.0 * units_l52w / NULLIF(active_skus_l52w, 0), 1)                 AS units_per_sku,
    ROUND(sales_l52w / NULLIF(units_l52w, 0), 5)                             AS asp,
    ROUND(100.0 * sales_l52w / SUM(sales_l52w) OVER (PARTITION BY level), 2) AS sales_share_pct,
    ROUND(100.0 * (sales_l52w / NULLIF(sales_p52w, 0) - 1), 1)               AS sales_yoy_pct,
    RANK() OVER (PARTITION BY level ORDER BY COALESCE(sales_l52w, 0) DESC)   AS sales_rank
FROM agg;

-- ---------------------------------------------------------------------
-- 2. Top 10 per level by sales
-- ---------------------------------------------------------------------
SELECT level, sales_rank, category, sales_l52w, sales_share_pct, units_per_sku, sales_yoy_pct
FROM category_performance
WHERE sales_rank <= 10
ORDER BY level, sales_rank;

-- ---------------------------------------------------------------------
-- 3. Biggest YoY gainers and decliners (material categories only:
--    >= 0.5% share of the level so tiny categories don't dominate)
-- ---------------------------------------------------------------------
WITH material AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY level ORDER BY sales_yoy_pct DESC) AS best_rn,
           ROW_NUMBER() OVER (PARTITION BY level ORDER BY sales_yoy_pct ASC)  AS worst_rn
    FROM category_performance
    WHERE sales_share_pct >= 0.5
      AND sales_yoy_pct IS NOT NULL
)
SELECT level,
       CASE WHEN best_rn <= 5 THEN 'Top YoY growth' ELSE 'Largest YoY decline' END AS bucket,
       category, sales_share_pct, sales_yoy_pct, units_per_sku
FROM material
WHERE best_rn <= 5 OR worst_rn <= 5
ORDER BY level, bucket DESC, sales_yoy_pct DESC;

-- ---------------------------------------------------------------------
-- 4. Productivity: departments that sell the most per option vs. the
--    least (>= 50 active SKUs so the ratio is meaningful)
-- ---------------------------------------------------------------------
SELECT category AS department, active_skus_l52w, units_l52w, units_per_sku,
       NTILE(4) OVER (ORDER BY units_per_sku DESC) AS productivity_quartile
FROM category_performance
WHERE level = 'Department'
  AND active_skus_l52w >= 50
ORDER BY units_per_sku DESC;
