-- Computes bi-weekly payroll for all active US employees:
-- regular pay, overtime (FLSA 1.5x after 80h), federal/state tax brackets,
-- benefits deductions, and net pay. Writes results to payroll_register.
CREATE PROCEDURE usp_calculate_payroll
    @pay_period_end DATE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @pay_period_start DATE = DATEADD(day, -13, @pay_period_end);
    DECLARE @fiscal_table     NVARCHAR(128);
    DECLARE @sql              NVARCHAR(MAX);

    -- Route to the correct fiscal-year tax table dynamically
    SET @fiscal_table = 'dbo.tax_brackets_' + CAST(YEAR(@pay_period_end) AS VARCHAR);

    -- Gross earnings per employee
    SELECT
        ts.employee_id,
        SUM(CASE WHEN ts.hours_worked <= 80 THEN ts.hours_worked ELSE 80 END)
            * e.hourly_rate                                              AS regular_pay,
        CASE WHEN SUM(ts.hours_worked) > 80
             THEN (SUM(ts.hours_worked) - 80) * e.hourly_rate * 1.5
             ELSE 0 END                                                  AS overtime_pay,
        e.hourly_rate
    INTO #gross_earnings
    FROM dbo.timesheets     ts
    JOIN dbo.employees      e  ON e.employee_id = ts.employee_id
    WHERE ts.work_date BETWEEN @pay_period_start AND @pay_period_end
      AND e.employment_status = 'ACTIVE'
      AND e.country_code      = 'US'
    GROUP BY ts.employee_id, e.hourly_rate;

    -- Apply federal tax brackets (read from dynamic year table)
    SET @sql = N'
    SELECT
        ge.employee_id,
        ge.regular_pay + ge.overtime_pay                        AS gross_pay,
        SUM(
            tb.rate * (
                LEAST(ge.regular_pay + ge.overtime_pay, tb.bracket_max)
              - tb.bracket_min
            )
        )                                                        AS federal_tax
    INTO #tax_withholding
    FROM #gross_earnings ge
    CROSS APPLY (
        SELECT bracket_min, bracket_max, rate
        FROM ' + @fiscal_table + N'
        WHERE ge.regular_pay + ge.overtime_pay > bracket_min
          AND filing_status = ''SINGLE''
    ) tb
    GROUP BY ge.employee_id, ge.regular_pay, ge.overtime_pay;';

    EXEC sp_executesql @sql;

    -- Aggregate benefit deductions per employee
    SELECT
        bd.employee_id,
        SUM(CASE WHEN bd.deduction_type = 'HEALTH'   THEN bd.amount ELSE 0 END) AS health_deduction,
        SUM(CASE WHEN bd.deduction_type = '401K'     THEN bd.amount ELSE 0 END) AS retirement_deduction,
        SUM(CASE WHEN bd.deduction_type = 'DENTAL'   THEN bd.amount ELSE 0 END) AS dental_deduction
    INTO #deductions
    FROM dbo.benefit_deductions bd
    WHERE bd.effective_date <= @pay_period_end
      AND (bd.end_date IS NULL OR bd.end_date >= @pay_period_start)
    GROUP BY bd.employee_id;

    -- Write final payroll register
    INSERT INTO dbo.payroll_register
        (employee_id, pay_period_start, pay_period_end,
         gross_pay, federal_tax, health_deduction, retirement_deduction,
         dental_deduction, net_pay, created_at)
    SELECT
        tw.employee_id,
        @pay_period_start,
        @pay_period_end,
        tw.gross_pay,
        tw.federal_tax,
        ISNULL(d.health_deduction,      0),
        ISNULL(d.retirement_deduction,  0),
        ISNULL(d.dental_deduction,      0),
        tw.gross_pay
            - tw.federal_tax
            - ISNULL(d.health_deduction,     0)
            - ISNULL(d.retirement_deduction, 0)
            - ISNULL(d.dental_deduction,     0)            AS net_pay,
        GETDATE()
    FROM       #tax_withholding tw
    LEFT JOIN  #deductions       d  ON d.employee_id = tw.employee_id;

    -- Cursor to update each employee's YTD totals
    DECLARE @emp_id   INT;
    DECLARE @net_pay  DECIMAL(12,2);

    DECLARE cur_ytd CURSOR FOR
        SELECT employee_id, net_pay FROM #tax_withholding;

    OPEN cur_ytd;
    FETCH NEXT FROM cur_ytd INTO @emp_id, @net_pay;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        UPDATE dbo.employee_ytd_totals
        SET    ytd_net_pay  = ytd_net_pay + @net_pay,
               last_updated = GETDATE()
        WHERE  employee_id  = @emp_id
          AND  tax_year     = YEAR(@pay_period_end);

        FETCH NEXT FROM cur_ytd INTO @emp_id, @net_pay;
    END

    CLOSE cur_ytd;
    DEALLOCATE cur_ytd;
END
