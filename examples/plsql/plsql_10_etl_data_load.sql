-- Loads and transforms flat-file staging data from an external table into
-- normalised customer dimension and sales fact tables. Uses parallel hints,
-- MERGE for upserts, and gathers stats post-load.
CREATE OR REPLACE PROCEDURE proc_etl_data_load (
    p_load_date     IN  DATE DEFAULT TRUNC(SYSDATE),
    p_rows_loaded   OUT NUMBER,
    p_rows_rejected OUT NUMBER
) IS
    v_batch_id      NUMBER;
    v_error_msg     VARCHAR2(4000);
BEGIN
    p_rows_loaded   := 0;
    p_rows_rejected := 0;

    -- Generate batch ID for lineage tracking
    SELECT etl_batch_seq.NEXTVAL INTO v_batch_id FROM DUAL;

    -- Log batch start
    INSERT INTO etl_run_log (batch_id, load_date, status, started_at)
    VALUES (v_batch_id, p_load_date, 'RUNNING', SYSDATE);
    COMMIT;

    -- Validate staging rows: reject nulls on mandatory fields
    INSERT INTO etl_rejected_rows (batch_id, raw_row, reject_reason, rejected_at)
    SELECT v_batch_id, s.raw_line,
           CASE
               WHEN s.customer_ext_id IS NULL THEN 'Missing customer_ext_id'
               WHEN s.order_amount IS NULL     THEN 'Missing order_amount'
               WHEN s.order_date IS NULL        THEN 'Missing order_date'
               ELSE                                  'Multiple nulls'
           END,
           SYSDATE
    FROM   stg_sales_flat s
    WHERE  s.load_date   = p_load_date
      AND  (s.customer_ext_id IS NULL OR s.order_amount IS NULL OR s.order_date IS NULL);

    p_rows_rejected := SQL%ROWCOUNT;

    -- Upsert customer dimension (SCD Type 1)
    MERGE /*+ PARALLEL(dim_customers, 8) */ INTO dim_customers tgt
    USING (
        SELECT DISTINCT
               s.customer_ext_id,
               s.customer_name,
               s.customer_email,
               s.country_code,
               s.industry_code,
               p_load_date AS load_date
        FROM   stg_sales_flat s
        WHERE  s.load_date          = p_load_date
          AND  s.customer_ext_id IS NOT NULL
    ) src
    ON (tgt.customer_ext_id = src.customer_ext_id)
    WHEN MATCHED THEN
        UPDATE SET
            tgt.customer_name  = src.customer_name,
            tgt.customer_email = src.customer_email,
            tgt.country_code   = src.country_code,
            tgt.industry_code  = src.industry_code,
            tgt.last_seen_date = src.load_date
    WHEN NOT MATCHED THEN
        INSERT (customer_ext_id, customer_name, customer_email,
                country_code, industry_code, first_seen_date, last_seen_date)
        VALUES (src.customer_ext_id, src.customer_name, src.customer_email,
                src.country_code, src.industry_code, src.load_date, src.load_date);

    -- Load sales fact with FK resolution
    INSERT /*+ APPEND PARALLEL(fact_sales, 8) */ INTO fact_sales (
        batch_id, customer_id, order_ext_id,
        order_date, order_amount, currency_code,
        product_category, discount_pct, net_amount,
        load_date
    )
    SELECT /*+ PARALLEL(s, 8) PARALLEL(c, 8) */
        v_batch_id,
        c.customer_id,
        s.order_ext_id,
        TO_DATE(s.order_date, 'YYYY-MM-DD'),
        s.order_amount,
        NVL(s.currency_code, 'USD'),
        s.product_category,
        NVL(s.discount_pct, 0),
        ROUND(s.order_amount * (1 - NVL(s.discount_pct, 0) / 100), 2),
        p_load_date
    FROM       stg_sales_flat  s
    JOIN       dim_customers   c ON c.customer_ext_id = s.customer_ext_id
    WHERE      s.load_date          = p_load_date
      AND      s.customer_ext_id IS NOT NULL
      AND      s.order_amount   IS NOT NULL;

    p_rows_loaded := SQL%ROWCOUNT;

    -- Gather table stats post-load for query optimiser
    DBMS_STATS.GATHER_TABLE_STATS(
        ownname     => 'DW_OWNER',
        tabname     => 'FACT_SALES',
        estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
        method_opt  => 'FOR ALL COLUMNS SIZE AUTO',
        degree      => 8,
        cascade     => TRUE
    );

    -- Close batch log
    UPDATE etl_run_log
    SET    status       = 'COMPLETE',
           rows_loaded  = p_rows_loaded,
           rows_rejected= p_rows_rejected,
           completed_at = SYSDATE
    WHERE  batch_id     = v_batch_id;

    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        v_error_msg := SQLERRM;
        UPDATE etl_run_log
        SET    status    = 'FAILED',
               error_msg = v_error_msg
        WHERE  batch_id  = v_batch_id;
        COMMIT;
        p_rows_loaded   := 0;
        RAISE;
END proc_etl_data_load;
