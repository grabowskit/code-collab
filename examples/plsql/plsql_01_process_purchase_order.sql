-- Validates multi-line purchase orders against budget codes and approval
-- authority matrices, then commits approved lines and rejects overspend lines.
CREATE OR REPLACE PROCEDURE proc_process_purchase_order (
    p_po_id         IN  NUMBER,
    p_approved_by   IN  NUMBER,
    p_result_code   OUT VARCHAR2,
    p_message       OUT VARCHAR2
) IS
    TYPE t_po_lines IS TABLE OF po_lines%ROWTYPE INDEX BY PLS_INTEGER;
    v_lines         t_po_lines;
    v_total_amount  NUMBER := 0;
    v_budget_avail  NUMBER;
    v_approval_limit NUMBER;
    v_line_count    NUMBER := 0;
    v_rejected      NUMBER := 0;

    CURSOR c_po_lines IS
        SELECT pol.*
        FROM   po_lines    pol
        JOIN   purchase_orders po ON po.po_id = pol.po_id
        WHERE  pol.po_id   = p_po_id
          AND  pol.status  = 'PENDING'
        ORDER BY pol.line_num;

BEGIN
    -- Validate PO exists and is in SUBMITTED state
    BEGIN
        SELECT status INTO p_result_code
        FROM   purchase_orders
        WHERE  po_id = p_po_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            p_result_code := 'ERROR';
            p_message     := 'Purchase order ' || p_po_id || ' not found.';
            RETURN;
    END;

    IF p_result_code <> 'SUBMITTED' THEN
        p_result_code := 'ERROR';
        p_message     := 'PO is not in SUBMITTED status.';
        RETURN;
    END IF;

    -- Fetch approver authority limit
    SELECT approval_limit
    INTO   v_approval_limit
    FROM   approval_matrix
    WHERE  user_id    = p_approved_by
      AND  SYSDATE BETWEEN effective_date AND NVL(end_date, SYSDATE);

    -- Bulk collect all pending lines
    OPEN c_po_lines;
    FETCH c_po_lines BULK COLLECT INTO v_lines LIMIT 500;
    CLOSE c_po_lines;

    -- Validate and accumulate total
    FOR i IN 1 .. v_lines.COUNT LOOP
        v_total_amount := v_total_amount + v_lines(i).quantity * v_lines(i).unit_price;
        v_line_count   := v_line_count + 1;
    END LOOP;

    IF v_total_amount > v_approval_limit THEN
        p_result_code := 'ESCALATE';
        p_message     := 'PO total $' || v_total_amount || ' exceeds approver limit $' || v_approval_limit;
        UPDATE purchase_orders
        SET    status         = 'ESCALATED',
               last_updated   = SYSDATE
        WHERE  po_id          = p_po_id;
        COMMIT;
        RETURN;
    END IF;

    -- Check budget availability per cost centre
    FOR i IN 1 .. v_lines.COUNT LOOP
        SAVEPOINT before_line;
        BEGIN
            SELECT remaining_budget
            INTO   v_budget_avail
            FROM   budget_codes
            WHERE  cost_centre_id  = v_lines(i).cost_centre_id
              AND  fiscal_year     = TO_NUMBER(TO_CHAR(SYSDATE, 'YYYY'))
            FOR UPDATE NOWAIT;

            IF v_budget_avail >= v_lines(i).quantity * v_lines(i).unit_price THEN
                -- Approve line and decrement budget
                UPDATE po_lines
                SET    status       = 'APPROVED',
                       approved_by  = p_approved_by,
                       approved_at  = SYSDATE
                WHERE  po_line_id   = v_lines(i).po_line_id
                RETURNING po_line_id, quantity * unit_price INTO v_lines(i).po_line_id, v_total_amount;

                UPDATE budget_codes
                SET    remaining_budget = remaining_budget - (v_lines(i).quantity * v_lines(i).unit_price),
                       last_updated     = SYSDATE
                WHERE  cost_centre_id  = v_lines(i).cost_centre_id
                  AND  fiscal_year     = TO_NUMBER(TO_CHAR(SYSDATE, 'YYYY'));
            ELSE
                ROLLBACK TO before_line;
                UPDATE po_lines
                SET    status     = 'REJECTED',
                       reject_reason = 'Insufficient budget'
                WHERE  po_line_id = v_lines(i).po_line_id;
                v_rejected := v_rejected + 1;
            END IF;
        EXCEPTION
            WHEN RESOURCE_BUSY THEN
                ROLLBACK TO before_line;
                DBMS_OUTPUT.PUT_LINE('Budget lock conflict on line ' || i || ', skipping.');
                v_rejected := v_rejected + 1;
        END;
    END LOOP;

    -- Set overall PO status
    UPDATE purchase_orders
    SET    status       = CASE WHEN v_rejected = 0 THEN 'APPROVED' ELSE 'PARTIAL' END,
           approved_by  = p_approved_by,
           approved_at  = SYSDATE,
           last_updated = SYSDATE
    WHERE  po_id        = p_po_id;

    COMMIT;

    p_result_code := 'OK';
    p_message     := v_line_count || ' lines processed, ' || v_rejected || ' rejected.';

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result_code := 'ERROR';
        p_message     := SQLERRM;
        RAISE;
END proc_process_purchase_order;
