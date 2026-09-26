# Tableau Dashboard

**Live version:** [H&M Buying & Planning: Key Findings (Tableau Public)](https://public.tableau.com/app/profile/aaron.casarez/viz/HMBuyingandPlanningKeyFindings/Dashboard1)

![Dashboard](dashboard.png)

## Charts and data sources

Each chart has its own data source, exported by [`sql/07_tableau_exports.sql`](../sql/07_tableau_exports.sql). The files are not joined; they come together on the dashboard.

| Chart | What it shows | Data source (`exports/`) |
|---|---|---|
| Sales Below Last Year Until Aug-2020 | Monthly sales % vs same month last year (partial months excluded) | `tableau_monthly_kpis.csv` |
| Stores Closed Apr-2020: 100% Online | Monthly sales by channel (Online vs Store) | `tableau_monthly_channel.csv` |
| 5% of SKUs Drive 62% of Units | Share of last-4-week units by SKU performance flag | `tableau_sku_flags.csv` |
| Knitwear Up, Summer Categories Down | Product types: % vs previous 4 weeks (x) and % vs same 4 weeks last year (y) | `tableau_category_momentum.csv` |
| Black & White Outsell Their Share | Colour demand index (unit share ÷ SKU share); line at 1.0 | `tableau_attribute_demand.csv` |

## Build notes

- **Colour scheme:** blue = strong or growing, red = declining, grey = neutral.
- **YoY chart:** continuous month axis; red-blue diverging colour centred on 0.
- **Demand concentration:** calculated field `IF [Performance Flag] = "High Performer" THEN "High Performer" ELSE "Other" END` on Color.
- **Growth vs seasonal:** filtered to `Level = Product Type` and `Units P4W >= 2000`. The **Unknown** product type is excluded; its +1,103% vs LY comes from missing product classifications (see the data-quality section of the main README), not from real demand.
- **Colour demand:** filtered to colours with ≥ 1% of SKUs; reference line at a demand index of 1.0.
- **Publishing:** all data sources are extracts, which Tableau Public requires.
