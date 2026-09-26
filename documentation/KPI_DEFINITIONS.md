# KPI Definitions

All metrics are calculated from `fact_sales`, the cleaned transaction table built in [`01_data_quality_checks.sql`](../sql/01_data_quality_checks.sql).

**Time periods**

| Label | Meaning | Dates |
|---|---|---|
| Week | Wednesday to Tuesday, so the final week in the data is complete | - |
| L4W | Last 4 weeks | 2020-08-26 to 2020-09-22 |
| P4W | Previous 4 weeks | 2020-07-29 to 2020-08-25 |
| LY4W | Same 4 weeks last year | 2019-08-28 to 2019-09-24 |
| L12W | Last 12 weeks, the "current season" view for SKUs | 2020-07-01 to 2020-09-22 |
| L52W / P52W | Last 52 weeks / prior 52 weeks | 2019-09-25 to 2020-09-22 / 2018-09-26 to 2019-09-24 |

---

### Sales
- **Definition:** Total value of units sold.
- **Calculation:** `SUM(price)`
- **Business use:** The headline measure of demand, used for trending, category share and ranking.
- **Caveat:** H&M scaled the price column, so Sales is a **relative index, not currency**. It works for comparisons and % change, but not as an absolute revenue figure. It is also gross demand: returns and discounts aren't available.

### Units
- **Definition:** Number of items sold.
- **Calculation:** `COUNT(*)`, because each transaction row is one unit.
- **Business use:** Volume demand, independent of price. It's the main measure for SKU velocity and momentum.
- **Caveat:** Returns aren't in the data, so Units is gross units sold.

### Transactions
- **Definition:** Proxy for a purchase or basket.
- **Calculation:** number of distinct (customer_id, sale_date, channel) combinations: `SELECT DISTINCT` those three columns, then `COUNT(*)`
- **Business use:** Traffic that converted, and the base for ATV and UPT.
- **Caveat:** The data has no receipt ID. A customer shopping twice in one day on the same channel counts as one transaction, so this slightly undercounts. It is **not additive** across categories, so the dashboard shows it at company level only.

### Active SKUs
- **Definition:** Number of distinct articles (style + colour) with at least one unit sold in the period.
- **Calculation:** `COUNT(DISTINCT article_id)`
- **Business use:** A proxy for assortment breadth, i.e. how many options are generating demand.
- **Caveat:** This is **not** the number of SKUs in stock or on the floor. There's no inventory data, so an item in stock with zero sales isn't counted.

### Average Selling Price (ASP)
- **Definition:** Average price realized per unit.
- **Calculation:** `Sales / Units`
- **Business use:** Tracks price mix and markdown pressure. A falling ASP in-season can signal clearance.
- **Caveat:** Scaled price, so read it as a relative index. It moves with product mix (for example, more outerwear raises ASP) as well as pricing.

### Average Transaction Value (ATV)
- **Definition:** Average value per transaction.
- **Calculation:** `Sales / Transactions`
- **Business use:** Basket size in value terms. ATV = ASP × UPT.
- **Caveat:** Inherits the Transactions proxy caveat.

### Units per Transaction (UPT)
- **Definition:** Average number of items per transaction.
- **Calculation:** `Units / Transactions`
- **Business use:** Basket depth. It shows whether customers are buying multiples or outfits.
- **Caveat:** Inherits the Transactions proxy caveat.

### Units per SKU (Productivity)
- **Definition:** Average units sold per active option in a category.
- **Calculation:** `Units / Active SKUs`
- **Business use:** Separates categories that sell a lot because they carry a lot of options from categories that sell a lot per option. High productivity can mean a category is under-assorted relative to demand.
- **Caveat:** It doesn't account for inventory depth or how long each SKU was on sale.

### Sales Velocity (Units per Week)
- **Definition:** Rate of sale for a SKU.
- **Calculation:** `Units in L12W / weeks on sale`, where weeks on sale counts from the SKU's first sale in the window through the final week.
- **Business use:** Identifies fast and slow movers fairly, so new launches aren't penalized for being on sale for fewer weeks.
- **Caveat:** Without inventory, low velocity can't be separated from low stock. A SKU may sell slowly because it was nearly sold out.

### L4W vs P4W % Change (Momentum)
- **Definition:** Short-term growth or decline.
- **Calculation:** `(L4W units / P4W units) - 1`
- **Business use:** Early warning of items and categories gaining or losing demand.
- **Caveat:** The data ends in September, so this comparison is heavily seasonal (summer to autumn). Category trends are also compared to **LY4W** to separate real change from seasonality. SKU-level changes require at least 30–50 units to avoid small-base noise.

### Demand Index (attributes)
- **Definition:** How much an attribute (colour, pattern, etc.) sells relative to how much of the assortment it takes up.
- **Calculation:** `unit share % / SKU share %`
- **Business use:** A value above 1.0 means the attribute sells more than its share of options, a possible under-assortment. Below 1.0 means it may be over-assorted.
- **Caveat:** This is correlation, not causation. Attributes overlap with category (for example, black trousers).

### Performance Flag (SKU)
Assigned in [`06_assortment_opportunities.sql`](../sql/06_assortment_opportunities.sql), in priority order:

| Flag | Rule | Suggested action |
|---|---|---|
| High Performer | Top 5% of active SKUs by L4W units | Protect: monitor availability and consider depth |
| Growing | L4W ≥ 30 units and ≥ +25% vs P4W | Watch for chase and reorder opportunities |
| Declining / Watch | P4W ≥ 30 units and ≤ −25% vs P4W | Review: is it seasonal, end of life or a problem? |
| Low Velocity | On sale ≥ 4 weeks, bottom 20% of weekly velocity | Review assortment breadth and markdown candidates |
| Core / Stable | Everything else | Business as usual |

- **Caveat:** These flags point to places to investigate. They aren't buying decisions, because inventory, margin and receipt plans aren't available.

---

### Metrics intentionally *not* calculated
The public dataset has no inventory on hand, receipts, on-order or cost data. **Sell-through, weeks of supply, inventory turnover, stockout rate, GMROI and margin cannot be calculated honestly**, so this project doesn't report them.
