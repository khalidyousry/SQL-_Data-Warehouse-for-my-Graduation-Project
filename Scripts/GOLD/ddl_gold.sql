USE FMCG_Datawarehouse;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'GOLD')
    EXEC('CREATE SCHEMA GOLD');
GO

/* ================= DIMENSIONS ================= */

-- تقويم من 2025-09-01 لـ 2026-12-31
CREATE OR ALTER VIEW GOLD.dim_date AS
WITH nums AS (
    SELECT TOP (500) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
    FROM sys.all_objects
),
days AS (
    SELECT DATEADD(DAY, n, CAST('2025-09-01' AS DATE)) AS d
    FROM nums
)
SELECT
    d                                              AS [date],
    YEAR(d)                                        AS [year],
    DATEPART(QUARTER, d)                           AS [quarter],
    MONTH(d)                                       AS [month],
    DATENAME(MONTH, d)                             AS month_name,
    DATEPART(ISO_WEEK, d)                          AS week_of_year,
    -- بداية الأسبوع (يوم الاثنين) ومش بتتأثر بإعدادات السيرفر
    DATEADD(DAY, -(DATEDIFF(DAY, '1900-01-01', d) % 7), d) AS week_start,
    DATEDIFF(DAY, '1900-01-01', d) % 7 + 1         AS day_of_week,   -- 1 = Monday
    CASE WHEN DATEDIFF(DAY, '1900-01-01', d) % 7 >= 5 THEN 1 ELSE 0 END AS is_weekend
FROM days
WHERE d <= '2026-12-31';
GO

CREATE OR ALTER VIEW GOLD.dim_product AS
SELECT
    product_id,
    product_name,
    category,
    sub_category,
    unit_cost,
    unit_price,
    unit_price - unit_cost AS unit_margin,   -- NULL لو التكلفة NULL
    supplier_id
FROM SILVER.ERP_Products;
GO

CREATE OR ALTER VIEW GOLD.dim_supplier AS
SELECT
    supplier_id,
    supplier_name,
    country,
    lead_time         AS lead_time_days,
    reliability_score
FROM SILVER.ERP_Suppliers;
GO

CREATE OR ALTER VIEW GOLD.dim_warehouse AS
SELECT
    warehouse_id,
    warehouse_name,
    location,
    CASE WHEN CHARINDEX(',', location) > 0
         THEN LEFT(location, CHARINDEX(',', location) - 1)
         ELSE location END AS city,
    CASE WHEN CHARINDEX(',', location) > 0
         THEN TRIM(SUBSTRING(location, CHARINDEX(',', location) + 1, 100))
         ELSE NULL END     AS state,
    capacity
FROM SILVER.ERP_Warehouse;
GO

/* ================= FACTS ================= */

CREATE OR ALTER VIEW GOLD.fact_sales AS
SELECT
    s.order_id,
    s.product_id,
    s.warehouse_id,
    s.customer_id,
    s.order_date,
    s.ship_date,
    s.delivery_date,
    s.quantity,
    s.status,
    CASE WHEN s.status = 'Cancelled' THEN 1 ELSE 0 END          AS is_cancelled,
    -- الإيراد بالسعر الرسمي، والطلب الملغي = صفر
    CASE WHEN s.status = 'Cancelled' THEN 0
         ELSE s.quantity * p.unit_price END                      AS revenue,
    DATEDIFF(DAY, s.order_date, s.ship_date)                     AS days_to_ship,
    DATEDIFF(DAY, s.ship_date, s.delivery_date)                  AS days_in_transit,
    DATEDIFF(DAY, s.order_date, s.delivery_date)                 AS days_order_to_delivery
FROM SILVER.ERP_sales_orders s
LEFT JOIN SILVER.ERP_Products p ON p.product_id = s.product_id;
GO

CREATE OR ALTER VIEW GOLD.fact_purchase_orders AS
SELECT
    po_id,
    product_id,
    supplier_id,
    warehouse_id,
    order_date,
    expected_delivery_date,
    actual_delivery_date,
    quantity_ordered,
    quantity_received,
    status,
    DATEDIFF(DAY, order_date, expected_delivery_date) AS planned_lead_time_days,

    -- مقاييس التسليم بتتحسب بس للأوامر اللي وصلت فعلًا (مش In Transit)
    CASE WHEN status <> 'In Transit' AND actual_delivery_date IS NOT NULL
         THEN DATEDIFF(DAY, order_date, actual_delivery_date) END AS actual_lead_time_days,

    CASE WHEN status <> 'In Transit' AND actual_delivery_date IS NOT NULL
         THEN DATEDIFF(DAY, expected_delivery_date, actual_delivery_date) END AS delay_days,

    CASE WHEN status <> 'In Transit' AND actual_delivery_date IS NOT NULL
         THEN CASE WHEN actual_delivery_date <= expected_delivery_date THEN 1 ELSE 0 END END AS is_on_time,

    CAST(quantity_received AS DECIMAL(10,4)) / NULLIF(quantity_ordered, 0) AS fill_rate
FROM SILVER.ERP_purchase_orders;
GO

CREATE OR ALTER VIEW GOLD.fact_inventory AS
SELECT
    inventory_id,
    product_id,
    warehouse_id,
    [date] AS snapshot_date,
    stock_on_hand,
    reorder_point,
    safety_stock,
    CASE WHEN stock_on_hand IS NULL OR reorder_point IS NULL THEN NULL
         WHEN stock_on_hand <= reorder_point THEN 1 ELSE 0 END AS is_below_reorder,
    CASE WHEN stock_on_hand IS NULL OR safety_stock IS NULL THEN NULL
         WHEN stock_on_hand <  safety_stock THEN 1 ELSE 0 END  AS is_below_safety,
    CASE WHEN stock_on_hand IS NULL THEN NULL
         WHEN stock_on_hand = 0 THEN 1 ELSE 0 END              AS is_stockout
FROM SILVER.ERP_Inventory;
GO

CREATE OR ALTER VIEW GOLD.fact_returns AS
SELECT
    r.return_id,
    r.order_id,
    r.product_id,
    s.warehouse_id,                       -- من الطلب الأصلي
    s.order_date,
    r.return_date,
    r.reason,
    r.quantity,
    r.quantity * p.unit_price              AS return_value,
    DATEDIFF(DAY, s.order_date, r.return_date) AS days_since_order
FROM SILVER.ERP_Returns r
LEFT JOIN SILVER.ERP_sales_orders s ON s.order_id   = r.order_id
LEFT JOIN SILVER.ERP_Products     p ON p.product_id = r.product_id;
GO


USE FMCG_Datawarehouse;
GO

/* =====================================================
   1) الطلب الأسبوعي  (Demand Forecasting)
   Grain: منتج × مخزن × أسبوع  (الأسابيع الفاضية = صفر)
   ===================================================== */
CREATE OR ALTER VIEW GOLD.vw_demand_weekly AS
WITH weeks AS (
    SELECT [date] AS week_start, [year], [month], week_of_year
    FROM GOLD.dim_date
    WHERE day_of_week = 1                                   -- يوم الاثنين
      AND [date] BETWEEN (SELECT MIN(order_date) FROM GOLD.fact_sales)
                     AND (SELECT MAX(order_date) FROM GOLD.fact_sales)
),
pairs AS (
    SELECT product_id, warehouse_id FROM GOLD.fact_sales
    UNION
    SELECT product_id, warehouse_id FROM GOLD.fact_inventory
),
sales_w AS (
    SELECT s.product_id, s.warehouse_id, d.week_start,
           SUM(s.quantity) AS units_sold,
           COUNT(*)        AS orders_count
    FROM GOLD.fact_sales s
    JOIN GOLD.dim_date d ON d.[date] = s.order_date
    WHERE s.is_cancelled = 0                                -- الملغي مش طلب حقيقي
    GROUP BY s.product_id, s.warehouse_id, d.week_start
),
returns_w AS (
    SELECT r.product_id, r.warehouse_id, d.week_start,
           SUM(r.quantity) AS units_returned
    FROM GOLD.fact_returns r
    JOIN GOLD.dim_date d ON d.[date] = r.return_date
    WHERE r.warehouse_id IS NOT NULL
    GROUP BY r.product_id, r.warehouse_id, d.week_start
)
SELECT
    p.product_id,
    pr.category,
    p.warehouse_id,
    w.week_start,
    w.[year],
    w.[month],
    w.week_of_year,
    ISNULL(s.units_sold, 0)      AS units_sold,
    ISNULL(s.orders_count, 0)    AS orders_count,
    ISNULL(r.units_returned, 0)  AS units_returned
FROM pairs p
CROSS JOIN weeks w
LEFT JOIN sales_w   s ON s.product_id = p.product_id AND s.warehouse_id = p.warehouse_id AND s.week_start = w.week_start
LEFT JOIN returns_w r ON r.product_id = p.product_id AND r.warehouse_id = p.warehouse_id AND r.week_start = w.week_start
LEFT JOIN GOLD.dim_product pr ON pr.product_id = p.product_id;
GO

/* =====================================================
   2) مدخلات الـ Inventory Optimization / Safety Stock
   Grain: منتج × مخزن
   ===================================================== */
CREATE OR ALTER VIEW GOLD.vw_inventory_policy_inputs AS
WITH demand AS (
    SELECT product_id, warehouse_id,
           COUNT(*)                         AS weeks_observed,
           AVG(CAST(units_sold AS FLOAT))   AS avg_weekly_demand,
           STDEV(CAST(units_sold AS FLOAT)) AS std_weekly_demand
    FROM GOLD.vw_demand_weekly
    GROUP BY product_id, warehouse_id
),
lead AS (
    SELECT product_id, warehouse_id,
           COUNT(actual_lead_time_days)                AS po_count,
           AVG(CAST(actual_lead_time_days AS FLOAT))   AS avg_lead_time_days,
           STDEV(CAST(actual_lead_time_days AS FLOAT)) AS std_lead_time_days
    FROM GOLD.fact_purchase_orders
    GROUP BY product_id, warehouse_id
),
latest AS (
    SELECT product_id, warehouse_id, snapshot_date, stock_on_hand, reorder_point, safety_stock,
           ROW_NUMBER() OVER (PARTITION BY product_id, warehouse_id ORDER BY snapshot_date DESC) AS rn
    FROM GOLD.fact_inventory
),
joined AS (
    SELECT
        d.product_id, d.warehouse_id,
        p.category, p.sub_category, p.unit_cost, p.unit_price, p.supplier_id,
        s.reliability_score,
        d.weeks_observed, d.avg_weekly_demand, d.std_weekly_demand,
        l.po_count, l.std_lead_time_days,
        -- الـ lead time الفعلي من أوامر الشراء، ولو مفيش نستخدم المسجّل عند المورد
        COALESCE(l.avg_lead_time_days, s.lead_time_days) AS lead_time_days,
        i.snapshot_date AS last_snapshot_date,
        i.stock_on_hand, i.reorder_point, i.safety_stock,
        CASE WHEN i.product_id IS NULL THEN 0 ELSE 1 END AS has_inventory_record
    FROM demand d
    LEFT JOIN GOLD.dim_product  p ON p.product_id  = d.product_id
    LEFT JOIN GOLD.dim_supplier s ON s.supplier_id = p.supplier_id
    LEFT JOIN lead   l ON l.product_id = d.product_id AND l.warehouse_id = d.warehouse_id
    LEFT JOIN latest i ON i.product_id = d.product_id AND i.warehouse_id = d.warehouse_id AND i.rn = 1
),
calc AS (
    SELECT *,
           lead_time_days / 7.0                     AS lead_time_weeks,
           ISNULL(std_lead_time_days, 0) / 7.0      AS std_lead_weeks
    FROM joined
)
SELECT
    product_id, warehouse_id, category, sub_category, supplier_id,
    unit_cost, unit_price, reliability_score,
    weeks_observed,
    ROUND(avg_weekly_demand, 3)       AS avg_weekly_demand,
    ROUND(std_weekly_demand, 3)       AS std_weekly_demand,
    ROUND(avg_weekly_demand * 52, 1)  AS annual_demand,
    ROUND(lead_time_days, 2)          AS lead_time_days,
    po_count,
    ROUND(std_lead_time_days, 2)      AS std_lead_time_days,
    has_inventory_record, last_snapshot_date,
    stock_on_hand, reorder_point, safety_stock,

    -- Baseline للمقارنة: safety stock بمستوى خدمة 95% (z = 1.645)
    -- SS = z * sqrt( L*σd² + d²*σL² )   (Graves & Willems)
    ROUND(1.645 * SQRT(lead_time_weeks * POWER(std_weekly_demand, 2)
                       + POWER(avg_weekly_demand, 2) * POWER(std_lead_weeks, 2)), 1) AS safety_stock_95,

    ROUND(avg_weekly_demand * lead_time_weeks
          + 1.645 * SQRT(lead_time_weeks * POWER(std_weekly_demand, 2)
                         + POWER(avg_weekly_demand, 2) * POWER(std_lead_weeks, 2)), 1) AS reorder_point_95
FROM calc;
GO

/* =====================================================
   3) تقييم الموردين  (Supplier Scoring)
   Grain: مورد
   ===================================================== */
CREATE OR ALTER VIEW GOLD.vw_supplier_scorecard AS
SELECT
    s.supplier_id,
    s.supplier_name,
    s.country,
    s.lead_time_days     AS master_lead_time_days,
    s.reliability_score,
    COUNT(po.po_id)                                   AS total_pos,
    COUNT(po.is_on_time)                              AS delivered_pos,   -- اللي اتسلّم فعلًا
    COUNT(DISTINCT po.product_id)                     AS products_supplied,
    ROUND(AVG(CAST(po.is_on_time AS FLOAT)), 3)       AS on_time_rate,
    ROUND(AVG(CAST(po.delay_days AS FLOAT)), 2)       AS avg_delay_days,
    ROUND(AVG(CAST(po.planned_lead_time_days AS FLOAT)), 2) AS avg_planned_lead_time,
    ROUND(AVG(CAST(po.actual_lead_time_days  AS FLOAT)), 2) AS avg_actual_lead_time,
    ROUND(AVG(CAST(po.fill_rate AS FLOAT)), 3)        AS avg_fill_rate,
    SUM(po.quantity_ordered)                          AS total_qty_ordered,
    SUM(po.quantity_received)                         AS total_qty_received
FROM GOLD.dim_supplier s
LEFT JOIN GOLD.fact_purchase_orders po ON po.supplier_id = s.supplier_id
GROUP BY s.supplier_id, s.supplier_name, s.country, s.lead_time_days, s.reliability_score;
GO

/* =====================================================
   4) خطر نفاد المخزون  (Risk Prediction / ML)
   Grain: منتج × مخزن × أسبوع  (لقطة المخزون)
   ===================================================== */
CREATE OR ALTER VIEW GOLD.vw_inventory_risk AS
WITH dem AS (
    SELECT product_id, warehouse_id, week_start, units_sold,
           AVG(CAST(units_sold AS FLOAT)) OVER (
               PARTITION BY product_id, warehouse_id
               ORDER BY week_start
               ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS avg_demand_prev_4w
    FROM GOLD.vw_demand_weekly
),
inv AS (
    SELECT i.*,
           LEAD(i.is_below_safety) OVER (PARTITION BY i.product_id, i.warehouse_id ORDER BY i.snapshot_date) AS next_week_below_safety,
           LEAD(i.is_stockout)     OVER (PARTITION BY i.product_id, i.warehouse_id ORDER BY i.snapshot_date) AS next_week_stockout
    FROM GOLD.fact_inventory i
)
SELECT
    inv.product_id,
    p.category,
    inv.warehouse_id,
    w.warehouse_name,
    inv.snapshot_date,
    inv.stock_on_hand,
    inv.reorder_point,
    inv.safety_stock,
    inv.stock_on_hand - inv.reorder_point  AS gap_to_reorder,
    inv.stock_on_hand - inv.safety_stock   AS gap_to_safety,
    d.units_sold                           AS units_sold_this_week,
    ROUND(d.avg_demand_prev_4w, 3)         AS avg_demand_prev_4w,
    ROUND(inv.stock_on_hand / NULLIF(d.avg_demand_prev_4w, 0), 2) AS weeks_of_cover,
    inv.is_below_reorder,
    inv.is_below_safety,
    inv.is_stockout,
    inv.next_week_below_safety,            -- الـ target للـ ML (NULL في آخر أسبوع)
    inv.next_week_stockout
FROM inv
LEFT JOIN dem d ON d.product_id = inv.product_id AND d.warehouse_id = inv.warehouse_id AND d.week_start = inv.snapshot_date
LEFT JOIN GOLD.dim_product   p ON p.product_id   = inv.product_id
LEFT JOIN GOLD.dim_warehouse w ON w.warehouse_id = inv.warehouse_id;
GO

