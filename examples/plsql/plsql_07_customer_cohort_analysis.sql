-- Segments customers by acquisition cohort (first purchase month) and tracks
-- retention rate, average order value, and cumulative LTV over 24 months.
-- Writes results to cohort_retention_summary for the analytics dashboard.
CREATE OR REPLACE PROCEDURE proc_customer_cohort_analysis (
    p_analysis_date IN  DATE DEFAULT TRUNC(SYSDATE),
    p_rows_written  OUT NUMBER
) IS
    v_cohort_month  VARCHAR2(7);
    v_period_month  VARCHAR2(7);
    v_months_out    NUMBER;

BEGIN
    p_rows_written := 0;

    -- Delete stale cohort rows for the current analysis date
    DELETE FROM cohort_retention_summary WHERE analysis_date = p_analysis_date;

    -- Iterate over cohorts defined in the last 24 months
    FOR cohort IN (
        SELECT DISTINCT TO_CHAR(first_order_date, 'YYYY-MM') AS cohort_month,
                        TRUNC(first_order_date, 'MM')         AS cohort_start
        FROM   customer_first_orders
        WHERE  first_order_date >= ADD_MONTHS(p_analysis_date, -24)
          AND  first_order_date <  p_analysis_date
        ORDER BY cohort_start
    ) LOOP
        -- For each subsequent month from cohort month to analysis date
        FOR period IN (
            SELECT TRUNC(ADD_MONTHS(cohort.cohort_start, lvl - 1), 'MM') AS period_start,
                   lvl - 1                                                 AS months_out
            FROM   (SELECT LEVEL AS lvl FROM DUAL
                    CONNECT BY LEVEL <= MONTHS_BETWEEN(
                        TRUNC(p_analysis_date, 'MM'),
                        cohort.cohort_start
                    ) + 1)
        ) LOOP
            INSERT INTO cohort_retention_summary (
                analysis_date, cohort_month, period_month, months_out,
                cohort_size,
                retained_customers,
                retention_rate,
                avg_order_value,
                cumulative_ltv,
                orders_count
            )
            SELECT
                p_analysis_date,
                cohort.cohort_month,
                TO_CHAR(period.period_start, 'YYYY-MM'),
                period.months_out,
                -- Cohort size (customers who first purchased in cohort month)
                (SELECT COUNT(DISTINCT cfo.customer_id)
                 FROM   customer_first_orders cfo
                 WHERE  TO_CHAR(cfo.first_order_date, 'YYYY-MM') = cohort.cohort_month),
                -- Retained: placed an order in this period month
                COUNT(DISTINCT o.customer_id),
                -- Retention rate
                ROUND(COUNT(DISTINCT o.customer_id) /
                    NULLIF((SELECT COUNT(DISTINCT cfo.customer_id)
                            FROM   customer_first_orders cfo
                            WHERE  TO_CHAR(cfo.first_order_date, 'YYYY-MM') = cohort.cohort_month), 0)
                    * 100, 2),
                -- Average order value in this period
                ROUND(NVL(AVG(o.order_amount), 0), 2),
                -- Cumulative LTV: all revenue from cohort from cohort start to period end
                (SELECT ROUND(NVL(SUM(o2.order_amount), 0), 2)
                 FROM   orders o2
                 JOIN   customer_first_orders cfo2 ON cfo2.customer_id = o2.customer_id
                 WHERE  TO_CHAR(cfo2.first_order_date, 'YYYY-MM') = cohort.cohort_month
                   AND  TRUNC(o2.order_date, 'MM') <= period.period_start),
                COUNT(o.order_id)
            FROM   orders               o
            JOIN   customer_first_orders cfo ON cfo.customer_id = o.customer_id
            WHERE  TO_CHAR(cfo.first_order_date, 'YYYY-MM') = cohort.cohort_month
              AND  TRUNC(o.order_date, 'MM')                = period.period_start
            HAVING COUNT(o.order_id) > 0;

            p_rows_written := p_rows_written + SQL%ROWCOUNT;
        END LOOP;
    END LOOP;

    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_rows_written := 0;
        RAISE;
END proc_customer_cohort_analysis;
