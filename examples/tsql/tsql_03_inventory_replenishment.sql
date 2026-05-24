-- Identifies SKUs below their reorder point and upserts purchase order
-- recommendations, factoring in vendor lead times and safety stock levels.
CREATE PROCEDURE usp_inventory_replenishment
    @warehouse_id   INT,
    @run_date       DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @run_date = ISNULL(@run_date, CAST(GETDATE() AS DATE));

    -- Current stock vs. reorder thresholds
    SELECT
        ws.sku_id,
        ws.quantity_on_hand - ISNULL(ws.quantity_reserved, 0)  AS qty_available,
        sp.reorder_point,
        sp.reorder_quantity,
        sp.safety_stock_days,
        sp.preferred_vendor_id,
        ISNULL(vl.lead_time_days, 14)                          AS lead_time_days,
        sp.avg_daily_demand
    INTO #below_threshold
    FROM dbo.warehouse_stock    ws
    JOIN dbo.sku_params         sp ON sp.sku_id       = ws.sku_id
    LEFT JOIN dbo.vendor_lead_times vl
              ON  vl.vendor_id     = sp.preferred_vendor_id
              AND vl.sku_id        = ws.sku_id
    WHERE ws.warehouse_id = @warehouse_id
      AND (ws.quantity_on_hand - ISNULL(ws.quantity_reserved, 0)) < sp.reorder_point;

    -- Compute suggested order quantity: cover lead time + safety stock buffer
    SELECT
        sku_id,
        preferred_vendor_id,
        qty_available,
        reorder_point,
        CEILING(
            (lead_time_days + safety_stock_days) * avg_daily_demand
            - qty_available
        )                                                        AS suggested_qty,
        DATEADD(day, lead_time_days, @run_date)                  AS expected_delivery_date
    INTO #recommendations
    FROM #below_threshold
    WHERE avg_daily_demand > 0;

    -- Upsert into purchase_order_recommendations
    MERGE dbo.purchase_order_recommendations AS tgt
    USING #recommendations AS src
        ON  tgt.warehouse_id = @warehouse_id
        AND tgt.sku_id       = src.sku_id
        AND tgt.status       = 'OPEN'
    WHEN MATCHED AND src.suggested_qty > tgt.recommended_qty THEN
        UPDATE SET
            tgt.recommended_qty         = src.suggested_qty,
            tgt.expected_delivery_date  = src.expected_delivery_date,
            tgt.last_updated            = GETDATE()
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (warehouse_id, sku_id, vendor_id, recommended_qty,
                expected_delivery_date, status, created_at)
        VALUES (@warehouse_id, src.sku_id, src.preferred_vendor_id,
                src.suggested_qty, src.expected_delivery_date, 'OPEN', GETDATE())
    WHEN NOT MATCHED BY SOURCE
        AND tgt.warehouse_id = @warehouse_id
        AND tgt.status       = 'OPEN' THEN
        UPDATE SET tgt.status = 'CANCELLED', tgt.last_updated = GETDATE();

    -- Log replenishment run
    INSERT INTO dbo.replenishment_run_log
        (warehouse_id, run_date, skus_evaluated, skus_below_threshold, created_at)
    SELECT
        @warehouse_id,
        @run_date,
        (SELECT COUNT(*) FROM dbo.warehouse_stock WHERE warehouse_id = @warehouse_id),
        @@ROWCOUNT,
        GETDATE();
END
