-- Selects supplier invoices due for payment based on due date and early-
-- payment discount windows, checks cash availability, creates payment records,
-- and returns a cursor of selected invoices to the caller.
CREATE OR REPLACE PROCEDURE proc_ap_payment_run (
    p_payment_date  IN  DATE,
    p_bank_account  IN  VARCHAR2,
    p_max_outflow   IN  NUMBER,
    p_invoice_cur   OUT SYS_REFCURSOR,
    p_total_paid    OUT NUMBER
) IS
    PRAGMA AUTONOMOUS_TRANSACTION;

    v_bank_balance  NUMBER;
    v_running_total NUMBER := 0;
    v_discount_amt  NUMBER;
    v_pay_amount    NUMBER;
    v_run_id        NUMBER;

    TYPE t_inv_ids  IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    v_paid_ids      t_inv_ids;
    v_idx           PLS_INTEGER := 0;

BEGIN
    p_total_paid := 0;

    -- Get available cash balance (lock to prevent concurrent payment runs)
    SELECT available_balance
    INTO   v_bank_balance
    FROM   bank_accounts
    WHERE  account_code = p_bank_account
    FOR UPDATE NOWAIT;

    IF v_bank_balance < 1000 THEN
        RAISE_APPLICATION_ERROR(-20010, 'Insufficient cash balance for payment run.');
    END IF;

    -- Create payment run header
    INSERT INTO payment_runs (run_date, bank_account, status, created_at)
    VALUES (p_payment_date, p_bank_account, 'IN_PROGRESS', SYSDATE)
    RETURNING run_id INTO v_run_id;

    -- Select invoices: due within 5 days, or in early-payment discount window
    FOR inv IN (
        SELECT  si.invoice_id,
                si.supplier_id,
                si.invoice_amount - NVL(si.amount_paid, 0)  AS balance_due,
                si.due_date,
                si.discount_pct,
                si.discount_deadline,
                TO_DATE(si.invoice_date, 'YYYY-MM-DD')       AS invoice_date
        FROM    supplier_invoices si
        JOIN    suppliers          s  ON s.supplier_id = si.supplier_id
        WHERE   si.status         IN ('APPROVED', 'PARTIAL')
          AND   si.due_date        <= p_payment_date + 5
          AND   s.payment_hold     = 'N'
          AND   si.bank_account    = p_bank_account
        ORDER BY
            CASE WHEN si.discount_deadline >= p_payment_date THEN 0 ELSE 1 END,
            si.due_date
        FETCH BULK COLLECT INTO v_paid_ids LIMIT 500
    ) LOOP
        -- Apply early payment discount if within window
        IF inv.discount_deadline IS NOT NULL AND inv.discount_deadline >= p_payment_date THEN
            v_discount_amt := ROUND(inv.balance_due * inv.discount_pct / 100, 2);
        ELSE
            v_discount_amt := 0;
        END IF;

        v_pay_amount := inv.balance_due - v_discount_amt;

        -- Stop if we would exceed cash limit or max outflow
        EXIT WHEN v_running_total + v_pay_amount > LEAST(v_bank_balance, p_max_outflow);

        -- Record payment
        INSERT INTO payments (
            payment_run_id, invoice_id, supplier_id,
            payment_date,   gross_amount, discount_taken, net_amount,
            bank_account,   status,       created_at
        ) VALUES (
            v_run_id, inv.invoice_id, inv.supplier_id,
            p_payment_date, inv.balance_due, v_discount_amt, v_pay_amount,
            p_bank_account, 'PENDING', SYSDATE
        );

        UPDATE supplier_invoices
        SET    amount_paid   = NVL(amount_paid, 0) + v_pay_amount,
               status        = CASE WHEN amount_paid + v_pay_amount >= invoice_amount
                                    THEN 'PAID' ELSE 'PARTIAL' END,
               last_updated  = SYSDATE
        WHERE  invoice_id    = inv.invoice_id;

        v_running_total := v_running_total + v_pay_amount;
        p_total_paid    := p_total_paid    + v_pay_amount;
    END LOOP;

    -- Debit bank account
    UPDATE bank_accounts
    SET    available_balance = available_balance - p_total_paid,
           last_updated      = SYSDATE
    WHERE  account_code      = p_bank_account;

    -- Finalise run
    UPDATE payment_runs
    SET    status        = 'COMPLETE',
           total_amount  = p_total_paid,
           completed_at  = SYSDATE
    WHERE  run_id        = v_run_id;

    COMMIT;

    -- Return selected invoice details to caller
    OPEN p_invoice_cur FOR
        SELECT p.payment_id, p.invoice_id, p.supplier_id,
               p.gross_amount, p.discount_taken, p.net_amount
        FROM   payments p
        WHERE  p.payment_run_id = v_run_id;

EXCEPTION
    WHEN RESOURCE_BUSY THEN
        RAISE_APPLICATION_ERROR(-20011, 'Payment run already in progress for account ' || p_bank_account);
    WHEN OTHERS THEN
        ROLLBACK;
        p_total_paid := 0;
        RAISE;
END proc_ap_payment_run;
