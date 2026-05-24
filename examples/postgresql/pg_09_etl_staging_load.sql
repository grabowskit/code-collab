-- Validates, deduplicates, and upserts raw CDC events from a Kafka-backed
-- staging table into the customers and orders dimension/fact tables.
-- Processes events in order, applying only the latest state per natural key.
CREATE OR REPLACE PROCEDURE proc_etl_staging_load(
    p_batch_id      BIGINT,
    p_rows_loaded   OUT INT,
    p_rows_rejected OUT INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_batch_start   TIMESTAMPTZ;
    v_batch_end     TIMESTAMPTZ;
BEGIN
    p_rows_loaded   := 0;
    p_rows_rejected := 0;

    -- Bounds for this batch
    SELECT MIN(event_ts), MAX(event_ts)
    INTO   v_batch_start, v_batch_end
    FROM   cdc_staging
    WHERE  batch_id = p_batch_id;

    IF NOT FOUND OR v_batch_start IS NULL THEN
        RAISE EXCEPTION 'Batch % not found in cdc_staging.', p_batch_id;
    END IF;

    -- Reject malformed rows (missing natural keys or bad timestamps)
    INSERT INTO etl_rejected_rows (batch_id, source_id, reject_reason, rejected_at)
    SELECT p_batch_id, raw_id,
           CASE
               WHEN natural_key IS NULL          THEN 'Missing natural_key'
               WHEN entity_type IS NULL          THEN 'Missing entity_type'
               WHEN payload     IS NULL          THEN 'Missing payload'
               WHEN event_ts    IS NULL          THEN 'Missing event_ts'
               WHEN entity_type NOT IN ('CUSTOMER', 'ORDER') THEN 'Unknown entity_type'
               ELSE 'Multiple issues'
           END,
           NOW()
    FROM   cdc_staging
    WHERE  batch_id = p_batch_id
      AND  (natural_key IS NULL OR entity_type IS NULL OR payload IS NULL
            OR event_ts IS NULL OR entity_type NOT IN ('CUSTOMER', 'ORDER'));

    GET DIAGNOSTICS p_rows_rejected = ROW_COUNT;

    -- Deduplicate: keep only the latest event per natural_key within the batch
    WITH latest_events AS (
        SELECT DISTINCT ON (natural_key, entity_type)
            raw_id,
            natural_key,
            entity_type,
            payload,
            event_ts,
            operation   -- INSERT, UPDATE, DELETE
        FROM  cdc_staging
        WHERE batch_id    = p_batch_id
          AND natural_key IS NOT NULL
          AND entity_type IS NOT NULL
        ORDER BY natural_key, entity_type, event_ts DESC
    ),

    -- Upsert customers
    customer_upsert AS (
        INSERT INTO dim_customers (
            customer_ext_id,
            customer_name,
            email,
            country_code,
            segment,
            created_at,
            updated_at
        )
        SELECT
            e.natural_key,
            e.payload->>'name',
            e.payload->>'email',
            e.payload->>'country_code',
            e.payload->>'segment',
            (e.payload->>'created_at')::timestamptz,
            e.event_ts
        FROM latest_events e
        WHERE e.entity_type = 'CUSTOMER'
          AND e.operation   IN ('INSERT', 'UPDATE')
        ON CONFLICT (customer_ext_id)
        DO UPDATE SET
            customer_name = EXCLUDED.customer_name,
            email         = EXCLUDED.email,
            country_code  = EXCLUDED.country_code,
            segment       = EXCLUDED.segment,
            updated_at    = EXCLUDED.updated_at
        WHERE EXCLUDED.updated_at > dim_customers.updated_at
        RETURNING customer_ext_id
    ),

    -- Upsert orders, resolving customer FK
    order_upsert AS (
        INSERT INTO fact_orders (
            order_ext_id,
            customer_id,
            order_date,
            order_amount,
            currency_code,
            status,
            batch_id,
            created_at,
            updated_at
        )
        SELECT
            e.natural_key,
            dc.customer_id,
            (e.payload->>'order_date')::date,
            (e.payload->>'order_amount')::numeric,
            COALESCE(e.payload->>'currency_code', 'USD'),
            e.payload->>'status',
            p_batch_id,
            (e.payload->>'created_at')::timestamptz,
            e.event_ts
        FROM   latest_events e
        JOIN   dim_customers dc ON dc.customer_ext_id = e.payload->>'customer_ext_id'
        WHERE  e.entity_type = 'ORDER'
          AND  e.operation   IN ('INSERT', 'UPDATE')
        ON CONFLICT (order_ext_id)
        DO UPDATE SET
            order_amount  = EXCLUDED.order_amount,
            status        = EXCLUDED.status,
            updated_at    = EXCLUDED.updated_at
        WHERE EXCLUDED.updated_at > fact_orders.updated_at
        RETURNING order_ext_id
    )

    SELECT COUNT(*) INTO p_rows_loaded FROM (
        SELECT customer_ext_id AS key FROM customer_upsert
        UNION ALL
        SELECT order_ext_id    AS key FROM order_upsert
    ) combined;

    -- Mark batch complete
    INSERT INTO etl_batch_log (batch_id, batch_start, batch_end, rows_loaded, rows_rejected, completed_at)
    VALUES (p_batch_id, v_batch_start, v_batch_end, p_rows_loaded, p_rows_rejected, NOW())
    ON CONFLICT (batch_id) DO UPDATE SET
        rows_loaded   = EXCLUDED.rows_loaded,
        rows_rejected = EXCLUDED.rows_rejected,
        completed_at  = EXCLUDED.completed_at;

    RAISE NOTICE 'Batch % complete: % loaded, % rejected.', p_batch_id, p_rows_loaded, p_rows_rejected;

END;
$$;
