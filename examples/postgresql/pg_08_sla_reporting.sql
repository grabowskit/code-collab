-- Produces SLA compliance reporting: breach rates, p50/p95 resolution times,
-- consecutive breach detection per account, and MTTR by service tier.
-- Writes to sla_compliance_report; safe to re-run for a given report date.
CREATE OR REPLACE PROCEDURE proc_sla_reporting(
    p_report_date   DATE DEFAULT CURRENT_DATE,
    p_lookback_days INT  DEFAULT 30
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_period_start  DATE := p_report_date - p_lookback_days;
    v_rows          INT;
BEGIN
    DELETE FROM sla_compliance_report
    WHERE  report_date   = p_report_date
      AND  lookback_days = p_lookback_days;

    WITH
    -- Base ticket set with resolution time and breach flag
    ticket_metrics AS (
        SELECT
            t.ticket_id,
            t.account_id,
            t.priority,
            t.service_tier,
            t.created_at,
            t.resolved_at,
            t.first_response_at,
            -- Resolution duration in minutes (NULL if still open)
            EXTRACT(EPOCH FROM (t.resolved_at - t.created_at)) / 60        AS resolution_minutes,
            -- Response time in minutes
            EXTRACT(EPOCH FROM (t.first_response_at - t.created_at)) / 60  AS response_minutes,
            -- SLA thresholds from policy table
            sp.response_sla_minutes,
            sp.resolution_sla_minutes,
            -- Breach flags
            CASE WHEN t.first_response_at IS NULL
                   OR EXTRACT(EPOCH FROM (t.first_response_at - t.created_at)) / 60
                      > sp.response_sla_minutes
                 THEN TRUE ELSE FALSE END                                    AS response_breached,
            CASE WHEN t.resolved_at IS NULL
                   OR EXTRACT(EPOCH FROM (t.resolved_at - t.created_at)) / 60
                      > sp.resolution_sla_minutes
                 THEN TRUE ELSE FALSE END                                    AS resolution_breached
        FROM   tickets      t
        JOIN   sla_policies sp ON sp.priority     = t.priority
                              AND sp.service_tier = t.service_tier
        WHERE  t.created_at::date BETWEEN v_period_start AND p_report_date
    ),

    -- Consecutive breach detection per account using LAG
    consecutive_breaches AS (
        SELECT
            account_id,
            ticket_id,
            resolution_breached,
            LAG(resolution_breached, 1) OVER (PARTITION BY account_id ORDER BY created_at) AS prev_breached,
            LAG(resolution_breached, 2) OVER (PARTITION BY account_id ORDER BY created_at) AS prev2_breached
        FROM ticket_metrics
    ),

    accounts_with_consecutive AS (
        SELECT DISTINCT account_id
        FROM consecutive_breaches
        WHERE resolution_breached = TRUE
          AND prev_breached        = TRUE
          AND prev2_breached       = TRUE
    ),

    -- Aggregate by service tier and priority
    tier_summary AS (
        SELECT
            service_tier,
            priority,
            COUNT(*)                                                         AS total_tickets,
            COUNT(*) FILTER (WHERE response_breached = FALSE)               AS response_met,
            COUNT(*) FILTER (WHERE resolution_breached = FALSE
                               AND resolved_at IS NOT NULL)                 AS resolution_met,
            COUNT(*) FILTER (WHERE resolution_breached = TRUE)              AS resolution_breached_count,
            ROUND(
                COUNT(*) FILTER (WHERE resolution_breached = FALSE
                                   AND resolved_at IS NOT NULL)::NUMERIC
                / NULLIF(COUNT(*) FILTER (WHERE resolved_at IS NOT NULL), 0) * 100
            , 2)                                                             AS sla_compliance_pct,
            ROUND(percentile_disc(0.50) WITHIN GROUP
                (ORDER BY resolution_minutes) FILTER (WHERE resolved_at IS NOT NULL)::NUMERIC
            , 1)                                                             AS p50_resolution_min,
            ROUND(percentile_disc(0.95) WITHIN GROUP
                (ORDER BY resolution_minutes) FILTER (WHERE resolved_at IS NOT NULL)::NUMERIC
            , 1)                                                             AS p95_resolution_min,
            ROUND(AVG(resolution_minutes) FILTER (WHERE resolved_at IS NOT NULL)::NUMERIC, 1) AS mttr_minutes,
            ROUND(AVG(response_minutes)   FILTER (WHERE first_response_at IS NOT NULL)::NUMERIC, 1) AS avg_response_minutes
        FROM ticket_metrics
        GROUP BY service_tier, priority
    )

    INSERT INTO sla_compliance_report (
        report_date, lookback_days, period_start,
        service_tier, priority,
        total_tickets, response_met, resolution_met,
        resolution_breached_count, sla_compliance_pct,
        p50_resolution_min, p95_resolution_min,
        mttr_minutes, avg_response_minutes, created_at
    )
    SELECT
        p_report_date, p_lookback_days, v_period_start,
        service_tier, priority,
        total_tickets, response_met, resolution_met,
        resolution_breached_count, sla_compliance_pct,
        p50_resolution_min, p95_resolution_min,
        mttr_minutes, avg_response_minutes, NOW()
    FROM tier_summary;

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    -- Flag accounts with 3+ consecutive breaches for proactive outreach
    INSERT INTO account_risk_flags (account_id, flag_type, flagged_on, details)
    SELECT account_id, 'CONSECUTIVE_SLA_BREACHES', p_report_date,
           'Three or more consecutive resolution SLA breaches in the reporting period'
    FROM   accounts_with_consecutive
    ON CONFLICT (account_id, flag_type, flagged_on) DO NOTHING;

    RAISE NOTICE 'SLA compliance report written: % tier-priority rows for % day window ending %.', v_rows, p_lookback_days, p_report_date;

END;
$$;
