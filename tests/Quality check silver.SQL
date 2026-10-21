-- Testing Cleaning 

SELECT * FROM SILVER.ERP_Warehouse;

GO

SELECT * FROM SILVER.ERP_Suppliers;

GO

SELECT COUNT(*) AS total_rows,
       SUM(CASE WHEN [date] IS NULL THEN 1 ELSE 0 END)         AS null_dates,
       SUM(CASE WHEN stock_on_hand IS NULL THEN 1 ELSE 0 END)  AS null_stock,
       SUM(CASE WHEN reorder_point IS NULL THEN 1 ELSE 0 END)  AS null_reorder,
       SUM(CASE WHEN safety_stock IS NULL THEN 1 ELSE 0 END)   AS null_safety
FROM SILVER.ERP_Inventory;

GO

SELECT COUNT(*) AS total_rows,
       SUM(CASE WHEN unit_cost   IS NULL THEN 1 ELSE 0 END) AS null_cost,
       SUM(CASE WHEN supplier_id IS NULL THEN 1 ELSE 0 END) AS null_supplier
FROM SILVER.ERP_Products;

GO

SELECT COUNT(*) AS total_rows,
       SUM(CASE WHEN return_date IS NULL THEN 1 ELSE 0 END) AS null_dates,
       SUM(CASE WHEN reason      IS NULL THEN 1 ELSE 0 END) AS null_reason,
       SUM(CASE WHEN quantity    IS NULL THEN 1 ELSE 0 END) AS null_qty
FROM SILVER.ERP_Returns;

GO

SELECT COUNT(*) AS total_rows,
       SUM(CASE WHEN order_date IS NULL THEN 1 ELSE 0 END)           AS null_order_date,
       SUM(CASE WHEN expected_delivery_date IS NULL THEN 1 ELSE 0 END) AS null_expected,
       SUM(CASE WHEN actual_delivery_date IS NULL THEN 1 ELSE 0 END) AS null_actual,
       SUM(CASE WHEN quantity_received IS NULL THEN 1 ELSE 0 END)    AS null_received,
       SUM(CASE WHEN expected_delivery_date < order_date THEN 1 ELSE 0 END) AS bad_date_order
FROM SILVER.ERP_purchase_orders;

GO

SELECT COUNT(*) AS total_rows,
       SUM(CASE WHEN order_date IS NULL THEN 1 ELSE 0 END)    AS null_order_date,
       SUM(CASE WHEN ship_date IS NULL THEN 1 ELSE 0 END)     AS null_ship_date,
       SUM(CASE WHEN delivery_date IS NULL THEN 1 ELSE 0 END) AS null_delivery,
       SUM(CASE WHEN customer_id IS NULL THEN 1 ELSE 0 END)   AS null_customer,
       SUM(CASE WHEN ship_date < order_date THEN 1 ELSE 0 END) AS bad_date_order
FROM SILVER.ERP_sales_orders;
