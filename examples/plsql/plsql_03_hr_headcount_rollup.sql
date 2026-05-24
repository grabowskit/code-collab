-- Rolls up headcount, FTE, and 90-day attrition metrics through the
-- full org hierarchy using CONNECT BY, then writes the result to the
-- hr_headcount_summary reporting table.
CREATE OR REPLACE PROCEDURE proc_hr_headcount_rollup (
    p_as_of_date    IN  DATE DEFAULT TRUNC(SYSDATE),
    p_rows_written  OUT NUMBER
) IS
    v_fiscal_year   NUMBER := TO_NUMBER(TO_CHAR(p_as_of_date, 'YYYY'));

BEGIN
    -- Purge existing snapshot for this date
    DELETE FROM hr_headcount_summary WHERE snapshot_date = p_as_of_date;

    -- Build full org tree and aggregate headcount at every node
    INSERT INTO hr_headcount_summary (
        snapshot_date, manager_emp_id, org_path, org_depth,
        direct_headcount, total_headcount, total_fte,
        attrition_90d, fiscal_year
    )
    SELECT
        p_as_of_date,
        mgr.emp_id,
        SYS_CONNECT_BY_PATH(e.emp_id, '/') AS org_path,
        LEVEL                                AS org_depth,
        -- Direct reports only
        (SELECT COUNT(*)
         FROM   employees d
         WHERE  d.manager_id   = mgr.emp_id
           AND  d.status       = 'ACTIVE'
           AND  d.hire_date   <= p_as_of_date)  AS direct_headcount,
        -- All reports in subtree
        (SELECT COUNT(*)
         FROM   employees sub
         WHERE  sub.status     = 'ACTIVE'
           AND  sub.hire_date <= p_as_of_date
         CONNECT BY PRIOR sub.emp_id = sub.manager_id
         START WITH sub.manager_id   = mgr.emp_id) AS total_headcount,
        -- FTE sum (part-time = 0.5)
        (SELECT NVL(SUM(
             CASE WHEN sub.employment_type = 'FULL_TIME' THEN 1
                  WHEN sub.employment_type = 'PART_TIME' THEN 0.5
                  ELSE 0 END), 0)
         FROM   employees sub
         WHERE  sub.status     = 'ACTIVE'
           AND  sub.hire_date <= p_as_of_date
         CONNECT BY PRIOR sub.emp_id = sub.manager_id
         START WITH sub.manager_id   = mgr.emp_id) AS total_fte,
        -- Voluntary attrition in trailing 90 days
        (SELECT COUNT(*)
         FROM   employees sub
         WHERE  sub.termination_date BETWEEN p_as_of_date - 90 AND p_as_of_date
           AND  sub.termination_type = 'VOLUNTARY'
         CONNECT BY PRIOR sub.emp_id = sub.manager_id
         START WITH sub.manager_id   = mgr.emp_id) AS attrition_90d,
        v_fiscal_year
    FROM   employees mgr,
           employees e
    WHERE  REGEXP_LIKE(mgr.org_code, '^[A-Z]{2}[0-9]{4}$')   -- valid org codes only
      AND  mgr.status    = 'ACTIVE'
      AND  e.manager_id  = mgr.emp_id
    CONNECT BY PRIOR e.emp_id = e.manager_id
    START WITH e.manager_id IS NULL;

    p_rows_written := SQL%ROWCOUNT;

    -- Propagate org labels from the org chart dimension
    UPDATE hr_headcount_summary hs
    SET    hs.org_name = (
               SELECT oc.org_name
               FROM   org_chart oc
               WHERE  oc.manager_emp_id = hs.manager_emp_id
                 AND  ROWNUM = 1
           )
    WHERE  hs.snapshot_date = p_as_of_date;

    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_rows_written := 0;
        RAISE;
END proc_hr_headcount_rollup;
