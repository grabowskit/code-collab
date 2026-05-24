-- Calculates tiered sales commissions with quota accelerators, overlay rep
-- splits, and clawback netting for reversed deals. Uses a recursive CTE to
-- walk the territory hierarchy for manager override percentages.
CREATE OR REPLACE PROCEDURE proc_commission_payout(
    p_commission_month  DATE    -- must be the first day of the month
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_month_end     DATE := (p_commission_month + INTERVAL '1 month - 1 day')::DATE;
    v_rows          INT;
BEGIN
    -- Recursive territory hierarchy for manager overrides
    CREATE TEMP TABLE tmp_territory_hierarchy AS
    WITH RECURSIVE territory_tree AS (
        SELECT rep_id, manager_rep_id, override_pct, 0 AS depth
        FROM   territory_assignments
        WHERE  manager_rep_id IS NULL

        UNION ALL

        SELECT  t.rep_id, t.manager_rep_id, t.override_pct, tt.depth + 1
        FROM    territory_assignments t
        JOIN    territory_tree tt ON tt.rep_id = t.manager_rep_id
        WHERE   tt.depth < 4
    )
    SELECT * FROM territory_tree;

    -- Base commissions from closed-won deals
    CREATE TEMP TABLE tmp_base_commissions AS
    WITH rep_revenue AS (
        SELECT
            o.owner_rep_id                              AS rep_id,
            SUM(o.arr_amount)                           AS closed_arr,
            COUNT(*)                                    AS deal_count
        FROM   opportunities o
        WHERE  o.close_date   BETWEEN p_commission_month AND v_month_end
          AND  o.stage        = 'CLOSED_WON'
          AND  o.is_deleted   = FALSE
        GROUP BY o.owner_rep_id
    ),
    quota_attainment AS (
        SELECT
            r.rep_id,
            r.closed_arr,
            q.monthly_quota,
            r.closed_arr / NULLIF(q.monthly_quota, 0)          AS attainment_pct,
            CASE
                WHEN r.closed_arr / NULLIF(q.monthly_quota, 0) >= 1.5 THEN 0.15
                WHEN r.closed_arr / NULLIF(q.monthly_quota, 0) >= 1.0 THEN 0.10
                WHEN r.closed_arr / NULLIF(q.monthly_quota, 0) >= 0.5 THEN 0.07
                ELSE 0.05
            END                                                 AS commission_rate
        FROM rep_revenue r
        JOIN rep_quotas  q ON q.rep_id = r.rep_id AND q.quota_month = p_commission_month
    )
    SELECT
        rep_id,
        closed_arr,
        attainment_pct,
        commission_rate,
        ROUND((closed_arr * commission_rate)::NUMERIC, 2) AS base_commission
    FROM quota_attainment;

    -- Overlay splits from co-owned deals
    CREATE TEMP TABLE tmp_overlay_splits AS
    SELECT
        os.rep_id,
        ROUND(SUM(bc.base_commission * os.split_pct)::NUMERIC, 2) AS overlay_commission
    FROM   overlay_splits        os
    JOIN   tmp_base_commissions  bc ON bc.rep_id = os.primary_rep_id
    WHERE  os.split_month = p_commission_month
    GROUP BY os.rep_id;

    -- Clawbacks for deals reversed this month
    CREATE TEMP TABLE tmp_clawbacks AS
    SELECT
        cc.rep_id,
        ROUND(SUM(cc.original_commission_paid)::NUMERIC, 2) AS clawback_amount
    FROM   commission_clawbacks cc
    WHERE  cc.reversal_date BETWEEN p_commission_month AND v_month_end
      AND  cc.clawback_applied = FALSE
    GROUP BY cc.rep_id;

    -- Final payout register
    INSERT INTO commission_register (
        rep_id, commission_month,
        base_commission, overlay_commission, clawback_amount,
        manager_override_pct, net_commission, attainment_pct,
        pct_rank, created_at
    )
    SELECT
        bc.rep_id,
        p_commission_month,
        bc.base_commission,
        COALESCE(ov.overlay_commission, 0),
        COALESCE(cl.clawback_amount,    0),
        COALESCE(th.override_pct,       0),
        ROUND((
            bc.base_commission
            + COALESCE(ov.overlay_commission, 0)
            - COALESCE(cl.clawback_amount,    0)
        ) * (1 + COALESCE(th.override_pct, 0))::NUMERIC, 2),
        bc.attainment_pct,
        PERCENT_RANK() OVER (ORDER BY bc.base_commission),
        NOW()
    FROM       tmp_base_commissions bc
    LEFT JOIN  tmp_overlay_splits   ov ON ov.rep_id = bc.rep_id
    LEFT JOIN  tmp_clawbacks        cl ON cl.rep_id = bc.rep_id
    LEFT JOIN  tmp_territory_hierarchy th ON th.rep_id = bc.rep_id AND th.depth = 1
    ON CONFLICT (rep_id, commission_month)
    DO UPDATE SET
        net_commission = EXCLUDED.net_commission,
        pct_rank       = EXCLUDED.pct_rank;

    -- Mark clawbacks as applied
    UPDATE commission_clawbacks
    SET    clawback_applied = TRUE,
           applied_month    = p_commission_month
    WHERE  reversal_date BETWEEN p_commission_month AND v_month_end
      AND  clawback_applied = FALSE;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE NOTICE 'Commission payout: % clawbacks applied for %.', v_rows, p_commission_month;

    DROP TABLE tmp_territory_hierarchy, tmp_base_commissions, tmp_overlay_splits, tmp_clawbacks;

END;
$$;
