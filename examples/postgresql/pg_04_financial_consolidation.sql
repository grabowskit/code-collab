-- Consolidates multi-entity P&L and balance sheet: applies intercompany
-- eliminations, translates foreign-currency entities to USD, and produces
-- a GROUPING SETS summary at entity, region, and total levels.
CREATE OR REPLACE PROCEDURE proc_financial_consolidation(
    p_period_start  DATE,
    p_period_end    DATE,
    p_base_currency TEXT DEFAULT 'USD'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows INT;
BEGIN
    -- Clear existing consolidation rows for this period
    DELETE FROM consolidated_financials
    WHERE  period_start = p_period_start
      AND  period_end   = p_period_end;

    WITH
    -- FX-translated trial balance per entity
    translated_balances AS (
        SELECT
            je.entity_id,
            e.region,
            je.account_code,
            a.account_class,
            a.account_name,
            je.amount * COALESCE(fx.rate_to_usd, 1)     AS amount_usd,
            je.entry_type,
            je.currency_code
        FROM   journal_entries je
        JOIN   entities         e   ON e.entity_id    = je.entity_id
        JOIN   chart_of_accounts a  ON a.account_code = je.account_code
        LEFT JOIN fx_rates       fx ON fx.from_currency = je.currency_code
                                   AND fx.to_currency   = p_base_currency
                                   AND fx.rate_date     = p_period_end
        WHERE  je.entry_date BETWEEN p_period_start AND p_period_end
          AND  je.status = 'POSTED'
    ),

    -- Net balances before eliminations
    net_balances AS (
        SELECT
            entity_id, region, account_code, account_class, account_name,
            SUM(CASE WHEN entry_type = 'DEBIT'  THEN  amount_usd
                     WHEN entry_type = 'CREDIT' THEN -amount_usd
                     ELSE 0 END)                         AS net_amount_usd
        FROM translated_balances
        GROUP BY entity_id, region, account_code, account_class, account_name
    ),

    -- Intercompany eliminations: zero out transactions between group entities
    eliminations AS (
        SELECT
            ic.from_entity_id AS entity_id,
            ic.account_code,
            -ic.elimination_amount                       AS elimination_usd
        FROM   intercompany_eliminations ic
        WHERE  ic.period_start = p_period_start
          AND  ic.period_end   = p_period_end
    ),

    -- Apply eliminations
    post_elimination AS (
        SELECT
            nb.entity_id,
            nb.region,
            nb.account_code,
            nb.account_class,
            nb.account_name,
            nb.net_amount_usd + COALESCE(el.elimination_usd, 0)  AS consolidated_amount
        FROM  net_balances nb
        LEFT JOIN eliminations el
              ON  el.entity_id    = nb.entity_id
              AND el.account_code = nb.account_code
    ),

    -- GROUPING SETS: entity level, region level, and grand total
    summary AS (
        SELECT
            entity_id,
            region,
            account_code,
            account_class,
            account_name,
            SUM(consolidated_amount)                      AS total_amount,
            GROUPING(entity_id)                           AS is_region_rollup,
            GROUPING(region)                              AS is_grand_total,
            array_agg(DISTINCT entity_id ORDER BY entity_id)
                FILTER (WHERE entity_id IS NOT NULL)      AS entity_ids
        FROM post_elimination
        GROUP BY GROUPING SETS (
            (entity_id, region, account_code, account_class, account_name),
            (region,            account_code, account_class, account_name),
            (                   account_code, account_class, account_name)
        )
    )

    INSERT INTO consolidated_financials (
        period_start, period_end, entity_id, region,
        account_code, account_class, account_name,
        total_amount_usd, base_currency,
        consolidation_level, entity_ids, created_at
    )
    SELECT
        p_period_start,
        p_period_end,
        entity_id,
        region,
        account_code,
        account_class,
        account_name,
        ROUND(total_amount::NUMERIC, 2),
        p_base_currency,
        CASE
            WHEN is_grand_total = 1 THEN 'GROUP'
            WHEN is_region_rollup = 1 THEN 'REGION'
            ELSE 'ENTITY'
        END,
        entity_ids,
        NOW()
    FROM summary
    WHERE account_code IS NOT NULL;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE NOTICE 'Financial consolidation complete: % rows for period % to %.', v_rows, p_period_start, p_period_end;

END;
$$;
