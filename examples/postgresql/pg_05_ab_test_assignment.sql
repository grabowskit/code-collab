-- Assigns users to A/B test variants deterministically using an MD5 hash of
-- user_id + experiment_key, logs the exposure event, and computes running
-- conversion metrics per variant.
CREATE OR REPLACE PROCEDURE proc_ab_test_assignment(
    p_experiment_key    TEXT,
    p_assignment_date   DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_experiment_id     INT;
    v_traffic_pct       NUMERIC;
    v_variants          TEXT[];
    v_new_assignments   INT;
BEGIN
    -- Load experiment config
    SELECT experiment_id, traffic_pct, variant_keys
    INTO   v_experiment_id, v_traffic_pct, v_variants
    FROM   experiments
    WHERE  experiment_key = p_experiment_key
      AND  status         = 'RUNNING'
      AND  p_assignment_date BETWEEN start_date AND COALESCE(end_date, p_assignment_date);

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Experiment % is not active on %.', p_experiment_key, p_assignment_date;
    END IF;

    -- Assign eligible users not yet in the experiment
    -- Deterministic bucketing: MD5 hash → integer 0-999 → variant allocation
    WITH eligible_users AS (
        SELECT
            u.user_id,
            -- Consistent hash: same user always gets same variant
            ('x' || substr(md5(u.user_id::text || p_experiment_key), 1, 8))::bit(32)::int
                & 1023                                              AS bucket  -- 0-1023
        FROM   users u
        WHERE  u.status           = 'ACTIVE'
          AND  u.created_at::date <= p_assignment_date
          AND  NOT EXISTS (
                SELECT 1 FROM experiment_assignments ea
                WHERE  ea.user_id        = u.user_id
                  AND  ea.experiment_id  = v_experiment_id
               )
    ),

    -- Filter to traffic allocation and assign variant
    assignments AS (
        SELECT
            user_id,
            bucket,
            v_variants[
                (bucket % array_length(v_variants, 1)) + 1
            ]                                                       AS variant_key
        FROM eligible_users
        WHERE bucket < (v_traffic_pct / 100.0 * 1024)::int
    )

    INSERT INTO experiment_assignments
        (experiment_id, user_id, variant_key, bucket, assigned_at)
    SELECT
        v_experiment_id, user_id, variant_key, bucket, NOW()
    FROM assignments
    ON CONFLICT (experiment_id, user_id) DO NOTHING;

    GET DIAGNOSTICS v_new_assignments = ROW_COUNT;
    RAISE NOTICE 'Experiment %: % new users assigned.', p_experiment_key, v_new_assignments;

    -- Log exposure events for assigned users
    INSERT INTO exposure_events
        (experiment_id, user_id, variant_key, exposure_date, logged_at)
    SELECT
        ea.experiment_id,
        ea.user_id,
        ea.variant_key,
        p_assignment_date,
        clock_timestamp()     -- intentional: want the actual wall-clock time per row
    FROM experiment_assignments ea
    WHERE ea.experiment_id  = v_experiment_id
      AND ea.assigned_at::date = p_assignment_date
    ON CONFLICT (experiment_id, user_id, exposure_date) DO NOTHING;

    -- Refresh running conversion summary
    INSERT INTO experiment_metrics
        (experiment_id, variant_key, metric_date,
         assigned_users, converted_users, conversion_rate, avg_order_value)
    SELECT
        ea.experiment_id,
        ea.variant_key,
        p_assignment_date,
        COUNT(DISTINCT ea.user_id)                                  AS assigned_users,
        COUNT(DISTINCT o.user_id)                                   AS converted_users,
        ROUND(
            COUNT(DISTINCT o.user_id)::NUMERIC
            / NULLIF(COUNT(DISTINCT ea.user_id), 0) * 100, 2
        )                                                            AS conversion_rate,
        ROUND(AVG(o.order_amount)::NUMERIC, 2)                      AS avg_order_value
    FROM   experiment_assignments ea
    LEFT JOIN orders o
           ON  o.user_id     = ea.user_id
           AND o.created_at::date BETWEEN
               (SELECT start_date FROM experiments WHERE experiment_id = v_experiment_id)
               AND p_assignment_date
    WHERE  ea.experiment_id = v_experiment_id
    GROUP BY ea.experiment_id, ea.variant_key
    ON CONFLICT (experiment_id, variant_key, metric_date)
    DO UPDATE SET
        assigned_users   = EXCLUDED.assigned_users,
        converted_users  = EXCLUDED.converted_users,
        conversion_rate  = EXCLUDED.conversion_rate,
        avg_order_value  = EXCLUDED.avg_order_value;

END;
$$;
