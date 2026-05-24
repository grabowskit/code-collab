-- Archives orders and line items older than 7 years to cold-storage tables
-- on a linked server, then purges them from the transactional database.
-- Uses batched deletes to avoid long-running transactions.
CREATE PROCEDURE usp_data_archival_purge
    @cutoff_years   INT  = 7,
    @batch_size     INT  = 5000
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @cutoff_date    DATE = DATEADD(year, -@cutoff_years, CAST(GETDATE() AS DATE));
    DECLARE @rows_archived  INT  = 0;
    DECLARE @rows_deleted   INT  = 0;
    DECLARE @batch_rows     INT;

    -- Validate cold storage linked server is reachable
    IF NOT EXISTS (
        SELECT 1 FROM sys.servers WHERE name = 'ARCHIVE_LINKED_SRV' AND is_linked = 1
    )
    BEGIN
        RAISERROR('Linked server ARCHIVE_LINKED_SRV is not configured.', 16, 1);
        RETURN;
    END

    -- Ensure archive tables exist on the linked server; create if absent
    IF OBJECT_ID('ARCHIVE_LINKED_SRV.archive_db.dbo.orders_archive') IS NULL
    BEGIN
        EXEC ('CREATE TABLE archive_db.dbo.orders_archive (
                order_id        INT, customer_id INT, order_date DATE,
                total_amount    DECIMAL(12,2), status NVARCHAR(20),
                archived_at     DATETIME2
              )') AT ARCHIVE_LINKED_SRV;
    END

    -- Archive order line items first (FK child)
    INSERT INTO OPENQUERY(ARCHIVE_LINKED_SRV,
        'SELECT order_line_id, order_id, sku_id, quantity, unit_price, archived_at
         FROM archive_db.dbo.order_lines_archive')
    SELECT
        ol.order_line_id,
        ol.order_id,
        ol.sku_id,
        ol.quantity,
        ol.unit_price,
        GETDATE()
    FROM dbo.order_lines ol
    JOIN dbo.orders      o  ON o.order_id = ol.order_id
    WHERE o.order_date < @cutoff_date
      AND o.status IN ('DELIVERED', 'CANCELLED');

    SET @rows_archived = @@ROWCOUNT;

    -- Batched delete of archived line items
    SET @batch_rows = 1;
    WHILE @batch_rows > 0
    BEGIN
        DELETE TOP (@batch_size) ol
        FROM dbo.order_lines ol
        JOIN dbo.orders      o  ON o.order_id = ol.order_id
        WHERE o.order_date < @cutoff_date
          AND o.status IN ('DELIVERED', 'CANCELLED');

        SET @batch_rows = @@ROWCOUNT;
        SET @rows_deleted += @batch_rows;
    END

    -- Archive parent orders
    INSERT INTO OPENQUERY(ARCHIVE_LINKED_SRV,
        'SELECT order_id, customer_id, order_date, total_amount, status, archived_at
         FROM archive_db.dbo.orders_archive')
    SELECT
        order_id, customer_id, order_date, total_amount, status, GETDATE()
    FROM dbo.orders
    WHERE order_date < @cutoff_date
      AND status IN ('DELIVERED', 'CANCELLED');

    -- Batched delete of archived orders
    SET @batch_rows = 1;
    WHILE @batch_rows > 0
    BEGIN
        DELETE TOP (@batch_size)
        FROM dbo.orders
        WHERE order_date < @cutoff_date
          AND status IN ('DELIVERED', 'CANCELLED');

        SET @batch_rows  = @@ROWCOUNT;
        SET @rows_deleted += @batch_rows;
    END

    -- Purge orphaned audit rows no longer in scope
    DELETE FROM dbo.fulfillment_audit
    WHERE  order_line_id NOT IN (SELECT order_line_id FROM dbo.order_lines);

    -- Log the run
    INSERT INTO dbo.archival_run_log
        (run_date, cutoff_date, rows_archived, rows_deleted, completed_at)
    VALUES
        (CAST(GETDATE() AS DATE), @cutoff_date, @rows_archived, @rows_deleted, GETDATE());
END
