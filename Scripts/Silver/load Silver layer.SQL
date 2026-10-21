USE FMCG_Datawarehouse;
GO
-- CLEANING  WAREHOUSE DATA 
TRUNCATE TABLE SILVER.ERP_Warehouse;
GO

WITH fixed AS (
    SELECT
        warehouse_id,
        warehouse_name,
        location,
        REPLACE(capacity, CHAR(13), '') AS capacity   
    FROM BRONZE.ERP_Warehouse
)
INSERT INTO SILVER.ERP_Warehouse (warehouse_id, warehouse_name, location, capacity)
SELECT
    TRIM(warehouse_id),

    CASE UPPER(TRIM(warehouse_name))
        WHEN 'AHMEDABAD DC' THEN 'Ahmedabad DC'
        WHEN 'MUMBAI DC'    THEN 'Mumbai DC'
        WHEN 'BENGALURU DC' THEN 'Bengaluru DC'
        WHEN 'DELHI NCR DC' THEN 'Delhi NCR DC'
        WHEN 'CHENNAI DC'   THEN 'Chennai DC'
        ELSE TRIM(warehouse_name)
    END,

    
    CASE
        WHEN location LIKE '"%'
        THEN TRIM(REPLACE(location + ',' + LEFT(capacity, CHARINDEX(',', capacity) - 1), '"', ''))
        ELSE TRIM(location)
    END,

    
    CASE
        WHEN location LIKE '"%'
        THEN TRY_CAST(TRIM(SUBSTRING(capacity, CHARINDEX(',', capacity) + 1, 50)) AS INT)
        ELSE TRY_CAST(TRIM(capacity) AS INT)
    END
FROM fixed;
GO



GO 

-- CLEANING SUPPLIERS DATA 
USE FMCG_Datawarehouse;
GO

TRUNCATE TABLE SILVER.ERP_Suppliers;
GO

INSERT INTO SILVER.ERP_Suppliers (supplier_id, supplier_name, country, lead_time, reliability_score)
SELECT
    TRIM(supplier_id),
    TRIM(supplier_name),
    UPPER(LEFT(TRIM(country), 1)) + LOWER(SUBSTRING(TRIM(country), 2, 100)),

    -- الفاضي أو السالب أو الصفر يبقى NULL
    CASE WHEN TRY_CAST(NULLIF(TRIM(lead_time), '') AS DECIMAL(10,2)) > 0
         THEN CAST(TRY_CAST(TRIM(lead_time) AS DECIMAL(10,2)) AS INT)
    END,

    CASE WHEN TRY_CAST(NULLIF(TRIM(REPLACE(reliability_score, CHAR(13), '')), '') AS DECIMAL(5,2)) BETWEEN 0 AND 1
         THEN TRY_CAST(TRIM(REPLACE(reliability_score, CHAR(13), '')) AS DECIMAL(5,2))
    END
FROM BRONZE.ERP_Suppliers;
GO



GO

-- CLEANING INVENTORY Table

TRUNCATE TABLE SILVER.ERP_Inventory;
GO

USE FMCG_Datawarehouse;
GO

TRUNCATE TABLE SILVER.ERP_Inventory;
GO

WITH base AS (
    SELECT inventory_id, product_id, warehouse_id,
           [date], stock_on_hand, reorder_point,
           REPLACE(safety_stock, CHAR(13), '') AS safety_stock
    FROM BRONZE.ERP_Inventory
),
fixed AS (
    -- 1) رجّع الأعمدة لمكانها الصح + شيل التكرار
    SELECT DISTINCT
        TRIM(inventory_id) AS inventory_id,
        TRIM(product_id)   AS product_id,
        TRIM(warehouse_id) AS warehouse_id,

        CASE WHEN [date] LIKE '"%'
             THEN TRIM(REPLACE([date], '"', '') + ',' + REPLACE(stock_on_hand, '"', ''))
             ELSE TRIM([date]) END AS date_txt,

        CASE WHEN [date] LIKE '"%'
             THEN TRIM(reorder_point)
             ELSE TRIM(stock_on_hand) END AS stock_txt,

        CASE WHEN [date] LIKE '"%'
             THEN TRIM(LEFT(safety_stock, CHARINDEX(',', safety_stock) - 1))
             ELSE TRIM(reorder_point) END AS reorder_txt,

        CASE WHEN [date] LIKE '"%'
             THEN TRIM(SUBSTRING(safety_stock, CHARINDEX(',', safety_stock) + 1, 20))
             ELSE TRIM(safety_stock) END AS safety_txt
    FROM base
)
INSERT INTO SILVER.ERP_Inventory
    (inventory_id, product_id, warehouse_id, [date], stock_on_hand, reorder_point, safety_stock)
SELECT
    UPPER(inventory_id),
    UPPER(product_id),
    UPPER(warehouse_id),

    -- 2) توحيد التواريخ
    CASE
        WHEN date_txt LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]'
            THEN TRY_CONVERT(DATE, date_txt, 103)
        WHEN date_txt LIKE '[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]'
            THEN TRY_CONVERT(DATE, REPLACE(date_txt, '-', '/'), 103)
        WHEN date_txt LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
            THEN TRY_CONVERT(DATE, date_txt, 23)
        ELSE -- صيغة Nov 10, 2025: بقرأ الشهر بنفسي عشان لغة السيرفر ما تأثرش
            DATEFROMPARTS(
                CAST(RIGHT(date_txt, 4) AS INT),
                CASE LEFT(date_txt, 3)
                    WHEN 'Jan' THEN 1  WHEN 'Feb' THEN 2  WHEN 'Mar' THEN 3
                    WHEN 'Apr' THEN 4  WHEN 'May' THEN 5  WHEN 'Jun' THEN 6
                    WHEN 'Jul' THEN 7  WHEN 'Aug' THEN 8  WHEN 'Sep' THEN 9
                    WHEN 'Oct' THEN 10 WHEN 'Nov' THEN 11 WHEN 'Dec' THEN 12
                END,
                CAST(SUBSTRING(date_txt, 5, 2) AS INT))
    END,

    -- 3) الفاضي والسالب يبقى NULL
    CASE WHEN TRY_CAST(NULLIF(stock_txt, '') AS DECIMAL(10,2)) >= 0
         THEN CAST(TRY_CAST(stock_txt AS DECIMAL(10,2)) AS INT) END,

    CASE WHEN TRY_CAST(NULLIF(reorder_txt, '') AS DECIMAL(10,2)) > 0
         THEN CAST(TRY_CAST(reorder_txt AS DECIMAL(10,2)) AS INT) END,

    TRY_CAST(safety_txt AS INT)
FROM fixed;
GO



GO

-- Cleaning Products Table 



TRUNCATE TABLE SILVER.ERP_Products;
GO

INSERT INTO SILVER.ERP_Products
    (product_id, product_name, category, sub_category, unit_cost, unit_price, supplier_id)
SELECT DISTINCT   -- DISTINCT بتشيل الصفوف المكررة
    UPPER(TRIM(product_id)),
    TRIM(product_name),

    -- توحيد الـ category (5 قيم بس)
    CASE UPPER(TRIM(category))
        WHEN 'APPAREL'        THEN 'Apparel'
        WHEN 'ELECTRONICS'    THEN 'Electronics'
        WHEN 'GROCERY'        THEN 'Grocery'
        WHEN 'HOME & KITCHEN' THEN 'Home & Kitchen'
        WHEN 'PERSONAL CARE'  THEN 'Personal Care'
        ELSE TRIM(category)
    END,

    -- أول حرف كابيتال والباقي سمول (كلها كلمة واحدة)
    UPPER(LEFT(TRIM(sub_category), 1)) + LOWER(SUBSTRING(TRIM(sub_category), 2, 100)),

    -- السالب والفاضي يبقى NULL
    CASE WHEN TRY_CAST(NULLIF(TRIM(unit_cost), '') AS DECIMAL(12,2)) > 0
         THEN TRY_CAST(TRIM(unit_cost) AS DECIMAL(12,2))
    END,

    TRY_CAST(TRIM(unit_price) AS DECIMAL(12,2)),

    -- الفاضي يبقى NULL
    NULLIF(UPPER(TRIM(REPLACE(supplier_id, CHAR(13), ''))), '')
FROM BRONZE.ERP_Products;
GO



GO 

-- CLEANING Returns Table


TRUNCATE TABLE SILVER.ERP_Returns;
GO

INSERT INTO SILVER.ERP_Returns
    (return_id, order_id, product_id, return_date, reason, quantity)
SELECT
    UPPER(TRIM(return_id)),
    UPPER(TRIM(order_id)),
    UPPER(TRIM(product_id)),

    -- توحيد التاريخ (style 23 = سنة-شهر-يوم، و 105 = يوم-شهر-سنة)
    CASE
        WHEN TRIM(return_date) LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
            THEN TRY_CONVERT(DATE, TRIM(return_date), 23)
        ELSE TRY_CONVERT(DATE, TRIM(return_date), 105)
    END,

    -- توحيد السبب (5 قيم) والفاضي يبقى NULL
    CASE UPPER(TRIM(reason))
        WHEN 'DAMAGED'          THEN 'Damaged'
        WHEN 'LATE DELIVERY'    THEN 'Late Delivery'
        WHEN 'NO LONGER NEEDED' THEN 'No Longer Needed'
        WHEN 'QUALITY ISSUE'    THEN 'Quality Issue'
        WHEN 'WRONG ITEM'       THEN 'Wrong Item'
        ELSE NULLIF(TRIM(reason), '')
    END,

    TRY_CAST(TRIM(REPLACE(quantity, CHAR(13), '')) AS INT)
FROM BRONZE.ERP_Returns;
GO

-- Cleaning Purchase_Orders Table 


GO

TRUNCATE TABLE SILVER.ERP_purchase_orders;
GO

WITH no_dup AS (
    SELECT DISTINCT
        TRIM(po_id)                  AS po_id,
        TRIM(product_id)             AS product_id,
        TRIM(supplier_id)            AS supplier_id,
        TRIM(warehouse_id)           AS warehouse_id,
        TRIM(order_date)             AS order_date,
        TRIM(expected_delivery_date) AS expected_delivery_date,
        TRIM(actual_delivery_date)   AS actual_delivery_date,
        TRIM(quantity_ordered)       AS quantity_ordered,
        TRIM(quantity_received)      AS quantity_received,
        TRIM(REPLACE(status, CHAR(13), '')) AS status
    FROM BRONZE.ERP_purchase_orders
)
INSERT INTO SILVER.ERP_purchase_orders
    (po_id, product_id, supplier_id, warehouse_id, order_date, expected_delivery_date,
     actual_delivery_date, quantity_ordered, quantity_received, status)
SELECT
    UPPER(po_id),
    UPPER(product_id),
    UPPER(supplier_id),
    UPPER(warehouse_id),

    -- order_date: الـ "/" هنا شهر/يوم/سنة (style 101)، والـ "-" يوم-شهر-سنة (105)
    CASE
        WHEN order_date LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' THEN TRY_CONVERT(DATE, order_date, 23)
        WHEN order_date LIKE '[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, order_date, 105)
        WHEN order_date LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, order_date, 101)
    END,

    -- expected_delivery_date: سنة-شهر-يوم أو يوم-شهر-سنة
    CASE
        WHEN expected_delivery_date LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' THEN TRY_CONVERT(DATE, expected_delivery_date, 23)
        WHEN expected_delivery_date LIKE '[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, expected_delivery_date, 105)
    END,

    -- actual_delivery_date: الـ "/" هنا يوم/شهر/سنة (style 103)، والفاضي يبقى NULL
    CASE
        WHEN actual_delivery_date LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' THEN TRY_CONVERT(DATE, actual_delivery_date, 23)
        WHEN actual_delivery_date LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, actual_delivery_date, 103)
    END,

    CAST(TRY_CAST(quantity_ordered AS DECIMAL(10,2)) AS INT),

    -- الفاضي والسالب يبقى NULL
    CASE WHEN TRY_CAST(NULLIF(quantity_received, '') AS DECIMAL(10,2)) >= 0
         THEN CAST(TRY_CAST(quantity_received AS DECIMAL(10,2)) AS INT)
    END,

    CASE UPPER(status)
        WHEN 'RECEIVED'           THEN 'Received'
        WHEN 'PARTIALLY RECEIVED' THEN 'Partially Received'
        WHEN 'IN TRANSIT'         THEN 'In Transit'
        ELSE NULLIF(status, '')
    END
FROM no_dup;
GO



GO
-- Cleaning Orders Data


TRUNCATE TABLE SILVER.ERP_sales_orders;
GO

WITH no_dup AS (
    SELECT DISTINCT
        TRIM(order_id)      AS order_id,
        TRIM(product_id)    AS product_id,
        TRIM(warehouse_id)  AS warehouse_id,
        TRIM(customer_id)   AS customer_id,
        TRIM(order_date)    AS order_date,
        TRIM(ship_date)     AS ship_date,
        TRIM(delivery_date) AS delivery_date,
        TRIM(quantity)      AS quantity,
        TRIM(REPLACE(status, CHAR(13), '')) AS status
    FROM BRONZE.ERP_sales_orders
)
INSERT INTO SILVER.ERP_sales_orders
    (order_id, product_id, warehouse_id, customer_id, order_date, ship_date,
     delivery_date, quantity, status)
SELECT
    UPPER(order_id),
    UPPER(product_id),
    UPPER(warehouse_id),
    NULLIF(UPPER(customer_id), ''),

    -- order_date: الـ "/" هنا شهر/يوم/سنة (101)، والـ "-" يوم-شهر-سنة (105)
    CASE
        WHEN order_date LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' THEN TRY_CONVERT(DATE, order_date, 23)
        WHEN order_date LIKE '[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, order_date, 105)
        WHEN order_date LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, order_date, 101)
    END,

    -- ship_date: سنة-شهر-يوم أو يوم-شهر-سنة
    CASE
        WHEN ship_date LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' THEN TRY_CONVERT(DATE, ship_date, 23)
        WHEN ship_date LIKE '[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, ship_date, 105)
    END,

    -- delivery_date: الـ "/" هنا يوم/شهر/سنة (103)، والفاضي يبقى NULL
    CASE
        WHEN delivery_date LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' THEN TRY_CONVERT(DATE, delivery_date, 23)
        WHEN delivery_date LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, delivery_date, 103)
    END,

    TRY_CAST(quantity AS INT),

    CASE UPPER(status)
        WHEN 'DELIVERED' THEN 'Delivered'
        WHEN 'DELAYED'   THEN 'Delayed'
        WHEN 'CANCELLED' THEN 'Cancelled'
        ELSE NULLIF(status, '')
    END
FROM no_dup;
GO

