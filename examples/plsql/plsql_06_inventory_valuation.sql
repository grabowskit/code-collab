-- Calculates period-end inventory valuation using FIFO cost layering.
-- Processes receipt batches in chronological order to unwind cost layers
-- against consumption, then writes both FIFO and weighted-average values.
CREATE OR REPLACE PROCEDURE proc_inventory_valuation (
    p_period_end    IN  DATE,
    p_warehouse_id  IN  NUMBER,
    p_rows_written  OUT NUMBER
) IS
    v_remaining_qty NUMBER;
    v_fifo_cost     NUMBER;
    v_wa_cost       NUMBER;
    v_total_qty     NUMBER;
    v_total_value   NUMBER;

    -- All SKUs with stock movements in the period
    CURSOR c_skus IS
        SELECT DISTINCT sku_id
        FROM   stock_movements
        WHERE  warehouse_id  = p_warehouse_id
          AND  movement_date <= p_period_end;

    -- Receipt batches in FIFO order for a given SKU
    CURSOR c_batches (p_sku_id NUMBER) IS
        SELECT  batch_id,
                receipt_date,
                quantity_received,
                quantity_consumed,
                unit_cost,
                LISTAGG(batch_id, ',') WITHIN GROUP (ORDER BY receipt_date)
                    OVER (PARTITION BY sku_id) AS batch_chain
        FROM    inventory_batches
        WHERE   sku_id        = p_sku_id
          AND   warehouse_id  = p_warehouse_id
          AND   receipt_date  <= p_period_end
        ORDER BY receipt_date ASC;

BEGIN
    p_rows_written := 0;

    FOR sku_rec IN c_skus LOOP
        v_remaining_qty := 0;
        v_fifo_cost     := 0;
        v_total_qty     := 0;
        v_total_value   := 0;

        -- Determine on-hand quantity at period end
        SELECT NVL(SUM(quantity_received - quantity_consumed), 0)
        INTO   v_remaining_qty
        FROM   inventory_batches
        WHERE  sku_id       = sku_rec.sku_id
          AND  warehouse_id = p_warehouse_id
          AND  receipt_date <= p_period_end;

        -- Walk batches oldest-first to compute FIFO value
        DECLARE
            v_to_value  NUMBER := v_remaining_qty;
            v_batch_qty NUMBER;
        BEGIN
            FOR b IN c_batches(sku_rec.sku_id) LOOP
                EXIT WHEN v_to_value <= 0;
                -- Available quantity in this batch
                v_batch_qty := GREATEST(0,
                    b.quantity_received - NVL(b.quantity_consumed, 0));
                -- Take the lesser of what's left to value and batch availability
                v_fifo_cost := v_fifo_cost
                    + LEAST(v_to_value, v_batch_qty) * b.unit_cost;
                v_to_value  := v_to_value - v_batch_qty;

                v_total_qty   := v_total_qty   + b.quantity_received;
                v_total_value := v_total_value + b.quantity_received * b.unit_cost;
            END LOOP;
        END;

        -- Weighted average cost
        v_wa_cost := CASE WHEN v_total_qty > 0
                          THEN v_total_value / v_total_qty
                          ELSE 0 END;

        -- Write valuation record
        MERGE INTO inventory_valuation tgt
        USING (SELECT sku_rec.sku_id AS sku_id FROM DUAL) src
            ON (    tgt.sku_id       = src.sku_id
                AND tgt.warehouse_id = p_warehouse_id
                AND tgt.period_end   = p_period_end)
        WHEN MATCHED THEN
            UPDATE SET
                tgt.qty_on_hand    = v_remaining_qty,
                tgt.fifo_value     = ROUND(v_fifo_cost, 2),
                tgt.wa_unit_cost   = ROUND(v_wa_cost,   4),
                tgt.wa_total_value = ROUND(v_remaining_qty * v_wa_cost, 2),
                tgt.last_updated   = SYSDATE
        WHEN NOT MATCHED THEN
            INSERT (sku_id, warehouse_id, period_end,
                    qty_on_hand, fifo_value, wa_unit_cost, wa_total_value, created_at)
            VALUES (sku_rec.sku_id, p_warehouse_id, p_period_end,
                    v_remaining_qty,
                    ROUND(v_fifo_cost, 2),
                    ROUND(v_wa_cost,   4),
                    ROUND(v_remaining_qty * v_wa_cost, 2),
                    SYSDATE);

        p_rows_written := p_rows_written + 1;
    END LOOP;

    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_rows_written := 0;
        RAISE;
END proc_inventory_valuation;
