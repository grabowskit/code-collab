-- Scans open service tickets for SLA breaches, escalates to the notification
-- queue, and updates breach flags. Intended to run on a SQL Agent schedule.
CREATE PROCEDURE usp_sla_breach_monitor
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @check_time DATETIME2 = SYSDATETIME();

    -- SLA thresholds by priority tier (hours)
    SELECT
        t.ticket_id,
        t.priority,
        t.customer_id,
        t.assigned_team,
        t.created_at,
        t.last_updated_at,
        DATEDIFF(minute, t.created_at, @check_time)             AS age_minutes,
        sla.response_sla_minutes,
        sla.resolution_sla_minutes,
        CASE WHEN t.first_response_at IS NULL
                  AND DATEDIFF(minute, t.created_at, @check_time) > sla.response_sla_minutes
             THEN 1 ELSE 0 END                                   AS response_breached,
        CASE WHEN t.resolved_at IS NULL
                  AND DATEDIFF(minute, t.created_at, @check_time) > sla.resolution_sla_minutes
             THEN 1 ELSE 0 END                                   AS resolution_breached,
        -- How many minutes until the next threshold is hit
        CASE WHEN t.first_response_at IS NULL
             THEN sla.response_sla_minutes - DATEDIFF(minute, t.created_at, @check_time)
             ELSE sla.resolution_sla_minutes - DATEDIFF(minute, t.created_at, @check_time)
        END                                                       AS minutes_until_next_breach
    INTO #ticket_status
    FROM dbo.tickets        t
    JOIN dbo.sla_policies   sla ON sla.priority = t.priority
    WHERE t.status NOT IN ('RESOLVED', 'CLOSED', 'CANCELLED');

    -- Breach events to raise (not already escalated)
    SELECT ts.*
    INTO #new_breaches
    FROM #ticket_status ts
    WHERE (ts.response_breached = 1 OR ts.resolution_breached = 1)
      AND NOT EXISTS (
            SELECT 1 FROM dbo.sla_breach_log bl
            WHERE bl.ticket_id           = ts.ticket_id
              AND bl.response_breached   = ts.response_breached
              AND bl.resolution_breached = ts.resolution_breached
          );

    -- Write breach log
    INSERT INTO dbo.sla_breach_log
        (ticket_id, priority, customer_id, assigned_team,
         response_breached, resolution_breached,
         age_minutes, breach_detected_at)
    SELECT
        ticket_id, priority, customer_id, assigned_team,
        response_breached, resolution_breached,
        age_minutes, @check_time
    FROM #new_breaches;

    -- Notify queue — critical and high priority tickets
    INSERT INTO dbo.notification_queue
        (notification_type, entity_type, entity_id, payload, priority, created_at)
    OUTPUT
        inserted.notification_id,
        inserted.entity_id
    INTO dbo.notification_audit (notification_id, ticket_id)
    SELECT
        'SLA_BREACH',
        'TICKET',
        nb.ticket_id,
        '{"priority":"' + nb.priority + '",'
        + '"age_minutes":' + CAST(nb.age_minutes AS VARCHAR)
        + '}',
        CASE nb.priority WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 ELSE 3 END,
        @check_time
    FROM #new_breaches nb
    WHERE nb.priority IN ('CRITICAL', 'HIGH');

    -- Send email for critical tickets via Database Mail
    DECLARE @ticket_id  INT;
    DECLARE @customer   NVARCHAR(200);

    DECLARE cur_critical CURSOR FAST_FORWARD FOR
        SELECT nb.ticket_id, c.customer_name
        FROM   #new_breaches nb
        JOIN   dbo.customers c ON c.customer_id = nb.customer_id
        WHERE  nb.priority = 'CRITICAL';

    OPEN cur_critical;
    FETCH NEXT FROM cur_critical INTO @ticket_id, @customer;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC msdb.dbo.sp_send_dbmail
            @profile_name = 'SupportAlerts',
            @recipients   = 'oncall@company.com',
            @subject      = 'CRITICAL SLA Breach — Ticket ' + CAST(@ticket_id AS VARCHAR),
            @body         = 'Customer: ' + @customer + ' | Ticket: ' + CAST(@ticket_id AS VARCHAR);

        FETCH NEXT FROM cur_critical INTO @ticket_id, @customer;
    END

    CLOSE cur_critical;
    DEALLOCATE cur_critical;

    -- Update ticket breach flags in bulk
    UPDATE t
    SET    t.sla_breached    = 1,
           t.last_updated_at = @check_time
    FROM   dbo.tickets    t
    JOIN   #new_breaches  nb ON nb.ticket_id = t.ticket_id;
END
