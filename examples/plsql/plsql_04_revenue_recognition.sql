-- Applies ASC 606 revenue recognition rules: identifies performance obligations
-- on software contracts, allocates the transaction price proportionally, and
-- spreads recognised revenue over the obligation delivery schedule.
CREATE OR REPLACE PROCEDURE proc_revenue_recognition (
    p_period_start  IN  DATE,
    p_period_end    IN  DATE,
    p_rows_written  OUT NUMBER
) IS
    TYPE t_contract_rec IS RECORD (
        contract_id         contracts.contract_id%TYPE,
        total_contract_value contracts.total_contract_value%TYPE,
        currency_code       contracts.currency_code%TYPE
    );
    TYPE t_contract_tab IS TABLE OF t_contract_rec;
    v_contracts     t_contract_tab;

    v_total_ssp     NUMBER;
    v_alloc_price   NUMBER;
    v_period_days   NUMBER;
    v_recog_amount  NUMBER;

BEGIN
    p_rows_written := 0;

    -- Bulk collect active contracts with obligations in this period
    SELECT contract_id, total_contract_value, currency_code
    BULK COLLECT INTO v_contracts
    FROM contracts
    WHERE contract_status = 'ACTIVE'
      AND start_date <= p_period_end
      AND (end_date IS NULL OR end_date >= p_period_start)
      AND recognition_method = 'ASC606';

    FOR i IN 1 .. v_contracts.COUNT LOOP
        -- Sum standalone selling prices of all obligations on this contract
        SELECT NVL(SUM(standalone_selling_price), 0)
        INTO   v_total_ssp
        FROM   performance_obligations
        WHERE  contract_id = v_contracts(i).contract_id
          AND  status      IN ('OPEN', 'IN_PROGRESS');

        -- Skip if no SSP data (can't allocate)
        CONTINUE WHEN v_total_ssp = 0;

        -- Allocate and recognise revenue per obligation
        FOR ob IN (
            SELECT  ob_id, obligation_type, standalone_selling_price,
                    delivery_start_date, delivery_end_date
            FROM    performance_obligations
            WHERE   contract_id  = v_contracts(i).contract_id
              AND   status       IN ('OPEN', 'IN_PROGRESS')
              AND   delivery_end_date >= p_period_start
        ) LOOP
            -- Proportional allocation of transaction price
            v_alloc_price := v_contracts(i).total_contract_value
                             * (ob.standalone_selling_price / v_total_ssp);

            -- Days of the obligation that fall within the current period
            v_period_days := LEAST(ob.delivery_end_date,   p_period_end)
                           - GREATEST(ob.delivery_start_date, p_period_start)
                           + 1;

            -- Total obligation duration in days
            v_recog_amount := v_alloc_price
                * v_period_days
                / GREATEST(ob.delivery_end_date - ob.delivery_start_date + 1, 1);

            INSERT INTO revenue_recognition_schedule (
                contract_id, ob_id, period_start, period_end,
                allocated_price, recognised_amount, currency_code,
                recognition_basis, created_at
            ) VALUES (
                v_contracts(i).contract_id,
                ob.ob_id,
                p_period_start,
                p_period_end,
                ROUND(v_alloc_price,   2),
                ROUND(v_recog_amount,  2),
                v_contracts(i).currency_code,
                'TIME_ELAPSED',
                SYSDATE
            );

            p_rows_written := p_rows_written + 1;

            -- Mark obligation complete if delivery end falls within this period
            IF ob.delivery_end_date <= p_period_end THEN
                UPDATE performance_obligations
                SET    status       = 'COMPLETE',
                       completed_at = SYSDATE
                WHERE  ob_id        = ob.ob_id;
            END IF;
        END LOOP;
    END LOOP;

    -- Summarise period revenue into gl_staging for journal entry creation
    INSERT INTO gl_revenue_staging (
        period_start, period_end, contract_id, total_recognised, currency_code, staged_at
    )
    SELECT
        p_period_start,
        p_period_end,
        contract_id,
        SUM(recognised_amount),
        currency_code,
        SYSDATE
    FROM   revenue_recognition_schedule
    WHERE  period_start = p_period_start
      AND  period_end   = p_period_end
    GROUP BY contract_id, currency_code;

    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_rows_written := 0;
        RAISE;
END proc_revenue_recognition;
