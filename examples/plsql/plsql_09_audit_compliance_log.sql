-- Row-level audit trigger for SOX-regulated tables (orders, payments, gl_entries).
-- Captures before/after values, session context, and a SHA-256 hash of the row
-- for tamper detection. Writes to the immutable audit_log table.
CREATE OR REPLACE TRIGGER trg_sox_audit
AFTER INSERT OR UPDATE OR DELETE
ON orders
FOR EACH ROW
DECLARE
    v_action        VARCHAR2(10);
    v_session_id    VARCHAR2(100) := USERENV('SESSIONID');
    v_user          VARCHAR2(100) := SYS_CONTEXT('USERENV', 'SESSION_USER');
    v_ip_address    VARCHAR2(50)  := SYS_CONTEXT('USERENV', 'IP_ADDRESS');
    v_row_hash_new  VARCHAR2(64);
    v_row_hash_old  VARCHAR2(64);
    v_audit_id      RAW(16) := SYS_GUID();
BEGIN
    -- Determine DML action
    IF    INSERTING THEN v_action := 'INSERT';
    ELSIF UPDATING  THEN v_action := 'UPDATE';
    ELSIF DELETING  THEN v_action := 'DELETE';
    END IF;

    -- Hash the new row for tamper detection
    IF NOT DELETING THEN
        v_row_hash_new := STANDARD_HASH(
            :NEW.order_id        || '|' ||
            :NEW.customer_id     || '|' ||
            :NEW.order_amount    || '|' ||
            :NEW.status          || '|' ||
            :NEW.last_updated,
            'SHA256'
        );
    END IF;

    -- Hash the old row
    IF NOT INSERTING THEN
        v_row_hash_old := STANDARD_HASH(
            :OLD.order_id        || '|' ||
            :OLD.customer_id     || '|' ||
            :OLD.order_amount    || '|' ||
            :OLD.status          || '|' ||
            :OLD.last_updated,
            'SHA256'
        );
    END IF;

    -- Write to immutable audit log
    INSERT INTO audit_log (
        audit_id,
        table_name,
        record_id,
        action,
        old_customer_id,    new_customer_id,
        old_order_amount,   new_order_amount,
        old_status,         new_status,
        row_hash_old,       row_hash_new,
        session_id,
        db_user,
        ip_address,
        audit_timestamp
    ) VALUES (
        v_audit_id,
        'ORDERS',
        NVL(:NEW.order_id, :OLD.order_id),
        v_action,
        :OLD.customer_id,   :NEW.customer_id,
        :OLD.order_amount,  :NEW.order_amount,
        :OLD.status,        :NEW.status,
        v_row_hash_old,     v_row_hash_new,
        v_session_id,
        v_user,
        v_ip_address,
        SYSTIMESTAMP
    );

    -- Flag high-value changes (> $50,000) for compliance review queue
    IF (INSERTING OR UPDATING)
        AND :NEW.order_amount > 50000
        AND (:OLD.order_amount IS NULL OR :NEW.order_amount <> :OLD.order_amount)
    THEN
        INSERT INTO compliance_review_queue (
            audit_id, table_name, record_id, flag_reason, flagged_at
        ) VALUES (
            v_audit_id, 'ORDERS',
            :NEW.order_id,
            'High-value order ' || :NEW.order_amount || ' > $50,000 threshold',
            SYSTIMESTAMP
        );
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        -- Audit failures must not block the originating DML
        INSERT INTO audit_error_log (error_code, error_message, trigger_name, logged_at)
        VALUES (SQLCODE, SQLERRM, 'TRG_SOX_AUDIT', SYSTIMESTAMP);
END trg_sox_audit;
