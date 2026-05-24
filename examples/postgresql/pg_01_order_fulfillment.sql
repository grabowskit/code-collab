-- Reserves inventory for an order, creates shipment records, and advances order
-- status atomically. Uses advisory locks to prevent race conditions on the same
-- order and SKIP LOCKED to avoid blocking parallel fulfillment workers.
CREATE OR REPLACE PROCEDURE proc_order_fulfillment(
    p_order_id      INT,
    p_warehouse_id  INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_order_status  TEXT;
    v_lines_count   INT := 0;
    v_shipment_id   INT;
    r_line          RECORD;
    v_row_count     INT;
BEGIN
    -- Advisory lock scoped to this transaction to serialise concurrent calls
    PERFORM pg_advisory_xact_lock(p_order_id);

    -- Validate order state
    SELECT status INTO v_order_status
    FROM   orders
    WHERE  order_id = p_order_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order % not found.', p_order_id;
    END IF;

    IF v_order_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Order % is in status %; expected PENDING.', p_order_id, v_order_status;
    END IF;

    -- Lock inventory rows we intend to update; skip if another worker holds them
    FOR r_line IN
        SELECT ol.order_line_id, ol.sku_id, ol.quantity_ordered,
               ws.quantity_on_hand - COALESCE(ws.quantity_reserved, 0) AS qty_available
        FROM   order_lines     ol
        JOIN   warehouse_stock ws
               ON  ws.sku_id       = ol.sku_id
               AND ws.warehouse_id = p_warehouse_id
        WHERE  ol.order_id = p_order_id
        FOR UPDATE OF ws SKIP LOCKED
    LOOP
        IF r_line.qty_available < r_line.quantity_ordered THEN
            RAISE EXCEPTION 'Insufficient stock for SKU % on order %.', r_line.sku_id, p_order_id;
        END IF;

        -- Reserve stock
        UPDATE warehouse_stock
        SET    quantity_reserved = quantity_reserved + r_line.quantity_ordered,
               updated_at        = NOW()
        WHERE  sku_id        = r_line.sku_id
          AND  warehouse_id  = p_warehouse_id;

        v_lines_count := v_lines_count + 1;
    END LOOP;

    IF v_lines_count = 0 THEN
        RAISE EXCEPTION 'No inventory rows available to lock for order %. Another worker may be processing it.', p_order_id;
    END IF;

    -- Create shipment header
    INSERT INTO shipments (order_id, warehouse_id, status, created_at)
    VALUES (p_order_id, p_warehouse_id, 'PENDING', NOW())
    RETURNING shipment_id INTO v_shipment_id;

    -- Create shipment line items
    INSERT INTO shipment_lines (shipment_id, order_line_id, sku_id, quantity)
    SELECT v_shipment_id, ol.order_line_id, ol.sku_id, ol.quantity_ordered
    FROM   order_lines ol
    WHERE  ol.order_id = p_order_id;

    GET DIAGNOSTICS v_row_count = ROW_COUNT;
    RAISE NOTICE 'Shipment % created with % lines for order %.', v_shipment_id, v_row_count, p_order_id;

    -- Advance order status
    UPDATE orders
    SET    status     = 'RESERVED',
           updated_at = NOW()
    WHERE  order_id   = p_order_id;

END;
$$;
