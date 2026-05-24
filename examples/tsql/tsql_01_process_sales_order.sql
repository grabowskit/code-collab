-- Validates incoming sales orders, reserves inventory, and queues fulfillment.
-- Runs inside an explicit transaction; any failure rolls back all reservations.
CREATE PROCEDURE usp_process_sales_order
    @order_id       INT,
    @warehouse_id   INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @reserved_lines INT = 0;
    DECLARE @order_status   NVARCHAR(20);

    -- Validate order exists and is in PENDING state
    SELECT @order_status = status
    FROM   dbo.sales_orders WITH (NOLOCK)
    WHERE  order_id = @order_id;

    IF @order_status IS NULL
    BEGIN
        RAISERROR('Order %d not found.', 16, 1, @order_id);
        RETURN;
    END

    IF @order_status <> 'PENDING'
    BEGIN
        RAISERROR('Order %d is not in PENDING status (current: %s).', 16, 1, @order_id, @order_status);
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Stage order lines with available stock check
        SELECT
            ol.order_line_id,
            ol.sku_id,
            ol.quantity_ordered,
            ISNULL(ws.quantity_on_hand, 0)               AS qty_on_hand,
            ISNULL(ws.quantity_reserved, 0)               AS qty_reserved,
            ISNULL(ws.quantity_on_hand, 0)
                - ISNULL(ws.quantity_reserved, 0)         AS qty_available
        INTO #order_lines
        FROM dbo.sales_order_lines  ol
        LEFT JOIN dbo.warehouse_stock ws
            ON  ws.sku_id       = ol.sku_id
            AND ws.warehouse_id = @warehouse_id
        WHERE ol.order_id = @order_id;

        -- Reject if any line cannot be fulfilled
        IF EXISTS (
            SELECT 1 FROM #order_lines
            WHERE  qty_available < quantity_ordered
        )
        BEGIN
            ROLLBACK TRANSACTION;
            RAISERROR('Insufficient stock for one or more order lines on order %d.', 16, 1, @order_id);
            RETURN;
        END

        -- Reserve stock
        UPDATE ws
        SET    ws.quantity_reserved = ws.quantity_reserved + ol.quantity_ordered,
               ws.last_updated      = GETDATE()
        FROM   dbo.warehouse_stock ws
        JOIN   #order_lines        ol ON ol.sku_id = ws.sku_id
        WHERE  ws.warehouse_id = @warehouse_id;

        SET @reserved_lines = @@ROWCOUNT;

        -- Write fulfillment queue entries, capturing new IDs
        INSERT INTO dbo.fulfillment_queue
            (order_id, order_line_id, sku_id, quantity, warehouse_id, queued_at, status)
        OUTPUT
            inserted.fulfillment_id,
            inserted.order_line_id
        INTO dbo.fulfillment_audit (fulfillment_id, order_line_id)
        SELECT
            @order_id,
            order_line_id,
            sku_id,
            quantity_ordered,
            @warehouse_id,
            GETDATE(),
            'QUEUED'
        FROM #order_lines;

        -- Advance order status
        UPDATE dbo.sales_orders
        SET    status     = 'RESERVED',
               updated_at = GETDATE()
        WHERE  order_id   = @order_id;

        COMMIT TRANSACTION;

        PRINT CAST(@reserved_lines AS VARCHAR) + ' lines reserved for order ' + CAST(@order_id AS VARCHAR);

    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END
