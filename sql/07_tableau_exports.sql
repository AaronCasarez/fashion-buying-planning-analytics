-- =====================================================================
-- 07_tableau_exports.sql
-- Writes aggregated CSVs for the Tableau dashboard to exports/.
-- Run AFTER files 01-06 (it reads the tables they create).
--
-- COPY ... TO is how DuckDB (and PostgreSQL) write a query result to a
-- file. Tableau gets aggregates, not the 31.8M raw rows, so the workbook
-- stays fast and fits Tableau Public limits.
-- =====================================================================

-- 1. Weekly x SKU for the last 52 weeks, with product hierarchy attached.
--    Drives KPI tiles, trend line, category and SKU views - and every
--    filter (department, section, garment group, product type) works on it.
COPY (
    WITH weekly_sku AS (
        SELECT week_start, weeks_ago, article_id,
               COUNT(*)   AS units,
               SUM(price) AS sales
        FROM fact_sales
        WHERE weeks_ago <= 51
        GROUP BY week_start, weeks_ago, article_id
    )
    SELECT
        w.week_start,
        w.weeks_ago,
        w.article_id,
        a.prod_name,
        a.index_group_name   AS index_group,
        a.department_name    AS department,
        a.section_name       AS section,
        a.garment_group_name AS garment_group,
        a.product_type_name  AS product_type,
        a.colour_group_name  AS colour,
        w.units,
        ROUND(w.sales, 5)    AS sales
    FROM weekly_sku w
    JOIN articles a ON w.article_id = a.article_id
    ORDER BY w.week_start, w.article_id
) TO 'exports/tableau_weekly_sku.csv' (HEADER);

-- 2. Company-level weekly KPIs (all weeks). Transactions / ATV / UPT are
--    not additive across SKUs, so they come from here, unfiltered.
COPY (SELECT * FROM kpi_weekly ORDER BY week_start)
TO 'exports/tableau_weekly_kpis.csv' (HEADER);

-- 3. SKU performance flags (High Performer / Growing / Declining / Low Velocity)
COPY (
    SELECT article_id, prod_name, department_name AS department, section_name AS section,
           garment_group_name AS garment_group, product_type_name AS product_type,
           colour_group_name AS colour, units AS units_l12w, ROUND(sales, 5) AS sales_l12w,
           weeks_on_sale, units_per_week, asp, units_l4w, units_p4w,
           pct_change_l4w_vs_p4w, performance_flag
    FROM sku_flags
    ORDER BY units_l4w DESC
) TO 'exports/tableau_sku_flags.csv' (HEADER);

-- 4. Category performance and momentum (supporting tables)
COPY (SELECT * FROM category_performance ORDER BY level, sales_rank)
TO 'exports/tableau_category_performance.csv' (HEADER);

COPY (SELECT * FROM category_momentum ORDER BY level, units_change)
TO 'exports/tableau_category_momentum.csv' (HEADER);

COPY (SELECT * FROM attribute_demand ORDER BY attribute, demand_index DESC)
TO 'exports/tableau_attribute_demand.csv' (HEADER);

-- 5. Monthly KPIs (MoM / YoY) and monthly Store vs. Online split
COPY (SELECT * FROM kpi_monthly ORDER BY month_start)
TO 'exports/tableau_monthly_kpis.csv' (HEADER);

COPY (
    SELECT month_start, channel,
           ROUND(SUM(price), 2) AS sales,
           COUNT(*)             AS units
    FROM fact_sales
    GROUP BY month_start, channel
    ORDER BY month_start, channel
) TO 'exports/tableau_monthly_channel.csv' (HEADER);
