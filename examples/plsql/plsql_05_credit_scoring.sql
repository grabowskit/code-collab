-- Generates B2B credit scores for customers using payment history,
-- credit utilisation, and industry risk band, then updates credit limits.
CREATE OR REPLACE PROCEDURE proc_credit_scoring (
    p_score_date    IN  DATE DEFAULT TRUNC(SYSDATE),
    p_segment       IN  VARCHAR2 DEFAULT 'ALL',
    p_scores_written OUT NUMBER
) IS
    v_industry_risk NUMBER;
    v_util_score    NUMBER;
    v_payment_score NUMBER;
    v_final_score   NUMBER;
    v_new_limit     NUMBER;

    CURSOR c_customers IS
        SELECT  c.customer_id,
                c.industry_sic_code,
                c.current_credit_limit,
                NVL(ch.total_lifetime_value,    0)  AS lifetime_value,
                NVL(ch.avg_days_to_pay,         60) AS avg_days_to_pay,
                NVL(ch.pct_invoices_on_time,     0) AS pct_on_time,
                NVL(ch.open_balance,             0) AS open_balance,
                RATIO_TO_REPORT(NVL(ch.open_balance, 0))
                    OVER ()                          AS utilisation_ratio
        FROM    customers       c
        LEFT JOIN customer_history ch ON ch.customer_id = c.customer_id
        WHERE   c.status IN ('ACTIVE', 'PROBATION')
          AND   (p_segment = 'ALL' OR c.segment_code = p_segment);

BEGIN
    p_scores_written := 0;

    FOR rec IN c_customers LOOP
        -- Industry risk multiplier from lookup
        BEGIN
            SELECT risk_multiplier
            INTO   v_industry_risk
            FROM   industry_risk_bands
            WHERE  sic_code_range_start <= TO_NUMBER(rec.industry_sic_code)
              AND  sic_code_range_end   >= TO_NUMBER(rec.industry_sic_code)
              AND  ROWNUM = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN v_industry_risk := 1.0;
            WHEN VALUE_ERROR   THEN v_industry_risk := 1.0;
        END;

        -- Payment behaviour score (0-40 pts)
        v_payment_score :=
            DECODE(TRUNC(rec.avg_days_to_pay / 15), 0, 40, 1, 30, 2, 20, 3, 10, 0)
            + LEAST(rec.pct_on_time / 2.5, 40);

        -- Credit utilisation score (0-30 pts): penalise > 80% usage
        v_util_score := GREATEST(0,
            30 - GREATEST(0, rec.utilisation_ratio - 0.8) * 150
        );

        -- LTV bonus (0-20 pts)
        v_final_score := LEAST(100, GREATEST(0,
            v_payment_score
            + v_util_score
            + LEAST(NVL2(rec.lifetime_value, LEAST(rec.lifetime_value / 50000 * 20, 20), 0), 20)
        ) * v_industry_risk);

        -- Derive new credit limit from score band
        v_new_limit :=
            CASE
                WHEN v_final_score >= 80 THEN GREATEST(rec.current_credit_limit, 100000)
                WHEN v_final_score >= 60 THEN LEAST(rec.current_credit_limit * 1.10, 75000)
                WHEN v_final_score >= 40 THEN LEAST(rec.current_credit_limit,        50000)
                ELSE                          LEAST(rec.current_credit_limit * 0.75, 25000)
            END;

        -- Upsert score record
        MERGE INTO customer_credit_scores tgt
        USING (SELECT rec.customer_id AS customer_id FROM DUAL) src
            ON (tgt.customer_id = src.customer_id AND tgt.score_date = p_score_date)
        WHEN MATCHED THEN
            UPDATE SET
                tgt.credit_score     = v_final_score,
                tgt.payment_score    = v_payment_score,
                tgt.utilisation_score= v_util_score,
                tgt.industry_risk    = v_industry_risk,
                tgt.recommended_limit= v_new_limit,
                tgt.last_updated     = SYSDATE
        WHEN NOT MATCHED THEN
            INSERT (customer_id, score_date, credit_score, payment_score,
                    utilisation_score, industry_risk, recommended_limit, created_at)
            VALUES (rec.customer_id, p_score_date, v_final_score, v_payment_score,
                    v_util_score, v_industry_risk, v_new_limit, SYSDATE);

        -- Apply limit changes for materially improved or degraded scores
        IF ABS(v_new_limit - rec.current_credit_limit) / NULLIF(rec.current_credit_limit, 0) > 0.10 THEN
            UPDATE customers
            SET    current_credit_limit = v_new_limit,
                   limit_last_revised   = SYSDATE,
                   credit_score_band    = CASE
                       WHEN v_final_score >= 80 THEN 'A'
                       WHEN v_final_score >= 60 THEN 'B'
                       WHEN v_final_score >= 40 THEN 'C'
                       ELSE 'D' END
            WHERE  customer_id = rec.customer_id;
        END IF;

        p_scores_written := p_scores_written + 1;
    END LOOP;

    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_scores_written := 0;
        RAISE;
END proc_credit_scoring;
