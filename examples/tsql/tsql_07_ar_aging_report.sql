-- Buckets open accounts receivable into aging brackets (Current, 1-30, 31-60,
-- 61-90, 90+ days past due) and writes a snapshot for the finance dashboard.
CREATE PROCEDURE usp_ar_aging_report
    @as_of_date DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @as_of_date = ISNULL(@as_of_date, CAST(GETDATE() AS DATE));

    -- Open invoice balances with days outstanding
    SELECT
        i.invoice_id,
        i.customer_id,
        i.invoice_date,
        i.due_date,
        i.invoice_amount,
        COALESCE(SUM(p.payment_amount), 0)                          AS paid_amount,
        i.invoice_amount - COALESCE(SUM(p.payment_amount), 0)       AS balance_due,
        DATEDIFF(day, i.due_date, @as_of_date)                      AS days_past_due
    INTO #open_invoices
    FROM dbo.invoices i
    LEFT JOIN dbo.payments p
        ON  p.invoice_id  = i.invoice_id
        AND p.payment_date <= @as_of_date
    WHERE i.invoice_date <= @as_of_date
      AND i.status NOT IN ('VOID', 'WRITTEN_OFF')
    GROUP BY i.invoice_id, i.customer_id, i.invoice_date,
             i.due_date, i.invoice_amount
    HAVING i.invoice_amount - COALESCE(SUM(p.payment_amount), 0) > 0.01;

    -- Pivot aging buckets per customer
    SELECT
        customer_id,
        SUM(CASE WHEN days_past_due <= 0                          THEN balance_due ELSE 0 END) AS current_bucket,
        SUM(CASE WHEN days_past_due BETWEEN  1 AND  30            THEN balance_due ELSE 0 END) AS bucket_1_30,
        SUM(CASE WHEN days_past_due BETWEEN 31 AND  60            THEN balance_due ELSE 0 END) AS bucket_31_60,
        SUM(CASE WHEN days_past_due BETWEEN 61 AND  90            THEN balance_due ELSE 0 END) AS bucket_61_90,
        SUM(CASE WHEN days_past_due > 90                          THEN balance_due ELSE 0 END) AS bucket_90_plus,
        SUM(balance_due)                                                                        AS total_outstanding,
        COUNT(invoice_id)                                                                       AS open_invoice_count,
        MAX(days_past_due)                                                                      AS max_days_past_due
    INTO #aging_buckets
    FROM #open_invoices
    GROUP BY customer_id;

    -- Attach customer metadata and credit limit utilisation
    INSERT INTO dbo.ar_aging_snapshots
        (as_of_date, customer_id, customer_name, credit_limit,
         current_bucket, bucket_1_30, bucket_31_60, bucket_61_90, bucket_90_plus,
         total_outstanding, credit_utilisation_pct,
         open_invoice_count, max_days_past_due,
         risk_tier, snapshot_created_at)
    SELECT
        @as_of_date,
        ab.customer_id,
        c.customer_name,
        c.credit_limit,
        ab.current_bucket,
        ab.bucket_1_30,
        ab.bucket_31_60,
        ab.bucket_61_90,
        ab.bucket_90_plus,
        ab.total_outstanding,
        CASE WHEN c.credit_limit > 0
             THEN ROUND(ab.total_outstanding / c.credit_limit * 100, 2)
             ELSE NULL END                                              AS credit_utilisation_pct,
        ab.open_invoice_count,
        ab.max_days_past_due,
        CASE
            WHEN ab.bucket_90_plus > 0           THEN 'HIGH'
            WHEN ab.bucket_61_90  > 0            THEN 'MEDIUM'
            WHEN ab.max_days_past_due > 30       THEN 'LOW'
            ELSE 'CURRENT'
        END                                                             AS risk_tier,
        GETDATE()
    FROM       #aging_buckets  ab
    JOIN       dbo.customers   c ON c.customer_id = ab.customer_id;

    -- Flag accounts that crossed into high-risk this period
    UPDATE dbo.customers
    SET    credit_hold    = 1,
           credit_hold_at = GETDATE()
    FROM   dbo.customers c
    JOIN   dbo.ar_aging_snapshots s
        ON  s.customer_id = c.customer_id
        AND s.as_of_date  = @as_of_date
    WHERE  s.risk_tier  = 'HIGH'
      AND  c.credit_hold = 0;
END
