-- Resolves the effective unit price for each customer-SKU pair by walking a
-- waterfall: contract price → segment discount → active promotion → list price.
-- Writes the resolved prices to effective_prices for use by the order API.
CREATE PROCEDURE usp_pricing_engine
    @effective_date DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @effective_date = ISNULL(@effective_date, CAST(GETDATE() AS DATE));

    -- Candidate prices from all pricing layers
    SELECT
        cp.customer_id,
        cp.sku_id,
        lp.list_price,
        -- Contract price (highest specificity)
        con.contract_price,
        -- Segment discount applied to list price
        lp.list_price * (1 - ISNULL(seg.discount_pct, 0))       AS segment_price,
        -- Active promotional price from JSON rules blob
        TRY_CAST(
            JSON_VALUE(pr.rules_json, '$.fixed_price')
            AS DECIMAL(12,4)
        )                                                         AS promo_fixed_price,
        -- Percentage promo from JSON
        lp.list_price * (1 - ISNULL(
            TRY_CAST(JSON_VALUE(pr.rules_json, '$.discount_pct') AS DECIMAL(5,4)),
            0
        ))                                                        AS promo_pct_price
    INTO #price_candidates
    FROM (
        SELECT DISTINCT customer_id, sku_id
        FROM   dbo.customer_sku_catalog
        WHERE  is_active = 1
    ) cp
    JOIN dbo.list_prices lp
        ON  lp.sku_id       = cp.sku_id
        AND lp.effective_date <= @effective_date
        AND (lp.end_date IS NULL OR lp.end_date >= @effective_date)
    LEFT JOIN dbo.contract_prices con
        ON  con.customer_id     = cp.customer_id
        AND con.sku_id          = cp.sku_id
        AND con.start_date      <= @effective_date
        AND (con.end_date IS NULL OR con.end_date >= @effective_date)
    LEFT JOIN (
        SELECT customer_id, discount_pct
        FROM   dbo.segment_discounts sd
        JOIN   dbo.customer_segments cs
            ON  cs.segment_id    = sd.segment_id
            AND cs.effective_date <= @effective_date
    ) seg ON seg.customer_id = cp.customer_id
    LEFT JOIN dbo.promotions pr
        ON  pr.sku_id        = cp.sku_id
        AND pr.start_date    <= @effective_date
        AND pr.end_date      >= @effective_date
        AND pr.is_active     = 1;

    -- Apply waterfall: pick lowest valid price per customer-SKU
    SELECT
        customer_id,
        sku_id,
        list_price,
        contract_price,
        segment_price,
        ISNULL(promo_fixed_price, promo_pct_price) AS effective_promo_price,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id, sku_id
            ORDER BY
                ISNULL(contract_price, 999999),
                ISNULL(ISNULL(promo_fixed_price, promo_pct_price), 999999),
                segment_price
        )                                           AS price_rank
    INTO #resolved
    FROM #price_candidates;

    -- Enforce margin floor: never below 30% margin
    SELECT
        r.customer_id,
        r.sku_id,
        IIF(effective_price < cost.unit_cost * 1.30,
            cost.unit_cost * 1.30,
            effective_price)                        AS final_price,
        r.effective_source,
        @effective_date                             AS effective_date
    INTO #margin_adjusted
    FROM (
        SELECT
            customer_id,
            sku_id,
            CASE price_rank
                WHEN 1 THEN COALESCE(contract_price, ISNULL(effective_promo_price, segment_price), list_price)
                ELSE list_price
            END                                     AS effective_price,
            CASE
                WHEN contract_price IS NOT NULL AND price_rank = 1 THEN 'CONTRACT'
                WHEN effective_promo_price IS NOT NULL             THEN 'PROMOTION'
                WHEN segment_price < list_price                    THEN 'SEGMENT'
                ELSE 'LIST'
            END                                     AS effective_source
        FROM #resolved
        WHERE price_rank = 1
    ) r
    JOIN dbo.sku_costs cost ON cost.sku_id = r.sku_id
                           AND cost.cost_date <= @effective_date;

    -- Upsert resolved prices
    MERGE dbo.effective_prices AS tgt
    USING #margin_adjusted      AS src
        ON tgt.customer_id = src.customer_id AND tgt.sku_id = src.sku_id
    WHEN MATCHED THEN
        UPDATE SET
            tgt.final_price      = src.final_price,
            tgt.effective_source = src.effective_source,
            tgt.effective_date   = src.effective_date,
            tgt.updated_at       = GETDATE()
    WHEN NOT MATCHED THEN
        INSERT (customer_id, sku_id, final_price, effective_source, effective_date, updated_at)
        VALUES (src.customer_id, src.sku_id, src.final_price, src.effective_source, src.effective_date, GETDATE());
END
