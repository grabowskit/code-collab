-- Takes a point-in-time inventory snapshot by warehouse and SKU, computing
-- velocity (units sold per day), days-on-hand, and reorder urgency.
-- Writes to inventory_snapshots; safe to re-run (upserts on composite key).
CREATE OR REPLACE PROCEDURE proc_inventory_snapshot(
    p_snapshot_date DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_written INT;
BEGIN
    WITH
    -- Stock on hand per warehouse-SKU at snapshot date
    stock AS (
        SELECT
            warehouse_id,
            sku_id,
            SUM(quantity_received - COALESCE(quantity_consumed, 0))   AS qty_on_hand,
            SUM(quantity_reserved)                                      AS qty_reserved,
            MIN(receipt_date)                                           AS oldest_receipt_date
        FROM   inventory_batches
        WHERE  receipt_date <= p_snapshot_date
        GROUP BY warehouse_id, sku_id
        HAVING SUM(quantity_received - COALESCE(quantity_consumed, 0)) > 0
    ),

    -- 30-day sales velocity per warehouse-SKU
    velocity AS (
        SELECT
            sm.warehouse_id,
            sm.sku_id,
            COUNT(sm.movement_id)                                       AS transaction_count,
            SUM(sm.quantity)                                            AS units_sold_30d,
            SUM(sm.quantity)::NUMERIC / 30                              AS daily_velocity
        FROM   stock_movements sm
        WHERE  sm.movement_type = 'SALE'
          AND  sm.movement_date BETWEEN p_snapshot_date - 30 AND p_snapshot_date
        GROUP BY sm.warehouse_id, sm.sku_id
    ),

    -- Median unit cost via percentile
    cost AS (
        SELECT
            warehouse_id,
            sku_id,
            percentile_cont(0.5) WITHIN GROUP (ORDER BY unit_cost)     AS median_unit_cost,
            AVG(unit_cost)                                              AS avg_unit_cost
        FROM   inventory_batches
        WHERE  receipt_date <= p_snapshot_date
        GROUP BY warehouse_id, sku_id
    ),

    -- Combine and compute derived metrics
    snapshot AS (
        SELECT
            s.warehouse_id,
            s.sku_id,
            s.qty_on_hand,
            s.qty_reserved,
            s.qty_on_hand - COALESCE(s.qty_reserved, 0)                AS qty_available,
            COALESCE(v.daily_velocity, 0)                               AS daily_velocity,
            CASE WHEN COALESCE(v.daily_velocity, 0) > 0
                 THEN ROUND((s.qty_on_hand / v.daily_velocity)::NUMERIC, 1)
                 ELSE NULL END                                           AS days_on_hand,
            COALESCE(v.units_sold_30d, 0)                               AS units_sold_30d,
            c.median_unit_cost,
            ROUND((s.qty_on_hand * c.avg_unit_cost)::NUMERIC, 2)        AS inventory_value,
            DATE_TRUNC('week', p_snapshot_date)                         AS snapshot_week,
            sp.reorder_point,
            CASE
                WHEN s.qty_on_hand <= sp.reorder_point * 0.5             THEN 'CRITICAL'
                WHEN s.qty_on_hand <= sp.reorder_point                   THEN 'LOW'
                WHEN s.qty_on_hand <= sp.reorder_point * 2               THEN 'ADEQUATE'
                ELSE                                                           'OVERSTOCKED'
            END                                                          AS stock_status
        FROM       stock                s
        LEFT JOIN  velocity             v ON v.warehouse_id = s.warehouse_id AND v.sku_id = s.sku_id
        LEFT JOIN  cost                 c ON c.warehouse_id = s.warehouse_id AND c.sku_id = s.sku_id
        LEFT JOIN  sku_params           sp ON sp.sku_id     = s.sku_id
    )

    INSERT INTO inventory_snapshots (
        snapshot_date, warehouse_id, sku_id,
        qty_on_hand, qty_reserved, qty_available,
        daily_velocity, days_on_hand, units_sold_30d,
        median_unit_cost, inventory_value, snapshot_week,
        reorder_point, stock_status
    )
    SELECT
        p_snapshot_date,
        warehouse_id, sku_id,
        qty_on_hand, qty_reserved, qty_available,
        daily_velocity, days_on_hand, units_sold_30d,
        median_unit_cost, inventory_value, snapshot_week,
        reorder_point, stock_status
    FROM snapshot
    ON CONFLICT (snapshot_date, warehouse_id, sku_id)
    DO UPDATE SET
        qty_on_hand      = EXCLUDED.qty_on_hand,
        qty_available    = EXCLUDED.qty_available,
        daily_velocity   = EXCLUDED.daily_velocity,
        days_on_hand     = EXCLUDED.days_on_hand,
        inventory_value  = EXCLUDED.inventory_value,
        stock_status     = EXCLUDED.stock_status;

    GET DIAGNOSTICS v_rows_written = ROW_COUNT;
    RAISE NOTICE 'Inventory snapshot written for % warehouse-SKU combinations on %.', v_rows_written, p_snapshot_date;

END;
$$;
