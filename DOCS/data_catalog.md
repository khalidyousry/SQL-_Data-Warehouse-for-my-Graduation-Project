# FMCG Supply Chain Data Warehouse: Data Catalog

Data dictionary for the **Gold layer** of `FMCG_Datawarehouse`, built for the graduation project *AI-Powered Supply Chain Analytics & Decision Intelligence Platform*.

**Audience:** anyone who queries the warehouse (OR modelling, ML, Power BI, back-end).
**Rule of thumb:** query only the `GOLD` schema. `BRONZE` and `SILVER` are internal layers.

---

## 1. Architecture

| Layer | Schema | Content | Who uses it |
|---|---|---|---|
| Bronze | `BRONZE` | Raw CSV data loaded as text, no cleaning | Data engineering only |
| Silver | `SILVER` | Cleaned, typed, de-duplicated tables (`ERP_*`) plus `dwh_create_date` | Data engineering only |
| **Gold** | `GOLD` | Star schema views (`dim_*`, `fact_*`) and analytical views (`vw_*`) | **Everyone** |

- **Server:** SQL Server LocalDB, instance `(localdb)\MSSQLLocalDB`
- **Database:** `FMCG_Datawarehouse`
- **Period covered:** 2025-09-01 to 2026-08-31 (53 Mondays, 52 weeks plus one)
- **Industry:** FMCG, 80 products, 5 warehouses, 12 suppliers
- **Gold objects are views.** They always reflect the current Silver data.

---

## 2. Conventions

| Topic | Convention |
|---|---|
| Naming | `GOLD.dim_<name>` for dimensions, `GOLD.fact_<name>` for facts, `GOLD.vw_<name>` for analytical views |
| Keys | Business keys are used for joins: `product_id`, `supplier_id`, `warehouse_id`. IDs are upper-case and trimmed. There are no surrogate keys. |
| Dates | Type `DATE`, ISO format (`YYYY-MM-DD`). `dim_date[date]` is the join key for every date column. |
| Weeks | A week starts on **Monday**. `week_start` is the Monday date. All inventory snapshots fall on Mondays. |
| NULLs | A NULL means **the value is missing or invalid in the source**. Missing values are never filled with defaults in Gold. See section 8. |
| Money | `unit_cost` and `unit_price` have no stated currency. Revenue is calculated at **list price** (`quantity x unit_price`). |
| Cancelled orders | Kept in `fact_sales` with `is_cancelled = 1` and `revenue = 0`. Excluded from all demand calculations. |
| Flags | Boolean columns are stored as `INT` (1 = yes, 0 = no, NULL = unknown). |

---

## 3. Data model

### Relationships (all one-to-many, dimension to fact)

| One side | Many side | Join column(s) |
|---|---|---|
| `dim_product` | `fact_sales`, `fact_purchase_orders`, `fact_inventory`, `fact_returns` | `product_id` |
| `dim_warehouse` | `fact_sales`, `fact_purchase_orders`, `fact_inventory`, `fact_returns` | `warehouse_id` |
| `dim_supplier` | `fact_purchase_orders` | `supplier_id` |
| `dim_date[date]` | `fact_sales` | `order_date` (active); `ship_date`, `delivery_date` (inactive) |
| `dim_date[date]` | `fact_purchase_orders` | `order_date` (active); `expected_delivery_date`, `actual_delivery_date` (inactive) |
| `dim_date[date]` | `fact_inventory` | `snapshot_date` |
| `dim_date[date]` | `fact_returns` | `return_date` (active); `order_date` (inactive) |

**Not modelled on purpose:**
- `dim_supplier` to `dim_product`: it would create two paths to `fact_purchase_orders`. Use the `supplier_id` in the fact.
- `fact_sales` to `fact_returns`: fact-to-fact joins are discouraged. Use shared dimensions. `fact_returns` already carries `warehouse_id` and `order_date` from the original order.

### Object summary

| Object | Type | Grain (one row = ...) | Expected rows |
|---|---|---|---|
| `dim_date` | Dimension | one calendar day (2025-09-01 to 2026-12-31) | 487 |
| `dim_product` | Dimension | one product | 80 |
| `dim_supplier` | Dimension | one supplier | 12 |
| `dim_warehouse` | Dimension | one warehouse | 5 |
| `fact_sales` | Fact | one sales order (one product per order) | 6,000 |
| `fact_purchase_orders` | Fact | one purchase order | 1,800 |
| `fact_inventory` | Fact | one product x warehouse x weekly snapshot | 10,600 |
| `fact_returns` | Fact | one return | 295 |
| `vw_demand_weekly` | Analytical | product x warehouse x week | 21,200 |
| `vw_inventory_policy_inputs` | Analytical | product x warehouse | 400 |
| `vw_supplier_scorecard` | Analytical | one supplier | 12 |
| `vw_inventory_risk` | Analytical | product x warehouse x weekly snapshot | 10,600 |

Row counts are the expected values after cleaning. Re-check them with the query in section 11.

---

## 4. Dimensions

### 4.1 `GOLD.dim_date`
Calendar table. Generated, not loaded from a source.

| Column | Type | Description |
|---|---|---|
| `date` | DATE | **PK.** Calendar day. |
| `year` | INT | Calendar year. |
| `quarter` | INT | Quarter, 1 to 4. |
| `month` | INT | Month number, 1 to 12. |
| `month_name` | VARCHAR | Month name (depends on server language). |
| `week_of_year` | INT | ISO week number. |
| `week_start` | DATE | Monday of the week the day belongs to. |
| `day_of_week` | INT | 1 = Monday ... 7 = Sunday. |
| `is_weekend` | INT | 1 for Saturday and Sunday. |

### 4.2 `GOLD.dim_product`
Source: `SILVER.ERP_Products`.

| Column | Type | Description |
|---|---|---|
| `product_id` | VARCHAR(50) | **PK.** Format `P0001` to `P0080`. |
| `product_name` | VARCHAR(200) | Product name, for example `Footwear Item 1`. |
| `category` | VARCHAR(100) | One of 5 categories (see section 7). |
| `sub_category` | VARCHAR(100) | One of 20 sub-categories. |
| `unit_cost` | DECIMAL(12,2) | Cost per unit. **NULL for 4 products** (3 negative values and 1 empty in the source). |
| `unit_price` | DECIMAL(12,2) | List selling price per unit. |
| `unit_margin` | DECIMAL(13,2) | `unit_price - unit_cost`. NULL when cost is NULL. |
| `supplier_id` | VARCHAR(50) | Default supplier. FK to `dim_supplier`. **NULL for 3 products.** |

### 4.3 `GOLD.dim_supplier`
Source: `SILVER.ERP_Suppliers`.

| Column | Type | Description |
|---|---|---|
| `supplier_id` | VARCHAR(50) | **PK.** Format `SUP001` to `SUP012`. |
| `supplier_name` | VARCHAR(100) | Supplier name. |
| `country` | VARCHAR(100) | Country, with unified capitalisation. |
| `lead_time_days` | INT | **Declared** lead time in days. NULL for 4 suppliers (SUP001, SUP002, SUP009, SUP011). |
| `reliability_score` | DECIMAL(5,2) | Declared reliability, between 0 and 1. NULL for SUP012. |

> The supplier name often does not match the country (for example `India Supplier 1` with country `Bangladesh`). This was left as is because the correct value is unknown.

### 4.4 `GOLD.dim_warehouse`
Source: `SILVER.ERP_Warehouse`.

| Column | Type | Description |
|---|---|---|
| `warehouse_id` | VARCHAR(50) | **PK.** `WH01` to `WH05`. |
| `warehouse_name` | VARCHAR(100) | Distribution centre name. |
| `location` | VARCHAR(100) | City and state as in the source, for example `Mumbai, Maharashtra`. |
| `city` | VARCHAR | Part of `location` before the comma. |
| `state` | VARCHAR | Part after the comma. NULL for `Delhi NCR`. |
| `capacity` | INT | Storage capacity. The unit is not stated in the source (assumed units). |

---

## 5. Facts

### 5.1 `GOLD.fact_sales`
Source: `SILVER.ERP_sales_orders` joined with `ERP_Products` for the price.

| Column | Type | Description |
|---|---|---|
| `order_id` | VARCHAR(50) | **PK.** Format `SO000001`. |
| `product_id` | VARCHAR(50) | FK to `dim_product`. |
| `warehouse_id` | VARCHAR(50) | FK to `dim_warehouse`. Warehouse that fulfilled the order. |
| `customer_id` | VARCHAR(50) | Customer. **NULL in 162 rows.** There is no customer dimension. |
| `order_date` | DATE | Order date. |
| `ship_date` | DATE | Shipping date. |
| `delivery_date` | DATE | Delivery date. **NULL in 177 rows.** |
| `quantity` | INT | Units ordered. 124 rows have `0`. |
| `status` | VARCHAR | `Delivered`, `Delayed` or `Cancelled`. |
| `is_cancelled` | INT | 1 if `status = 'Cancelled'`. |
| `revenue` | DECIMAL | `quantity x unit_price`. **0 for cancelled orders.** List price, not a transaction price. |
| `days_to_ship` | INT | `ship_date - order_date`. |
| `days_in_transit` | INT | `delivery_date - ship_date`. NULL if not delivered date. |
| `days_order_to_delivery` | INT | `delivery_date - order_date`. |

### 5.2 `GOLD.fact_purchase_orders`
Source: `SILVER.ERP_purchase_orders`.

| Column | Type | Description |
|---|---|---|
| `po_id` | VARCHAR(50) | **PK.** Purchase order ID. |
| `product_id` | VARCHAR(50) | FK to `dim_product`. |
| `supplier_id` | VARCHAR(50) | FK to `dim_supplier`. Always equals the product's default supplier. |
| `warehouse_id` | VARCHAR(50) | FK to `dim_warehouse`. Receiving warehouse. |
| `order_date` | DATE | Date the PO was placed. |
| `expected_delivery_date` | DATE | Promised delivery date. |
| `actual_delivery_date` | DATE | Actual delivery date. **NULL in 90 rows.** For `In Transit` orders this is probably a planned date, not an actual one. |
| `quantity_ordered` | INT | Units ordered. |
| `quantity_received` | INT | Units received. NULL when missing or negative in the source (about 123 rows). |
| `status` | VARCHAR | `Received`, `Partially Received` or `In Transit`. |
| `planned_lead_time_days` | INT | `expected_delivery_date - order_date`. |
| `actual_lead_time_days` | INT | `actual_delivery_date - order_date`. **Only for orders that are not In Transit** and have an actual date. |
| `delay_days` | INT | `actual - expected`. Negative means early. Same restriction as above. |
| `is_on_time` | INT | 1 if `actual <= expected`, 0 otherwise. Same restriction as above. |
| `fill_rate` | DECIMAL(10,4) | `quantity_received / quantity_ordered`. NULL when received is NULL. |

### 5.3 `GOLD.fact_inventory`
Source: `SILVER.ERP_Inventory`. Weekly snapshot on Mondays.

| Column | Type | Description |
|---|---|---|
| `inventory_id` | VARCHAR(50) | **PK.** Format `INV000001`. |
| `product_id` | VARCHAR(50) | FK to `dim_product`. |
| `warehouse_id` | VARCHAR(50) | FK to `dim_warehouse`. |
| `snapshot_date` | DATE | Snapshot date (always a Monday). |
| `stock_on_hand` | INT | Units in stock. NULL when empty or negative in the source. |
| `reorder_point` | INT | Stock level that triggers a reorder. NULL when missing. |
| `safety_stock` | INT | Safety stock level. |
| `is_below_reorder` | INT | 1 if `stock_on_hand <= reorder_point`. NULL if either is NULL. |
| `is_below_safety` | INT | 1 if `stock_on_hand < safety_stock`. NULL if either is NULL. |
| `is_stockout` | INT | 1 if `stock_on_hand = 0`. NULL if stock is NULL. |

> Inventory exists for **200** product x warehouse pairs only (each product is stocked in 2 or 3 warehouses), while sales happen in 400 pairs.

### 5.4 `GOLD.fact_returns`
Source: `SILVER.ERP_Returns` joined with sales and products.

| Column | Type | Description |
|---|---|---|
| `return_id` | VARCHAR(50) | **PK.** Return ID. |
| `order_id` | VARCHAR(50) | Original sales order. |
| `product_id` | VARCHAR(50) | FK to `dim_product`. |
| `warehouse_id` | VARCHAR(50) | FK to `dim_warehouse`. Taken from the original sales order. |
| `order_date` | DATE | Order date of the original sale. |
| `return_date` | DATE | Date of the return. |
| `reason` | VARCHAR | `Damaged`, `Late Delivery`, `No Longer Needed`, `Quality Issue`, `Wrong Item`. **NULL in 12 rows.** |
| `quantity` | INT | Units returned (1 to 4). |
| `return_value` | DECIMAL | `quantity x unit_price`. |
| `days_since_order` | INT | `return_date - order_date`. |

---

## 6. Analytical views

These views are built on the star schema and are designed as inputs for models.

### 6.1 `GOLD.vw_demand_weekly`
**Purpose:** weekly demand time series for forecasting and bullwhip analysis.
**Grain:** product x warehouse x week. Weeks without sales are present with `0` (no gaps in the series).
**Scope:** all 400 product x warehouse pairs seen in sales or inventory, for all 53 Mondays.

| Column | Type | Description |
|---|---|---|
| `product_id` | VARCHAR | Product. |
| `category` | VARCHAR | Product category. |
| `warehouse_id` | VARCHAR | Warehouse. |
| `week_start` | DATE | Monday of the week. |
| `year`, `month`, `week_of_year` | INT | Calendar attributes of the week. |
| `units_sold` | INT | Units sold that week, **excluding cancelled orders**. 0 when none. |
| `orders_count` | INT | Number of non-cancelled orders that week. |
| `units_returned` | INT | Units returned that week (by `return_date`). |

> Demand is **intermittent**: about 0.28 orders per week per product x warehouse pair. Aggregate to product level (all warehouses) or to months before forecasting.

### 6.2 `GOLD.vw_inventory_policy_inputs`
**Purpose:** parameters for safety stock, reorder point, EOQ, and inventory optimisation.
**Grain:** product x warehouse (400 rows).

| Column | Type | Description |
|---|---|---|
| `product_id`, `warehouse_id` | VARCHAR | Keys. |
| `category`, `sub_category`, `supplier_id` | VARCHAR | Product attributes. |
| `unit_cost`, `unit_price` | DECIMAL | From `dim_product`. |
| `reliability_score` | DECIMAL | Supplier's declared reliability. |
| `weeks_observed` | INT | Number of weeks in the demand series (53). |
| `avg_weekly_demand` | FLOAT | Mean of `units_sold` per week (zero weeks included). |
| `std_weekly_demand` | FLOAT | Standard deviation of weekly demand. |
| `annual_demand` | FLOAT | `avg_weekly_demand x 52`. |
| `lead_time_days` | FLOAT | Mean actual lead time from purchase orders for this pair. If there are none, the supplier's declared lead time. |
| `po_count` | INT | Number of purchase orders used for the actual lead time. |
| `std_lead_time_days` | FLOAT | Standard deviation of actual lead time. |
| `has_inventory_record` | INT | 1 if the pair has inventory snapshots, 0 otherwise (200 pairs have none). |
| `last_snapshot_date` | DATE | Latest inventory snapshot date. |
| `stock_on_hand`, `reorder_point`, `safety_stock` | INT | Values at the latest snapshot. NULL when no record. |
| `safety_stock_95` | FLOAT | Baseline safety stock at 95% service level (formula in section 9). |
| `reorder_point_95` | FLOAT | Baseline reorder point at 95% service level. |

### 6.3 `GOLD.vw_supplier_scorecard`
**Purpose:** supplier performance metrics for ranking and scoring (TOPSIS, AHP).
**Grain:** one supplier (12 rows). A supplier without purchase orders still appears.

| Column | Type | Description |
|---|---|---|
| `supplier_id`, `supplier_name`, `country` | VARCHAR | Supplier attributes. |
| `master_lead_time_days` | INT | Declared lead time. |
| `reliability_score` | DECIMAL | Declared reliability. |
| `total_pos` | INT | Number of purchase orders. |
| `delivered_pos` | INT | Orders with a measurable delivery (not In Transit, actual date present). |
| `products_supplied` | INT | Distinct products ordered. |
| `on_time_rate` | FLOAT | Share of delivered orders with `actual <= expected`. |
| `avg_delay_days` | FLOAT | Mean of `delay_days` (negative = early). |
| `avg_planned_lead_time` | FLOAT | Mean planned lead time (days). |
| `avg_actual_lead_time` | FLOAT | Mean actual lead time (days). |
| `avg_fill_rate` | FLOAT | Mean of per-order fill rate. |
| `total_qty_ordered`, `total_qty_received` | INT | Totals (NULL received quantities are not counted). |

### 6.4 `GOLD.vw_inventory_risk`
**Purpose:** features and targets for stock-out risk classification.
**Grain:** product x warehouse x weekly snapshot (10,600 rows, only the 200 pairs with inventory).

| Column | Type | Description |
|---|---|---|
| `product_id`, `category`, `warehouse_id`, `warehouse_name` | VARCHAR | Keys and labels. |
| `snapshot_date` | DATE | Snapshot Monday. |
| `stock_on_hand`, `reorder_point`, `safety_stock` | INT | Snapshot values. |
| `gap_to_reorder` | INT | `stock_on_hand - reorder_point`. |
| `gap_to_safety` | INT | `stock_on_hand - safety_stock`. |
| `units_sold_this_week` | INT | Units sold during the week starting on the snapshot date. |
| `avg_demand_prev_4w` | FLOAT | Mean weekly demand over the **previous 4 weeks** (excludes the current week). NULL for the first weeks. |
| `weeks_of_cover` | FLOAT | `stock_on_hand / avg_demand_prev_4w`. NULL when demand is 0 or NULL. |
| `is_below_reorder`, `is_below_safety`, `is_stockout` | INT | Current-week flags. |
| `next_week_below_safety` | INT | **Target.** Value of `is_below_safety` for the same pair next week. NULL for the last week. |
| `next_week_stockout` | INT | **Target.** Value of `is_stockout` next week. NULL for the last week. |

> For model training, drop rows where the target is NULL and split train and test **by time**, not randomly.

---

## 7. Domain values

| Attribute | Allowed values |
|---|---|
| `fact_sales.status` | `Delivered` (4,917), `Delayed` (791), `Cancelled` (292) |
| `fact_purchase_orders.status` | `Received` (571), `Partially Received` (1,079), `In Transit` (150) |
| `fact_returns.reason` | `Damaged`, `Late Delivery`, `No Longer Needed`, `Quality Issue`, `Wrong Item`, NULL |
| `dim_product.category` | `Apparel`, `Electronics`, `Grocery`, `Home & Kitchen`, `Personal Care` |
| `dim_warehouse` | `WH01` Ahmedabad DC, `WH02` Mumbai DC, `WH03` Bengaluru DC, `WH04` Delhi NCR DC, `WH05` Chennai DC |

---

## 8. Data quality notes and known limitations

| # | Area | Issue | Handling in Gold |
|---|---|---|---|
| 1 | Inventory | Only 200 of 400 product x warehouse pairs have inventory records, but sales exist for all 400. | `has_inventory_record` flag in `vw_inventory_policy_inputs`. Clarify with the data owner. |
| 2 | Demand | Very sparse and intermittent at product x warehouse level. | Aggregate before forecasting. Consider Croston or SBA. |
| 3 | Sales | 124 orders have `quantity = 0` (101 of them `Delivered`). | Kept as is. Decide in the model whether to exclude them. |
| 4 | Sales | `delivery_date` missing in 177 rows (140 are `Delivered`). | NULL. Exclude from lead time calculations. |
| 5 | Sales | `customer_id` missing in 162 rows. | NULL. |
| 6 | Products | `unit_cost` missing or negative for 4 products. | NULL. Margin is NULL too. |
| 7 | Products | `supplier_id` missing for 3 products. | NULL. |
| 8 | Suppliers | `lead_time_days` NULL for 4 suppliers, `reliability_score` NULL for 1. | NULL. Decide in the model (impute or exclude). |
| 9 | Suppliers | Supplier name does not match its country in most rows. | Not changed. |
| 10 | Purchase orders | 90 orders have no actual delivery date (37 `Received`, 50 `Partially Received`, 3 `In Transit`). | NULL. |
| 11 | Purchase orders | `In Transit` orders carry actual dates up to 2026-10-28, probably planned dates. | Delay and on-time metrics are computed only for orders that are not `In Transit`. |
| 12 | Purchase orders | `quantity_received` missing or negative in about 123 rows. | NULL. |
| 13 | Inventory | `stock_on_hand` missing or negative in about 315 rows, `reorder_point` missing in about 194. | NULL. |
| 14 | Returns | `reason` missing in 12 rows. | NULL. |
| 15 | Revenue | No transaction prices exist. Each product has one fixed price. | Revenue uses list price. Price elasticity cannot be estimated. |
| 16 | Costs | No holding, ordering, or transport costs. No customer coordinates or shelf-life data. | Must be modelled as explicit assumptions. |

---

## 9. Business rules and formulas

| Metric | Definition |
|---|---|
| Revenue | `quantity x unit_price`, 0 if cancelled |
| Demand | `units_sold` of non-cancelled orders |
| On-time delivery | `actual_delivery_date <= expected_delivery_date` (not In Transit) |
| Delay (days) | `actual_delivery_date - expected_delivery_date` |
| Actual lead time (days) | `actual_delivery_date - order_date` |
| Fill rate | `quantity_received / quantity_ordered` |
| Stock-out | `stock_on_hand = 0` |
| Below safety | `stock_on_hand < safety_stock` |
| Weeks of cover | `stock_on_hand / average weekly demand of the previous 4 weeks` |
| Safety stock (baseline) | `1.645 x SQRT( L x sd_d^2 + d^2 x sd_L^2 )` |
| Reorder point (baseline) | `d x L + safety stock` |

In the baseline formulas: `d` is the mean weekly demand, `sd_d` its standard deviation, `L` the lead time **in weeks** (days divided by 7), `sd_L` the standard deviation of lead time in weeks, and 1.645 is the z-value for a 95% service level (Graves and Willems). The formula assumes normally distributed demand, which does not hold here because demand is intermittent. Treat the result as a starting point and validate with simulation.

---

## 10. Silver cleaning rules (for reference)

| Table | Rules applied |
|---|---|
| All tables | Trim spaces, upper-case IDs, remove exact duplicate rows, convert empty strings to NULL, `TRY_CAST` to the final type |
| Warehouse | Fixed the columns shifted by commas inside quoted fields. Standardised names. |
| Suppliers | Capitalised country. Lead time -1 and empty became NULL. Values such as `21.0` converted through DECIMAL. |
| Products | Standardised category and sub-category. Negative or empty cost became NULL. Empty supplier became NULL. 4 duplicate rows removed. |
| Inventory | Repaired rows split by the comma in dates like `Nov 10, 2025`. Unified 4 date formats. Removed 159 duplicates. Negative or empty stock became NULL. |
| Purchase orders | Unified date formats. 36 duplicates removed. Negative or empty `quantity_received` became NULL. |
| Sales orders | Unified date formats. 90 duplicates removed. Standardised status. |
| Returns | Unified date formats. Standardised reason. |

**Date formats found in the source files** (important if you reload the data):

| Table and column | Formats |
|---|---|
| Sales `order_date`, purchase orders `order_date` | `YYYY-MM-DD`, `DD-MM-YYYY`, and **`MM/DD/YYYY`** |
| Sales `ship_date`, PO `expected_delivery_date` | `YYYY-MM-DD`, `DD-MM-YYYY` |
| Sales `delivery_date`, PO `actual_delivery_date` | `YYYY-MM-DD`, and **`DD/MM/YYYY`** |
| Inventory `date` | `YYYY-MM-DD`, `DD-MM-YYYY`, `DD/MM/YYYY`, `Mon DD, YYYY` |
| Returns `return_date` | `YYYY-MM-DD`, `DD-MM-YYYY` |

The slash format is `MM/DD/YYYY` in the order dates and `DD/MM/YYYY` in the other columns. Treating them the same silently corrupts dates.

---

## 11. How to use

### Check the warehouse
```sql
SELECT 'dim_date' AS view_name, COUNT(*) AS rows_count FROM GOLD.dim_date
UNION ALL SELECT 'dim_product',          COUNT(*) FROM GOLD.dim_product
UNION ALL SELECT 'dim_supplier',         COUNT(*) FROM GOLD.dim_supplier
UNION ALL SELECT 'dim_warehouse',        COUNT(*) FROM GOLD.dim_warehouse
UNION ALL SELECT 'fact_sales',           COUNT(*) FROM GOLD.fact_sales
UNION ALL SELECT 'fact_purchase_orders', COUNT(*) FROM GOLD.fact_purchase_orders
UNION ALL SELECT 'fact_inventory',       COUNT(*) FROM GOLD.fact_inventory
UNION ALL SELECT 'fact_returns',         COUNT(*) FROM GOLD.fact_returns;
```

### Monthly revenue by category
```sql
SELECT d.[year], d.[month], p.category, SUM(s.revenue) AS revenue
FROM GOLD.fact_sales s
JOIN GOLD.dim_date    d ON d.[date]    = s.order_date
JOIN GOLD.dim_product p ON p.product_id = s.product_id
GROUP BY d.[year], d.[month], p.category
ORDER BY d.[year], d.[month], p.category;
```

### Supplier on-time rate
```sql
SELECT supplier_id, supplier_name, on_time_rate, avg_fill_rate
FROM GOLD.vw_supplier_scorecard
ORDER BY on_time_rate DESC;
```

### Python (pandas)
```python
import pandas as pd, pyodbc

conn = pyodbc.connect(
    "Driver={ODBC Driver 17 for SQL Server};"
    "Server=(localdb)\\MSSQLLocalDB;"
    "Database=FMCG_Datawarehouse;"
    "Trusted_Connection=yes;"
)
demand = pd.read_sql("SELECT * FROM GOLD.vw_demand_weekly", conn)

# Forecasting at product level
product_week = (demand.groupby(["product_id", "week_start"], as_index=False)
                      .units_sold.sum())
```

### Power BI
1. Get Data, SQL Server. Server `(localdb)\MSSQLLocalDB`, database `FMCG_Datawarehouse`.
2. Select the `GOLD` views and choose **Import**.
3. In Model view, create the relationships from section 3 (many-to-one, single direction, dimension to fact) and mark `dim_date` as the date table.
4. Use `USERELATIONSHIP` for inactive date relationships, for example delivery date.

---

## 12. Mapping to project modules

| Module | Main objects |
|---|---|
| Demand forecasting | `vw_demand_weekly` |
| Bullwhip effect | `vw_demand_weekly` compared with weekly purchase quantities from `fact_purchase_orders` |
| Safety stock, EOQ, inventory optimisation | `vw_inventory_policy_inputs` |
| Supplier scoring | `vw_supplier_scorecard` |
| Stock-out risk prediction | `vw_inventory_risk` |
| Warehouse utilisation | `fact_inventory` with `dim_warehouse[capacity]` |
| Returns and quality analysis | `fact_returns`, `dim_product` |
| Executive dashboard | Star schema (`dim_*` and `fact_*`) |

**Not supported by the current data** (assumptions or synthetic data are required): vehicle routing (no customer locations or distances), cold-chain optimisation (no shelf life or temperature data), dynamic pricing (single fixed price per product).
