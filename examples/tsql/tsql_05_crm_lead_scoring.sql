-- Scores inbound CRM leads using weighted activity signals (email opens,
-- site visits, demo requests) plus firmographic overlays. Updates lead_score
-- and moves hot leads (score >= 75) into the sales_ready_queue.
CREATE PROCEDURE usp_crm_lead_scoring
    @score_date DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @score_date = ISNULL(@score_date, CAST(GETDATE() AS DATE));

    -- Weighted activity signals in the trailing 30 days
    SELECT
        l.lead_id,
        l.company_id,
        l.assigned_rep_id,
        SUM(signal.weighted_score)                                  AS activity_score,
        DENSE_RANK() OVER (ORDER BY SUM(signal.weighted_score) DESC) AS activity_rank
    INTO #activity_scores
    FROM dbo.leads l
    CROSS APPLY (
        VALUES
            ('EMAIL_OPEN',    (SELECT COUNT(*) * 2  FROM dbo.email_events   e WHERE e.lead_id = l.lead_id AND e.event_type = 'OPEN'    AND e.event_date >= DATEADD(day, -30, @score_date)), 2),
            ('EMAIL_CLICK',   (SELECT COUNT(*) * 5  FROM dbo.email_events   e WHERE e.lead_id = l.lead_id AND e.event_type = 'CLICK'   AND e.event_date >= DATEADD(day, -30, @score_date)), 5),
            ('SITE_VISIT',    (SELECT COUNT(*) * 3  FROM dbo.web_sessions   w WHERE w.lead_id = l.lead_id                              AND w.session_date >= DATEADD(day, -30, @score_date)), 3),
            ('DEMO_REQUEST',  (SELECT COUNT(*) * 20 FROM dbo.demo_requests  d WHERE d.lead_id = l.lead_id                              AND d.request_date >= DATEADD(day, -30, @score_date)), 20),
            ('PRICING_PAGE',  (SELECT COUNT(*) * 10 FROM dbo.page_views     p WHERE p.lead_id = l.lead_id AND p.page_key = 'PRICING'  AND p.view_date    >= DATEADD(day, -30, @score_date)), 10)
    ) AS signal (signal_type, raw_count, weight)
    WHERE l.status NOT IN ('CONVERTED', 'DISQUALIFIED')
    GROUP BY l.lead_id, l.company_id, l.assigned_rep_id;

    -- Firmographic overlay: ICP fit bonus
    SELECT
        a.activity_score,
        a.lead_id,
        a.assigned_rep_id,
        a.activity_score
            + ISNULL(f.employee_count_score,  0)
            + ISNULL(f.revenue_band_score,    0)
            + ISNULL(f.industry_fit_score,    0)  AS total_score,
        CHECKSUM(
            a.activity_score,
            f.employee_count_score,
            f.industry_fit_score
        )                                          AS score_hash
    INTO #final_scores
    FROM #activity_scores a
    LEFT JOIN (
        SELECT
            c.company_id,
            CASE WHEN c.employee_count BETWEEN 50  AND 500  THEN 10
                 WHEN c.employee_count BETWEEN 500 AND 5000 THEN 15
                 WHEN c.employee_count > 5000               THEN 20
                 ELSE 0 END                        AS employee_count_score,
            CASE WHEN c.annual_revenue_usd >= 10000000 THEN 10
                 WHEN c.annual_revenue_usd >= 1000000  THEN 5
                 ELSE 0 END                        AS revenue_band_score,
            ISNULL(ig.fit_score, 0)                AS industry_fit_score
        FROM  dbo.companies          c
        LEFT JOIN dbo.industry_grades ig ON ig.sic_code = c.sic_code
    ) f ON f.company_id = a.company_id;

    -- String-aggregate signals for audit trail using FOR XML PATH
    SELECT
        ae.lead_id,
        STUFF((
            SELECT ', ' + e.event_type + ':' + CAST(COUNT(*) AS VARCHAR)
            FROM   dbo.email_events e
            WHERE  e.lead_id  = ae.lead_id
              AND  e.event_date >= DATEADD(day, -30, @score_date)
            GROUP BY e.event_type
            FOR XML PATH(''), TYPE
        ).value('.', 'NVARCHAR(MAX)'), 1, 2, '')   AS signal_summary
    INTO #signal_audit
    FROM #activity_scores ae;

    -- Write scores and promote hot leads
    UPDATE l
    SET    l.lead_score     = fs.total_score,
           l.score_hash     = fs.score_hash,
           l.last_scored_at = GETDATE()
    FROM   dbo.leads       l
    JOIN   #final_scores   fs ON fs.lead_id = l.lead_id;

    INSERT INTO dbo.sales_ready_queue
        (lead_id, assigned_rep_id, score, queued_at, signal_summary)
    SELECT
        fs.lead_id,
        fs.assigned_rep_id,
        fs.total_score,
        GETDATE(),
        sa.signal_summary
    FROM  #final_scores fs
    JOIN  #signal_audit sa ON sa.lead_id = fs.lead_id
    WHERE fs.total_score >= 75
      AND NOT EXISTS (
            SELECT 1 FROM dbo.sales_ready_queue q
            WHERE  q.lead_id = fs.lead_id
              AND  q.status  = 'OPEN'
          );
END
