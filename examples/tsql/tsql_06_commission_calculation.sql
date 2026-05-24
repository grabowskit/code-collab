-- Computes monthly sales commissions with quota attainment accelerators,
-- overlay rep splits, manager overrides, and clawback netting for reversed deals.
CREATE PROCEDURE usp_commission_calculation
    @commission_month DATE   -- first day of the month
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @month_end DATE = EOMONTH(@commission_month);

    -- Recursive CTE: walk the territory hierarchy to propagate manager overrides
    ;WITH territory_hierarchy AS (
        SELECT
            t.rep_id,
            t.manager_rep_id,
            t.territory_id,
            t.override_pct,
            0                   AS depth
        FROM dbo.territory_assignments t
        WHERE t.manager_rep_id IS NULL

        UNION ALL

        SELECT
            c.rep_id,
            c.manager_rep_id,
            c.territory_id,
            c.override_pct,
            th.depth + 1
        FROM dbo.territory_assignments c
        JOIN territory_hierarchy       th ON th.rep_id = c.manager_rep_id
        WHERE th.depth < 5
    ),

    -- Closed-won revenue per rep in the month
    rep_revenue AS (
        SELECT
            o.owner_rep_id                    AS rep_id,
            SUM(o.arr_amount)                  AS closed_arr,
            COUNT(o.opportunity_id)            AS deal_count
        FROM dbo.opportunities o
        WHERE o.close_date  BETWEEN @commission_month AND @month_end
          AND o.stage       = 'CLOSED_WON'
          AND o.is_deleted  = 0
        GROUP BY o.owner_rep_id
    ),

    -- Quota attainment and accelerator tier
    attainment AS (
        SELECT
            r.rep_id,
            r.closed_arr,
            q.monthly_quota,
            CASE WHEN q.monthly_quota > 0
                 THEN r.closed_arr / q.monthly_quota
                 ELSE 0 END                    AS attainment_pct,
            CASE
                WHEN r.closed_arr / NULLIF(q.monthly_quota, 0) >= 1.5 THEN 0.15
                WHEN r.closed_arr / NULLIF(q.monthly_quota, 0) >= 1.0 THEN 0.10
                WHEN r.closed_arr / NULLIF(q.monthly_quota, 0) >= 0.5 THEN 0.07
                ELSE 0.05
            END                                AS commission_rate
        FROM rep_revenue r
        JOIN dbo.rep_quotas q
            ON  q.rep_id          = r.rep_id
            AND q.quota_month     = @commission_month
    )

    -- Base commissions before splits and clawbacks
    SELECT
        a.rep_id,
        a.closed_arr,
        a.attainment_pct,
        a.commission_rate,
        a.closed_arr * a.commission_rate       AS base_commission
    INTO #base_commissions
    FROM attainment a;

    -- Overlay splits: deals co-owned by multiple reps
    SELECT
        os.rep_id,
        SUM(bc.base_commission * os.split_pct) AS overlay_commission
    INTO #overlay_splits
    FROM dbo.overlay_splits   os
    JOIN #base_commissions    bc ON bc.rep_id = os.primary_rep_id
    WHERE os.split_month = @commission_month
    GROUP BY os.rep_id;

    -- Clawbacks: deals reversed in this month that paid commission previously
    SELECT
        cr.rep_id,
        SUM(cr.original_commission_paid)       AS clawback_amount
    INTO #clawback_staging
    FROM dbo.commission_clawbacks cr
    WHERE cr.reversal_date BETWEEN @commission_month AND @month_end
      AND cr.clawback_applied = 0
    GROUP BY cr.rep_id;

    -- Final commission register with UNPIVOT-style breakdown
    INSERT INTO dbo.commission_register
        (rep_id, commission_month, base_commission, overlay_commission,
         clawback_amount, manager_override_pct, net_commission, created_at)
    SELECT
        bc.rep_id,
        @commission_month,
        bc.base_commission,
        ISNULL(ov.overlay_commission, 0),
        ISNULL(cl.clawback_amount,    0),
        ISNULL(th.override_pct,       0),
        (bc.base_commission
            + ISNULL(ov.overlay_commission, 0)
            - ISNULL(cl.clawback_amount,    0))
         * (1 + ISNULL(th.override_pct, 0))   AS net_commission,
        GETDATE()
    FROM        #base_commissions bc
    LEFT JOIN   #overlay_splits   ov  ON ov.rep_id  = bc.rep_id
    LEFT JOIN   #clawback_staging cl  ON cl.rep_id  = bc.rep_id
    LEFT JOIN   territory_hierarchy th ON th.rep_id = bc.rep_id AND th.depth = 1;

    -- Mark clawbacks as applied
    UPDATE dbo.commission_clawbacks
    SET    clawback_applied  = 1,
           applied_month     = @commission_month
    WHERE  reversal_date BETWEEN @commission_month AND @month_end
      AND  clawback_applied  = 0;

    -- PERCENT_RANK distribution for performance report
    SELECT
        rep_id,
        net_commission,
        PERCENT_RANK() OVER (ORDER BY net_commission)  AS pct_rank,
        LAG(net_commission, 1) OVER (ORDER BY rep_id)  AS prior_period_commission
    FROM dbo.commission_register
    WHERE commission_month = @commission_month;
END
