-- Aggregates CRM touchpoints (calls, emails, meetings) from a JSONB activity
-- payload into per-account health scores with exponential recency decay.
-- Writes scores to account_health_scores; upserts on account_id.
CREATE OR REPLACE PROCEDURE proc_crm_activity_rollup(
    p_score_date    DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_decay_halflife_days   NUMERIC := 30.0;  -- score halves every 30 days
    v_rows                  INT;
BEGIN
    WITH
    -- Unpack JSONB activity events into rows
    raw_activities AS (
        SELECT
            al.account_id,
            al.activity_date,
            act->>'type'                                        AS activity_type,
            (act->>'duration_minutes')::NUMERIC                 AS duration_minutes,
            (act->>'sentiment_score')::NUMERIC                  AS sentiment_score,
            al.activity_date - p_score_date                     AS days_ago   -- negative
        FROM   activity_log al,
               LATERAL jsonb_array_elements(al.activities_payload) AS act
        WHERE  al.activity_date >= p_score_date - 90
          AND  al.account_id IS NOT NULL
    ),

    -- Apply exponential recency decay: weight = 0.5 ^ (|days_ago| / halflife)
    decayed_activities AS (
        SELECT
            account_id,
            activity_type,
            sentiment_score,
            duration_minutes,
            days_ago,
            -- Decay weight: recent = 1.0, 30 days ago ≈ 0.5, 60 days ago ≈ 0.25
            POWER(0.5, ABS(days_ago) / v_decay_halflife_days)   AS decay_weight
        FROM raw_activities
    ),

    -- Score per activity type with weights
    activity_scores AS (
        SELECT
            account_id,
            SUM(CASE activity_type
                    WHEN 'MEETING'        THEN 20 * decay_weight
                    WHEN 'DEMO'           THEN 25 * decay_weight
                    WHEN 'EMAIL_REPLY'    THEN  8 * decay_weight
                    WHEN 'CALL_ANSWERED'  THEN 12 * decay_weight
                    WHEN 'CALL_MISSED'    THEN  2 * decay_weight
                    WHEN 'SUPPORT_TICKET' THEN -5 * decay_weight
                    ELSE                       3  * decay_weight
                END)                                             AS raw_engagement_score,
            AVG(sentiment_score)
                FILTER (WHERE sentiment_score IS NOT NULL)       AS avg_sentiment,
            COUNT(*) FILTER (WHERE activity_type = 'MEETING')    AS meetings_90d,
            COUNT(*) FILTER (WHERE activity_type = 'SUPPORT_TICKET') AS tickets_90d,
            SUM(duration_minutes)
                FILTER (WHERE activity_type IN ('MEETING','DEMO')) AS total_meeting_minutes,
            STRING_AGG(DISTINCT activity_type, ', '
                ORDER BY activity_type)                          AS activity_mix,
            MAX(days_ago)                                        AS most_recent_days_ago
        FROM decayed_activities
        GROUP BY account_id
    ),

    -- Combine with account metadata
    final_scores AS (
        SELECT
            s.account_id,
            a.account_name,
            a.account_tier,
            a.csm_user_id,
            LEAST(100, GREATEST(0,
                ROUND(s.raw_engagement_score::NUMERIC, 1)
            ))                                                   AS engagement_score,
            ROUND(COALESCE(s.avg_sentiment, 0.5) * 100::NUMERIC, 1) AS sentiment_score,
            s.meetings_90d,
            s.tickets_90d,
            s.total_meeting_minutes,
            s.activity_mix,
            ABS(s.most_recent_days_ago)                         AS days_since_last_activity,
            CASE
                WHEN s.raw_engagement_score >= 60 AND COALESCE(s.avg_sentiment, 0.5) >= 0.6
                                                                THEN 'HEALTHY'
                WHEN s.raw_engagement_score >= 30              THEN 'NEUTRAL'
                WHEN s.tickets_90d > 3                         THEN 'AT_RISK'
                WHEN ABS(s.most_recent_days_ago) > 60          THEN 'DARK'
                ELSE                                                'NEEDS_ATTENTION'
            END                                                  AS health_status
        FROM   activity_scores  s
        JOIN   accounts         a ON a.account_id = s.account_id
    )

    INSERT INTO account_health_scores (
        account_id, account_name, account_tier, csm_user_id,
        score_date, engagement_score, sentiment_score, health_status,
        meetings_90d, tickets_90d, total_meeting_minutes,
        activity_mix, days_since_last_activity, scored_at
    )
    SELECT
        account_id, account_name, account_tier, csm_user_id,
        p_score_date, engagement_score, sentiment_score, health_status,
        meetings_90d, tickets_90d, total_meeting_minutes,
        activity_mix, days_since_last_activity, NOW()
    FROM final_scores
    ON CONFLICT (account_id, score_date)
    DO UPDATE SET
        engagement_score         = EXCLUDED.engagement_score,
        sentiment_score          = EXCLUDED.sentiment_score,
        health_status            = EXCLUDED.health_status,
        meetings_90d             = EXCLUDED.meetings_90d,
        tickets_90d              = EXCLUDED.tickets_90d,
        days_since_last_activity = EXCLUDED.days_since_last_activity,
        scored_at                = EXCLUDED.scored_at;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE NOTICE 'CRM health scores updated for % accounts on %.', v_rows, p_score_date;

END;
$$;
