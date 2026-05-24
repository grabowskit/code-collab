-- Closes a GL accounting period: validates balanced entries, rolls retained
-- earnings, locks the period, and produces a trial balance snapshot.
CREATE PROCEDURE usp_month_end_financial_close
    @fiscal_year    INT,
    @fiscal_period  INT   -- 1-12
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @period_start  DATE = DATEFROMPARTS(@fiscal_year, @fiscal_period, 1);
    DECLARE @period_end    DATE = EOMONTH(@period_start);
    DECLARE @out_of_balance DECIMAL(18,2);

    -- Guard: period must not already be closed
    IF EXISTS (
        SELECT 1 FROM dbo.gl_periods
        WHERE fiscal_year = @fiscal_year AND fiscal_period = @fiscal_period
          AND status = 'CLOSED'
    )
    BEGIN
        RAISERROR('Period %d/%d is already closed.', 16, 1, @fiscal_year, @fiscal_period);
        RETURN;
    END

    -- Verify debits = credits for the period
    SELECT @out_of_balance = ABS(
        SUM(CASE WHEN entry_type = 'DEBIT'  THEN amount ELSE 0 END)
      - SUM(CASE WHEN entry_type = 'CREDIT' THEN amount ELSE 0 END)
    )
    FROM dbo.gl_journal_entries
    WHERE entry_date BETWEEN @period_start AND @period_end
      AND status = 'POSTED';

    IF @out_of_balance > 0.01
    BEGIN
        RAISERROR('GL is out of balance by $%.2f. Period close aborted.', 16, 1, @out_of_balance);
        RETURN;
    END

    BEGIN TRANSACTION;

    -- Trial balance snapshot with subtotals by account class
    SELECT
        a.account_class,
        a.account_code,
        a.account_name,
        SUM(CASE WHEN je.entry_type = 'DEBIT'  THEN je.amount ELSE 0 END) AS total_debits,
        SUM(CASE WHEN je.entry_type = 'CREDIT' THEN je.amount ELSE 0 END) AS total_credits,
        SUM(CASE WHEN je.entry_type = 'DEBIT'  THEN je.amount ELSE -je.amount END) AS net_balance
    INTO #trial_balance
    FROM dbo.gl_journal_entries je
    JOIN dbo.chart_of_accounts  a  ON a.account_code = je.account_code
    WHERE je.entry_date BETWEEN @period_start AND @period_end
      AND je.status = 'POSTED'
    GROUP BY a.account_class, a.account_code, a.account_name
    WITH ROLLUP;

    -- Persist trial balance
    INSERT INTO dbo.trial_balance_snapshots
        (fiscal_year, fiscal_period, account_class, account_code, account_name,
         total_debits, total_credits, net_balance, snapshot_at)
    SELECT
        @fiscal_year, @fiscal_period,
        account_class, account_code, account_name,
        total_debits, total_credits, net_balance,
        SYSDATETIME()
    FROM #trial_balance
    WHERE account_code IS NOT NULL;

    -- Roll net income into retained earnings account (code 3900)
    DECLARE @net_income DECIMAL(18,2);
    SELECT @net_income = SUM(net_balance)
    FROM #trial_balance
    WHERE account_class IN ('REVENUE', 'EXPENSE')
      AND account_code IS NOT NULL;

    IF @net_income <> 0
    BEGIN
        INSERT INTO dbo.gl_journal_entries
            (entry_date, account_code, entry_type, amount,
             description, status, created_at)
        VALUES
            (@period_end, '3900',
             CASE WHEN @net_income > 0 THEN 'CREDIT' ELSE 'DEBIT' END,
             ABS(@net_income),
             'Automated period close — retained earnings roll',
             'POSTED', SYSDATETIME()),
            (@period_end,
             CASE WHEN @net_income > 0 THEN '4000' ELSE '3900' END,
             CASE WHEN @net_income > 0 THEN 'DEBIT'  ELSE 'CREDIT' END,
             ABS(@net_income),
             'Automated period close — income summary clear',
             'POSTED', SYSDATETIME());
    END

    -- Lock the period
    UPDATE dbo.gl_periods
    SET    status     = 'CLOSED',
           closed_by  = SYSTEM_USER,
           closed_at  = SYSDATETIME()
    WHERE  fiscal_year   = @fiscal_year
      AND  fiscal_period = @fiscal_period;

    -- Freeze all unposted entries in the period
    UPDATE dbo.gl_journal_entries
    SET    status = 'VOID'
    WHERE  entry_date BETWEEN @period_start AND @period_end
      AND  status    = 'DRAFT';

    COMMIT TRANSACTION;

    PRINT 'Period ' + CAST(@fiscal_year AS VARCHAR) + '/' + CAST(@fiscal_period AS VARCHAR) + ' closed successfully.';
END
