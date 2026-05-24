-- Posts balanced journal entry batches to the General Ledger.
-- Validates debit/credit balance, applies multi-currency FX conversion,
-- and writes an audit file via UTL_FILE.
CREATE OR REPLACE PROCEDURE proc_gl_journal_posting (
    p_batch_id      IN  NUMBER,
    p_posted_by     IN  VARCHAR2,
    p_entries_posted OUT NUMBER
) IS
    v_total_debits   NUMBER := 0;
    v_total_credits  NUMBER := 0;
    v_fx_rate        NUMBER;
    v_period_open    VARCHAR2(1);
    v_file_handle    UTL_FILE.FILE_TYPE;
    v_audit_dir      VARCHAR2(100) := 'GL_AUDIT_DIR';
    v_audit_file     VARCHAR2(200) := 'gl_batch_' || p_batch_id || '_' || TO_CHAR(SYSDATE,'YYYYMMDD') || '.log';
    v_sql            VARCHAR2(4000);
    v_session_user   VARCHAR2(100) := SYS_CONTEXT('USERENV', 'SESSION_USER');

    CURSOR c_entries IS
        SELECT  je.entry_id, je.account_code, je.entry_type,
                je.amount, je.currency_code, je.period_id
        FROM    journal_entries je
        WHERE   je.batch_id = p_batch_id
          AND   je.status   = 'DRAFT'
        ORDER BY je.entry_id;
BEGIN
    -- Verify the accounting period is open
    BEGIN
        SELECT is_open
        INTO   v_period_open
        FROM   gl_periods
        WHERE  period_id = (
            SELECT MAX(period_id) FROM journal_entries WHERE batch_id = p_batch_id
        );
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20001, 'No period found for batch ' || p_batch_id);
    END;

    IF v_period_open = 'N' THEN
        RAISE_APPLICATION_ERROR(-20002, 'Accounting period is closed — cannot post.');
    END IF;

    -- Validate batch is balanced (total debits = total credits per currency)
    SELECT NVL(SUM(CASE WHEN entry_type = 'DR' THEN amount ELSE 0 END), 0),
           NVL(SUM(CASE WHEN entry_type = 'CR' THEN amount ELSE 0 END), 0)
    INTO   v_total_debits, v_total_credits
    FROM   journal_entries
    WHERE  batch_id     = p_batch_id
      AND  currency_code = 'USD'
      AND  status        = 'DRAFT';

    IF ROUND(v_total_debits - v_total_credits, 2) <> 0 THEN
        RAISE_APPLICATION_ERROR(-20003,
            'Batch ' || p_batch_id || ' is out of balance: DR=' || v_total_debits || ' CR=' || v_total_credits);
    END IF;

    -- Open audit file
    v_file_handle := UTL_FILE.FOPEN(v_audit_dir, v_audit_file, 'W', 32767);
    UTL_FILE.PUT_LINE(v_file_handle, 'GL Post — Batch: ' || p_batch_id
        || ' | User: ' || v_session_user
        || ' | ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
    UTL_FILE.PUT_LINE(v_file_handle, '---');

    p_entries_posted := 0;

    -- Post each entry; apply FX conversion for non-USD lines
    FOR rec IN c_entries LOOP
        IF rec.currency_code <> 'USD' THEN
            v_sql := 'SELECT rate FROM fx_rates_' || rec.currency_code
                     || ' WHERE rate_date = TRUNC(SYSDATE)';
            EXECUTE IMMEDIATE v_sql INTO v_fx_rate;
        ELSE
            v_fx_rate := 1;
        END IF;

        UPDATE journal_entries
        SET    status          = 'POSTED',
               usd_amount      = ROUND(amount * v_fx_rate, 2),
               fx_rate_applied = v_fx_rate,
               posted_by       = p_posted_by,
               posted_at       = SYSDATE
        WHERE  entry_id        = rec.entry_id;

        -- Update GL account running balance
        UPDATE gl_account_balances
        SET    balance = balance
                       + CASE WHEN rec.entry_type = 'DR' THEN ROUND(rec.amount * v_fx_rate, 2)
                              ELSE -ROUND(rec.amount * v_fx_rate, 2) END,
               last_posted_at = SYSDATE
        WHERE  account_code = rec.account_code
          AND  period_id    = rec.period_id;

        UTL_FILE.PUT_LINE(v_file_handle,
            'POSTED | entry=' || rec.entry_id
            || ' acct=' || rec.account_code
            || ' ' || rec.entry_type
            || ' ' || rec.amount || ' ' || rec.currency_code
            || ' fx=' || v_fx_rate);

        p_entries_posted := p_entries_posted + 1;
    END LOOP;

    -- Update batch header
    UPDATE journal_entry_batches
    SET    status        = 'POSTED',
           posted_by     = p_posted_by,
           posted_at     = SYSDATE,
           entries_count = p_entries_posted
    WHERE  batch_id      = p_batch_id;

    UTL_FILE.PUT_LINE(v_file_handle, '---');
    UTL_FILE.PUT_LINE(v_file_handle, 'Total posted: ' || p_entries_posted);
    UTL_FILE.FCLOSE(v_file_handle);

    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        IF UTL_FILE.IS_OPEN(v_file_handle) THEN
            UTL_FILE.FCLOSE(v_file_handle);
        END IF;
        RAISE;
END proc_gl_journal_posting;
