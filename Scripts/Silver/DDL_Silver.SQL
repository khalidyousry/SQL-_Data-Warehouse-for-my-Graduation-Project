USE FMCG_Datawarehouse;
GO

/* ========== Schema ========== */
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'SILVER')
    EXEC('CREATE SCHEMA SILVER');
GO

/* ========== Tables ========== */
DROP TABLE IF EXISTS SILVER.ERP_Suppliers;
CREATE TABLE SILVER.ERP_Suppliers (
    supplier_id        VARCHAR(50),
    supplier_name      VARCHAR(100),
    country            VARCHAR(100),
    lead_time          INT,
    reliability_score  DECIMAL(5,2),
    dwh_create_date    DATETIME2 DEFAULT GETDATE()
);
GO

DROP TABLE IF EXISTS SILVER.ERP_Products;
CREATE TABLE SILVER.ERP_Products (
    product_id       VARCHAR(50),
    product_name     VARCHAR(200),
    category         VARCHAR(100),
    sub_category     VARCHAR(100),
    unit_cost        DECIMAL(12,2),
    unit_price       DECIMAL(12,2),
    supplier_id      VARCHAR(50),
    dwh_create_date  DATETIME2 DEFAULT GETDATE()
);
GO

DROP TABLE IF EXISTS SILVER.ERP_Inventory;
CREATE TABLE SILVER.ERP_Inventory (
    inventory_id     VARCHAR(50),
    product_id       VARCHAR(50),
    warehouse_id     VARCHAR(50),
    [date]           DATE,
    stock_on_hand    INT,
    reorder_point    INT,
    safety_stock     INT,
    dwh_create_date  DATETIME2 DEFAULT GETDATE()
);
GO

DROP TABLE IF EXISTS SILVER.ERP_Warehouse;
CREATE TABLE SILVER.ERP_Warehouse (
    warehouse_id     VARCHAR(50),
    warehouse_name   VARCHAR(100),
    location         VARCHAR(100),
    capacity         INT,
    dwh_create_date  DATETIME2 DEFAULT GETDATE()
);
GO

DROP TABLE IF EXISTS SILVER.ERP_purchase_orders;
CREATE TABLE SILVER.ERP_purchase_orders (
    po_id                   VARCHAR(50),
    product_id              VARCHAR(50),
    supplier_id             VARCHAR(50),
    warehouse_id            VARCHAR(50),
    order_date              DATE,
    expected_delivery_date  DATE,
    actual_delivery_date    DATE,
    quantity_ordered        INT,
    quantity_received       INT,
    status                  VARCHAR(100),
    dwh_create_date         DATETIME2 DEFAULT GETDATE()
);
GO

DROP TABLE IF EXISTS SILVER.ERP_Returns;
CREATE TABLE SILVER.ERP_Returns (
    return_id        VARCHAR(50),
    order_id         VARCHAR(50),
    product_id       VARCHAR(50),
    return_date      DATE,
    reason           VARCHAR(100),
    quantity         INT,
    dwh_create_date  DATETIME2 DEFAULT GETDATE()
);
GO

DROP TABLE IF EXISTS SILVER.ERP_sales_orders;
CREATE TABLE SILVER.ERP_sales_orders (
    order_id         VARCHAR(50),
    product_id       VARCHAR(50),
    warehouse_id     VARCHAR(50),
    customer_id      VARCHAR(50),
    order_date       DATE,
    ship_date        DATE,
    delivery_date    DATE,
    quantity         INT,
    status           VARCHAR(100),
    dwh_create_date  DATETIME2 DEFAULT GETDATE()
);
GO
