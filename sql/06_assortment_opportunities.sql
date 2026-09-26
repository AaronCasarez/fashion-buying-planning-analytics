-- =====================================================================
-- 06_assortment_opportunities.sql
-- Q1: Do certain garment types, colours, patterns or other product
--     attributes show stronger demand?
-- Q2: Flag SKUs for the Buying & Planning team to look at:
--     High Performer / Growing / Declining-Watch / Low Velocity
--
-- Requires tables built in 04 (sku_performance_l12w) and 05 (sku_momentum).
-- =====================================================================

-- ---------------------------------------------------------------------
-- PART A - Attribute demand (last 12 weeks)
-- Units per SKU normalises for how many options carry that attribute:
-- an attribute with few SKUs but high units/SKU is under-assorted
-- relative to demand; many SKUs with low units/SKU may be over-assorted.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS attribute_demand;
CREATE TABLE attribute_demand AS
WITH attrs AS (
    SELECT 'Colour'      AS attribute, colour_group_name            AS value, article_id FROM fact_sales WHERE weeks_ago <= 11
    UNION ALL
    SELECT 'Colour Tone',              perceived_colour_master_name,          article_id FROM fact_sales WHERE weeks_ago <= 11
    UNION ALL
    SELECT 'Pattern',                  graphical_appearance_name,             article_id FROM fact_sales WHERE weeks_ago <= 11
    UNION ALL
    SELECT 'Product Group',            product_group_name,                    article_id FROM fact_sales WHERE weeks_ago <= 11
    UNION ALL
    SELECT 'Index Group',              index_group_name,                      article_id FROM fact_sales WHERE weeks_ago <= 11
),
agg AS (
    SELECT attribute, value,
           COUNT(*)                   AS units,
           COUNT(DISTINCT article_id) AS active_skus
    FROM attrs
    GROUP BY attribute, value
),
shares AS (
    SELECT
        attribute,
        value,
        units,
        active_skus,
        100.0 * units       / SUM(units)       OVER (PARTITION BY attribute) AS unit_share,
        100.0 * active_skus / SUM(active_skus) OVER (PARTITION BY attribute) AS sku_share
    FROM agg
)
SELECT
    attribute,
    value,
    units,
    active_skus,
    ROUND(1.0 * units / active_skus, 1)  AS units_per_sku,
    ROUND(unit_share, 1)                 AS unit_share_pct,
    ROUND(sku_share, 1)                  AS sku_share_pct,
    -- > 1.0 = attribute sells more than its share of the assortment
    ROUND(unit_share / sku_share, 2)     AS demand_index
FROM shares;

-- Material values only (>= 1% of SKUs), strongest and weakest per attribute
SELECT attribute, value, active_skus, units, units_per_sku, unit_share_pct, sku_share_pct, demand_index
FROM attribute_demand
WHERE sku_share_pct >= 1
ORDER BY attribute, demand_index DESC;

-- ---------------------------------------------------------------------
-- PART B - SKU flags
--
--   High Performer   : top 5% of active SKUs by L4W units
--   Growing          : L4W >= 30 units and up >= 25% vs P4W
--   Declining/Watch  : P4W >= 30 units and down >= 25% vs P4W
--   Low Velocity     : on sale >= 4 of the last 12 weeks and bottom 20%
--                      of weekly velocity
--   Core / Stable    : everything else
--
-- CASE checks conditions top to bottom and stops at the first match, so
-- the order sets priority: a top seller that is also declining is shown
-- as High Performer (still a key item) - its % change remains visible.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS sku_flags;
CREATE TABLE sku_flags AS
WITH base AS (
    SELECT
        p.*,
        COALESCE(m.units_l4w, 0) AS units_l4w,    -- no match in sku_momentum -> 0 units
        COALESCE(m.units_p4w, 0) AS units_p4w,
        m.pct_change             AS pct_change_l4w_vs_p4w
    FROM sku_performance_l12w p
    LEFT JOIN sku_momentum m ON p.article_id = m.article_id
),
ranked AS (
    SELECT *,
           PERCENT_RANK() OVER (ORDER BY units_l4w) AS l4w_pctile
    FROM base
)
SELECT
    *,
    CASE
        WHEN l4w_pctile >= 0.95                                  THEN 'High Performer'
        WHEN units_l4w >= 30 AND units_l4w >= 1.25 * units_p4w   THEN 'Growing'
        WHEN units_p4w >= 30 AND units_l4w <= 0.75 * units_p4w   THEN 'Declining / Watch'
        WHEN weeks_on_sale >= 4 AND velocity_pctile < 0.20       THEN 'Low Velocity'
        ELSE 'Core / Stable'
    END AS performance_flag
FROM ranked;

-- Flag summary
SELECT performance_flag,
       COUNT(*)                                             AS skus,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)   AS pct_of_skus,
       SUM(units_l4w)                                       AS units_l4w,
       ROUND(100.0 * SUM(units_l4w) / SUM(SUM(units_l4w)) OVER (), 1) AS pct_of_l4w_units
FROM sku_flags
GROUP BY performance_flag
ORDER BY skus DESC;

-- Flag mix by department: where should the team look first?
SELECT department_name,
       COUNT(*)                                                             AS active_skus,
       COUNT(CASE WHEN performance_flag = 'High Performer'    THEN 1 END)   AS high_performers,
       COUNT(CASE WHEN performance_flag = 'Growing'           THEN 1 END)   AS growing,
       COUNT(CASE WHEN performance_flag = 'Declining / Watch' THEN 1 END)   AS declining,
       COUNT(CASE WHEN performance_flag = 'Low Velocity'      THEN 1 END)   AS low_velocity,
       ROUND(100.0 * COUNT(CASE WHEN performance_flag IN ('Declining / Watch', 'Low Velocity') THEN 1 END)
             / COUNT(*), 1)                                                 AS attention_pct
FROM sku_flags
GROUP BY department_name
HAVING COUNT(*) >= 150
ORDER BY attention_pct DESC
LIMIT 15;
