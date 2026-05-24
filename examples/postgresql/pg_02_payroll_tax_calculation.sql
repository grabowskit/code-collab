-- Computes federal and state payroll tax withholding for a pay period using a
-- recursive CTE to accumulate tax across progressive brackets, then writes
-- the results to the payroll_register table.
CREATE OR REPLACE PROCEDURE proc_payroll_tax_calculation(
    p_pay_period_start  DATE,
    p_pay_period_end    DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_written  INT;
BEGIN
    -- Remove any existing register rows for this period (idempotent re-run)
    DELETE FROM payroll_register
    WHERE  pay_period_start = p_pay_period_start
      AND  pay_period_end   = p_pay_period_end;

    -- Compute gross pay, progressive tax, and net pay in one query chain
    WITH gross_pay AS (
        SELECT
            e.employee_id,
            e.state_code,
            e.filing_status,
            SUM(ts.regular_hours)  * e.hourly_rate                          AS regular_pay,
            GREATEST(SUM(ts.total_hours) - 80, 0) * e.hourly_rate * 1.5    AS overtime_pay,
            SUM(ts.regular_hours) * e.hourly_rate
                + GREATEST(SUM(ts.total_hours) - 80, 0) * e.hourly_rate * 1.5 AS gross_pay
        FROM   employees  e
        JOIN   timesheets ts ON ts.employee_id = e.employee_id
        WHERE  ts.work_date BETWEEN p_pay_period_start AND p_pay_period_end
          AND  e.status         = 'ACTIVE'
        GROUP BY e.employee_id, e.state_code, e.filing_status, e.hourly_rate
    ),

    -- Recursive bracket accumulation: each step adds tax for one bracket
    federal_tax_calc AS (
        SELECT
            gp.employee_id,
            gp.gross_pay,
            gp.filing_status,
            tb.bracket_order,
            tb.rate,
            tb.bracket_min,
            tb.bracket_max,
            -- Tax owed within this bracket
            LEAST(gp.gross_pay, tb.bracket_max) - tb.bracket_min AS taxable_in_bracket
        FROM gross_pay gp
        JOIN federal_tax_brackets tb
             ON  gp.gross_pay         > tb.bracket_min
             AND gp.filing_status     = tb.filing_status
             AND tb.tax_year          = EXTRACT(YEAR FROM p_pay_period_end)
    ),

    federal_tax AS (
        SELECT
            employee_id,
            gross_pay,
            filing_status,
            SUM(GREATEST(taxable_in_bracket, 0) * rate)  AS federal_tax_withheld
        FROM federal_tax_calc
        GROUP BY employee_id, gross_pay, filing_status
    ),

    -- State tax: flat rate lookup
    state_tax AS (
        SELECT
            ft.employee_id,
            ft.gross_pay,
            ft.federal_tax_withheld,
            ft.gross_pay * COALESCE(str.flat_rate, 0)   AS state_tax_withheld
        FROM   federal_tax             ft
        JOIN   gross_pay               gp  ON gp.employee_id = ft.employee_id
        LEFT JOIN state_tax_rates      str ON str.state_code  = gp.state_code
                                          AND str.tax_year    = EXTRACT(YEAR FROM p_pay_period_end)
    ),

    -- Benefits deductions for the pay period
    deductions AS (
        SELECT
            bd.employee_id,
            SUM(bd.amount) FILTER (WHERE bd.deduction_type = 'HEALTH')      AS health_deduction,
            SUM(bd.amount) FILTER (WHERE bd.deduction_type = '401K')        AS retirement_deduction,
            SUM(bd.amount) FILTER (WHERE bd.deduction_type IN ('HSA','FSA')) AS hsa_fsa_deduction
        FROM   benefit_deductions bd
        WHERE  bd.effective_date <= p_pay_period_end
          AND  (bd.end_date IS NULL OR bd.end_date >= p_pay_period_start)
        GROUP BY bd.employee_id
    )

    INSERT INTO payroll_register (
        employee_id, pay_period_start, pay_period_end,
        gross_pay, federal_tax, state_tax,
        health_deduction, retirement_deduction, hsa_fsa_deduction,
        fica_employee, net_pay, created_at
    )
    SELECT
        st.employee_id,
        p_pay_period_start,
        p_pay_period_end,
        st.gross_pay,
        ROUND(st.federal_tax_withheld,  2),
        ROUND(st.state_tax_withheld,    2),
        ROUND(COALESCE(d.health_deduction,      0), 2),
        ROUND(COALESCE(d.retirement_deduction,  0), 2),
        ROUND(COALESCE(d.hsa_fsa_deduction,     0), 2),
        -- FICA: 6.2% SS (cap $160,200 YTD) + 1.45% Medicare
        ROUND(LEAST(st.gross_pay, 160200) * 0.062 + st.gross_pay * 0.0145, 2),
        ROUND(
            st.gross_pay
            - st.federal_tax_withheld
            - st.state_tax_withheld
            - COALESCE(d.health_deduction,     0)
            - COALESCE(d.retirement_deduction, 0)
            - COALESCE(d.hsa_fsa_deduction,    0)
            - (LEAST(st.gross_pay, 160200) * 0.062 + st.gross_pay * 0.0145)
        , 2)                                              AS net_pay,
        NOW()
    FROM   state_tax   st
    LEFT JOIN deductions d ON d.employee_id = st.employee_id;

    GET DIAGNOSTICS v_rows_written = ROW_COUNT;
    RAISE NOTICE 'Payroll register written for % employees (% to %).', v_rows_written, p_pay_period_start, p_pay_period_end;

END;
$$;
