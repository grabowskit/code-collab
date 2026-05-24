-- Purges PII and expired records per GDPR data retention policy.
-- Reads retention rules from a config table; dynamically constructs and
-- executes DELETE statements per table with configurable batch sizes.
DO $$
DECLARE
    v_rule          RECORD;
    v_cutoff        DATE;
    v_sql           TEXT;
    v_total_deleted BIGINT  := 0;
    v_batch_deleted INT;
    v_batch_size    INT     := 5000;
    v_run_id        BIGINT;
BEGIN
    -- Create a run record for audit trail
    INSERT INTO data_retention_runs (started_at, status)
    VALUES (NOW(), 'RUNNING')
    RETURNING run_id INTO v_run_id;

    -- Iterate over all active retention rules
    FOR v_rule IN
        SELECT
            rr.table_name,
            rr.date_column,
            rr.retention_days,
            rr.anonymise_instead,
            rr.anonymise_columns,
            rr.where_clause
        FROM   data_retention_rules rr
        JOIN   information_schema.tables ist
               ON  ist.table_schema = 'public'
               AND ist.table_name   = rr.table_name
        WHERE  rr.is_active = TRUE
        ORDER BY rr.priority ASC
    LOOP
        v_cutoff := CURRENT_DATE - (v_rule.retention_days || ' days')::INTERVAL;

        -- Validate that the date column exists on the target table
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE  table_schema = 'public'
              AND  table_name   = v_rule.table_name
              AND  column_name  = v_rule.date_column
        ) THEN
            RAISE WARNING 'Skipping %: column % not found.', v_rule.table_name, v_rule.date_column;
            CONTINUE;
        END IF;

        IF v_rule.anonymise_instead THEN
            -- Anonymise PII columns rather than delete rows
            v_sql := format(
                'UPDATE %I SET %s WHERE %I < %L %s',
                v_rule.table_name,
                v_rule.anonymise_columns,   -- e.g. "email = ''REDACTED'', name = ''ANONYMISED''"
                v_rule.date_column,
                v_cutoff,
                COALESCE('AND ' || v_rule.where_clause, '')
            );
            EXECUTE v_sql;
            GET DIAGNOSTICS v_batch_deleted = ROW_COUNT;
            v_total_deleted := v_total_deleted + v_batch_deleted;

            RAISE NOTICE 'Anonymised % rows in %.', v_batch_deleted, v_rule.table_name;
        ELSE
            -- Batched delete loop to avoid long-running transactions
            LOOP
                v_sql := format(
                    'WITH batch AS (
                        SELECT ctid FROM %I
                        WHERE  %I < %L %s
                        LIMIT  %s
                    )
                    DELETE FROM %I WHERE ctid IN (SELECT ctid FROM batch)',
                    v_rule.table_name,
                    v_rule.date_column,
                    v_cutoff,
                    COALESCE('AND ' || v_rule.where_clause, ''),
                    v_batch_size,
                    v_rule.table_name
                );
                EXECUTE v_sql;
                GET DIAGNOSTICS v_batch_deleted = ROW_COUNT;
                v_total_deleted := v_total_deleted + v_batch_deleted;

                EXIT WHEN v_batch_deleted < v_batch_size;

                -- Yield briefly between batches to reduce lock contention
                PERFORM pg_sleep(0.05);
            END LOOP;

            RAISE NOTICE 'Purged % total rows from %.', v_total_deleted, v_rule.table_name;
        END IF;

        -- Log per-table result
        INSERT INTO data_retention_run_details
            (run_id, table_name, retention_days, cutoff_date, rows_affected, processed_at)
        VALUES
            (v_run_id, v_rule.table_name, v_rule.retention_days, v_cutoff, v_batch_deleted, NOW());

    END LOOP;

    -- Close run record
    UPDATE data_retention_runs
    SET    status          = 'COMPLETE',
           total_rows_affected = v_total_deleted,
           completed_at    = NOW()
    WHERE  run_id = v_run_id;

    RAISE NOTICE 'Data retention purge complete. Run %, total rows affected: %.', v_run_id, v_total_deleted;

EXCEPTION
    WHEN OTHERS THEN
        UPDATE data_retention_runs
        SET    status      = 'FAILED',
               error_msg   = SQLERRM,
               completed_at = NOW()
        WHERE  run_id = v_run_id;
        RAISE;
END;
$$;
