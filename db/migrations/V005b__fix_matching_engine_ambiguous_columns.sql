-- VerityTick Migration V005b
-- Fix: Resolve ambiguous column references in matching engine
--
-- PostgreSQL 18 PL/pgSQL is strict about column vs variable disambiguation.
-- The v_resting RECORD has fields like remaining_quantity that clash with
-- table columns in UPDATE statements. Fix by table-qualifying all column refs.

-- Drop and recreate place_order with fixed column references

CREATE OR REPLACE FUNCTION trading.place_order(
    p_tenant_id UUID,
    p_account_id UUID,
    p_market_id UUID,
    p_side TEXT,
    p_limit_price NUMERIC(30, 18),
    p_quantity NUMERIC(30, 18),
    p_idempotency_key TEXT DEFAULT NULL
) RETURNS TABLE (
    order_id UUID,
    status TEXT,
    remaining_quantity NUMERIC(30, 18),
    trades_executed INTEGER,
    message TEXT
) AS $$
DECLARE
    v_market RECORD;
    v_account RECORD;
    v_order_id UUID;
    v_priority_seq BIGINT;
    v_base_asset_id UUID;
    v_quote_asset_id UUID;
    v_reserve_asset_id UUID;
    v_reserve_amount NUMERIC(30, 18);
    v_available NUMERIC(30, 18);
    v_remaining NUMERIC(30, 18);
    v_trades_count INTEGER := 0;
    v_resting RECORD;
    v_fill_qty NUMERIC(30, 18);
    v_fill_price NUMERIC(30, 18);
    v_trade_id UUID;
    v_order_status TEXT;
    v_trading_acct_id UUID;
    v_reservation_acct_id UUID;
    v_counter_trading_acct_id UUID;
    v_counter_reservation_acct_id UUID;
    v_existing_order_id UUID;
    v_resting_remaining NUMERIC(30, 18);
    v_resting_new_status TEXT;
    v_incoming_new_status TEXT;
BEGIN
    -- ─── Idempotency check ──────────────────────────────────────────────
    IF p_idempotency_key IS NOT NULL THEN
        SELECT o.order_id, o.status, o.remaining_quantity
        INTO v_existing_order_id, v_order_status, v_remaining
        FROM trading.orders o
        WHERE o.account_id = p_account_id
          AND o.idempotency_key = p_idempotency_key;

        IF FOUND THEN
            RETURN QUERY SELECT v_existing_order_id, v_order_status, v_remaining, 0,
                'Duplicate request — returning existing order'::TEXT;
            RETURN;
        END IF;
    END IF;

    -- ─── Validate market ────────────────────────────────────────────────
    SELECT m.market_id, m.base_asset_id, m.quote_asset_id, m.status,
           m.min_quantity, m.min_notional, m.next_priority_seq
    INTO v_market
    FROM core.markets m
    WHERE m.market_id = p_market_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT NULL::UUID, 'rejected'::TEXT, 0::NUMERIC(30,18), 0,
            'Market not found'::TEXT;
        RETURN;
    END IF;

    IF v_market.status != 'open' THEN
        RETURN QUERY SELECT NULL::UUID, 'rejected'::TEXT, 0::NUMERIC(30,18), 0,
            ('Market is ' || v_market.status)::TEXT;
        RETURN;
    END IF;

    v_base_asset_id := v_market.base_asset_id;
    v_quote_asset_id := v_market.quote_asset_id;

    -- ─── Validate account ───────────────────────────────────────────────
    SELECT a.account_id, a.tenant_id, a.status INTO v_account
    FROM core.trading_accounts a
    WHERE a.account_id = p_account_id
      AND a.tenant_id = p_tenant_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT NULL::UUID, 'rejected'::TEXT, 0::NUMERIC(30,18), 0,
            'Account not found or does not belong to tenant'::TEXT;
        RETURN;
    END IF;

    IF v_account.status != 'active' THEN
        RETURN QUERY SELECT NULL::UUID, 'rejected'::TEXT, 0::NUMERIC(30,18), 0,
            'Account is not active'::TEXT;
        RETURN;
    END IF;

    -- ─── Validate order params ──────────────────────────────────────────
    IF p_side NOT IN ('buy', 'sell') THEN
        RETURN QUERY SELECT NULL::UUID, 'rejected'::TEXT, 0::NUMERIC(30,18), 0,
            'Invalid side'::TEXT;
        RETURN;
    END IF;

    IF p_limit_price <= 0 THEN
        RETURN QUERY SELECT NULL::UUID, 'rejected'::TEXT, 0::NUMERIC(30,18), 0,
            'Price must be positive'::TEXT;
        RETURN;
    END IF;

    IF p_quantity <= 0 OR p_quantity < v_market.min_quantity THEN
        RETURN QUERY SELECT NULL::UUID, 'rejected'::TEXT, 0::NUMERIC(30,18), 0,
            ('Quantity must be >= ' || v_market.min_quantity)::TEXT;
        RETURN;
    END IF;

    IF p_limit_price * p_quantity < v_market.min_notional THEN
        RETURN QUERY SELECT NULL::UUID, 'rejected'::TEXT, 0::NUMERIC(30,18), 0,
            ('Notional value must be >= ' || v_market.min_notional)::TEXT;
        RETURN;
    END IF;

    -- ─── Ensure ledger accounts ─────────────────────────────────────────
    PERFORM ledger.ensure_accounts(p_tenant_id, p_account_id, v_base_asset_id);
    PERFORM ledger.ensure_accounts(p_tenant_id, p_account_id, v_quote_asset_id);

    -- ─── Reserve funds ──────────────────────────────────────────────────
    IF p_side = 'buy' THEN
        v_reserve_asset_id := v_quote_asset_id;
        v_reserve_amount := p_limit_price * p_quantity;
    ELSE
        v_reserve_asset_id := v_base_asset_id;
        v_reserve_amount := p_quantity;
    END IF;

    v_available := ledger.available_balance(p_account_id, v_reserve_asset_id);

    IF v_available < v_reserve_amount THEN
        RETURN QUERY SELECT NULL::UUID, 'rejected'::TEXT, 0::NUMERIC(30,18), 0,
            ('Insufficient balance. Need ' || v_reserve_amount ||
             ', available ' || v_available)::TEXT;
        RETURN;
    END IF;

    SELECT la.ledger_account_id INTO v_trading_acct_id
    FROM ledger.accounts la
    WHERE la.trading_account_id = p_account_id
      AND la.asset_id = v_reserve_asset_id
      AND la.account_type = 'trading';

    SELECT la.ledger_account_id INTO v_reservation_acct_id
    FROM ledger.accounts la
    WHERE la.trading_account_id = p_account_id
      AND la.asset_id = v_reserve_asset_id
      AND la.account_type = 'reservation';

    PERFORM ledger.post_transfer(
        p_tenant_id, 'reservation', 'order', NULL,
        'Reserve for ' || p_side || ' order',
        v_trading_acct_id, v_reservation_acct_id,
        v_reserve_asset_id, v_reserve_amount
    );

    -- ─── Assign priority sequence ───────────────────────────────────────
    UPDATE core.markets
    SET next_priority_seq = next_priority_seq + 1
    WHERE core.markets.market_id = p_market_id
    RETURNING next_priority_seq INTO v_priority_seq;

    -- ─── Insert order ───────────────────────────────────────────────────
    INSERT INTO trading.orders (
        tenant_id, account_id, market_id, side, limit_price,
        original_quantity, remaining_quantity, status,
        priority_seq, idempotency_key
    ) VALUES (
        p_tenant_id, p_account_id, p_market_id, p_side, p_limit_price,
        p_quantity, p_quantity, 'open',
        v_priority_seq, p_idempotency_key
    ) RETURNING trading.orders.order_id INTO v_order_id;

    INSERT INTO trading.order_events (order_id, event_type, remaining_after, details)
    VALUES (v_order_id, 'accepted', p_quantity,
            jsonb_build_object('price', p_limit_price, 'quantity', p_quantity, 'side', p_side));

    v_remaining := p_quantity;

    -- ─── Match against resting orders ───────────────────────────────────
    IF p_side = 'buy' THEN
        FOR v_resting IN
            SELECT o.order_id AS r_order_id, o.account_id AS r_account_id,
                   o.tenant_id AS r_tenant_id, o.limit_price AS r_limit_price,
                   o.remaining_quantity AS r_remaining_quantity
            FROM trading.orders o
            WHERE o.market_id = p_market_id
              AND o.side = 'sell'
              AND o.status IN ('open', 'partially_filled')
              AND o.limit_price <= p_limit_price
              AND o.order_id != v_order_id
            ORDER BY o.limit_price ASC, o.priority_seq ASC
            FOR UPDATE OF o
        LOOP
            EXIT WHEN v_remaining <= 0;

            v_fill_qty := LEAST(v_remaining, v_resting.r_remaining_quantity);
            v_fill_price := v_resting.r_limit_price;
            v_resting_remaining := v_resting.r_remaining_quantity - v_fill_qty;

            IF v_resting_remaining = 0 THEN
                v_resting_new_status := 'filled';
            ELSE
                v_resting_new_status := 'partially_filled';
            END IF;

            -- Create trade
            INSERT INTO trading.trades (
                market_id, buy_order_id, buy_account_id,
                sell_order_id, sell_account_id, price, quantity
            ) VALUES (
                p_market_id, v_order_id, p_account_id,
                v_resting.r_order_id, v_resting.r_account_id, v_fill_price, v_fill_qty
            ) RETURNING trading.trades.trade_id INTO v_trade_id;

            -- Update resting order
            UPDATE trading.orders
            SET remaining_quantity = v_resting_remaining,
                status = v_resting_new_status,
                updated_at = now()
            WHERE trading.orders.order_id = v_resting.r_order_id;

            v_remaining := v_remaining - v_fill_qty;

            IF v_remaining = 0 THEN v_incoming_new_status := 'filled';
            ELSE v_incoming_new_status := 'partially_filled';
            END IF;

            -- Record events for both sides
            INSERT INTO trading.order_events
                (order_id, event_type, trade_id, fill_quantity, fill_price, remaining_after)
            VALUES
                (v_resting.r_order_id, v_resting_new_status,
                 v_trade_id, v_fill_qty, v_fill_price, v_resting_remaining),
                (v_order_id, v_incoming_new_status,
                 v_trade_id, v_fill_qty, v_fill_price, v_remaining);

            -- ─── Settlement ─────────────────────────────────────────────
            PERFORM ledger.ensure_accounts(v_resting.r_tenant_id, v_resting.r_account_id, v_base_asset_id);
            PERFORM ledger.ensure_accounts(v_resting.r_tenant_id, v_resting.r_account_id, v_quote_asset_id);

            -- Buyer pays quote: from buyer reservation → seller trading
            SELECT la.ledger_account_id INTO v_counter_trading_acct_id
            FROM ledger.accounts la
            WHERE la.trading_account_id = v_resting.r_account_id
              AND la.asset_id = v_quote_asset_id
              AND la.account_type = 'trading';

            PERFORM ledger.post_transfer(
                p_tenant_id, 'trade_settlement', 'trade', v_trade_id,
                'Buyer pays quote',
                v_reservation_acct_id, v_counter_trading_acct_id,
                v_quote_asset_id, v_fill_price * v_fill_qty
            );

            -- Seller delivers base: from seller reservation → buyer trading
            SELECT la.ledger_account_id INTO v_counter_reservation_acct_id
            FROM ledger.accounts la
            WHERE la.trading_account_id = v_resting.r_account_id
              AND la.asset_id = v_base_asset_id
              AND la.account_type = 'reservation';

            SELECT la.ledger_account_id INTO v_counter_trading_acct_id
            FROM ledger.accounts la
            WHERE la.trading_account_id = p_account_id
              AND la.asset_id = v_base_asset_id
              AND la.account_type = 'trading';

            PERFORM ledger.post_transfer(
                v_resting.r_tenant_id, 'trade_settlement', 'trade', v_trade_id,
                'Seller delivers base',
                v_counter_reservation_acct_id, v_counter_trading_acct_id,
                v_base_asset_id, v_fill_qty
            );

            v_trades_count := v_trades_count + 1;
        END LOOP;

        -- Release excess buyer reservation if fully filled at better prices
        IF v_remaining = 0 THEN
            DECLARE
                v_total_quote_spent NUMERIC(30, 18);
                v_excess NUMERIC(30, 18);
            BEGIN
                SELECT COALESCE(SUM(t.price * t.quantity), 0)
                INTO v_total_quote_spent
                FROM trading.trades t
                WHERE t.buy_order_id = v_order_id;

                v_excess := v_reserve_amount - v_total_quote_spent;
                IF v_excess > 0 THEN
                    PERFORM ledger.post_transfer(
                        p_tenant_id, 'release', 'order', v_order_id,
                        'Release excess reservation after full fill',
                        v_reservation_acct_id, v_trading_acct_id,
                        v_reserve_asset_id, v_excess
                    );
                END IF;
            END;
        END IF;

    ELSE  -- p_side = 'sell'
        FOR v_resting IN
            SELECT o.order_id AS r_order_id, o.account_id AS r_account_id,
                   o.tenant_id AS r_tenant_id, o.limit_price AS r_limit_price,
                   o.remaining_quantity AS r_remaining_quantity
            FROM trading.orders o
            WHERE o.market_id = p_market_id
              AND o.side = 'buy'
              AND o.status IN ('open', 'partially_filled')
              AND o.limit_price >= p_limit_price
              AND o.order_id != v_order_id
            ORDER BY o.limit_price DESC, o.priority_seq ASC
            FOR UPDATE OF o
        LOOP
            EXIT WHEN v_remaining <= 0;

            v_fill_qty := LEAST(v_remaining, v_resting.r_remaining_quantity);
            v_fill_price := v_resting.r_limit_price;
            v_resting_remaining := v_resting.r_remaining_quantity - v_fill_qty;

            IF v_resting_remaining = 0 THEN
                v_resting_new_status := 'filled';
            ELSE
                v_resting_new_status := 'partially_filled';
            END IF;

            INSERT INTO trading.trades (
                market_id, buy_order_id, buy_account_id,
                sell_order_id, sell_account_id, price, quantity
            ) VALUES (
                p_market_id, v_resting.r_order_id, v_resting.r_account_id,
                v_order_id, p_account_id, v_fill_price, v_fill_qty
            ) RETURNING trading.trades.trade_id INTO v_trade_id;

            UPDATE trading.orders
            SET remaining_quantity = v_resting_remaining,
                status = v_resting_new_status,
                updated_at = now()
            WHERE trading.orders.order_id = v_resting.r_order_id;

            v_remaining := v_remaining - v_fill_qty;

            IF v_remaining = 0 THEN v_incoming_new_status := 'filled';
            ELSE v_incoming_new_status := 'partially_filled';
            END IF;

            INSERT INTO trading.order_events
                (order_id, event_type, trade_id, fill_quantity, fill_price, remaining_after)
            VALUES
                (v_resting.r_order_id, v_resting_new_status,
                 v_trade_id, v_fill_qty, v_fill_price, v_resting_remaining),
                (v_order_id, v_incoming_new_status,
                 v_trade_id, v_fill_qty, v_fill_price, v_remaining);

            -- Settlement
            PERFORM ledger.ensure_accounts(v_resting.r_tenant_id, v_resting.r_account_id, v_base_asset_id);
            PERFORM ledger.ensure_accounts(v_resting.r_tenant_id, v_resting.r_account_id, v_quote_asset_id);

            -- Buyer (resting) pays quote: from buyer reservation → seller trading
            SELECT la.ledger_account_id INTO v_counter_reservation_acct_id
            FROM ledger.accounts la
            WHERE la.trading_account_id = v_resting.r_account_id
              AND la.asset_id = v_quote_asset_id
              AND la.account_type = 'reservation';

            SELECT la.ledger_account_id INTO v_counter_trading_acct_id
            FROM ledger.accounts la
            WHERE la.trading_account_id = p_account_id
              AND la.asset_id = v_quote_asset_id
              AND la.account_type = 'trading';

            PERFORM ledger.post_transfer(
                v_resting.r_tenant_id, 'trade_settlement', 'trade', v_trade_id,
                'Buyer pays quote',
                v_counter_reservation_acct_id, v_counter_trading_acct_id,
                v_quote_asset_id, v_fill_price * v_fill_qty
            );

            -- Seller delivers base: from seller reservation → buyer trading
            SELECT la.ledger_account_id INTO v_counter_trading_acct_id
            FROM ledger.accounts la
            WHERE la.trading_account_id = v_resting.r_account_id
              AND la.asset_id = v_base_asset_id
              AND la.account_type = 'trading';

            PERFORM ledger.post_transfer(
                p_tenant_id, 'trade_settlement', 'trade', v_trade_id,
                'Seller delivers base',
                v_reservation_acct_id, v_counter_trading_acct_id,
                v_base_asset_id, v_fill_qty
            );

            -- Release excess resting buyer reservation if fully filled
            IF v_resting_remaining = 0 THEN
                DECLARE
                    v_resting_total_spent NUMERIC(30, 18);
                    v_resting_orig_reserved NUMERIC(30, 18);
                    v_resting_excess NUMERIC(30, 18);
                    v_resting_res_acct UUID;
                    v_resting_trd_acct UUID;
                BEGIN
                    SELECT COALESCE(SUM(t.price * t.quantity), 0)
                    INTO v_resting_total_spent
                    FROM trading.trades t
                    WHERE t.buy_order_id = v_resting.r_order_id;

                    SELECT o.limit_price * o.original_quantity INTO v_resting_orig_reserved
                    FROM trading.orders o WHERE o.order_id = v_resting.r_order_id;

                    v_resting_excess := v_resting_orig_reserved - v_resting_total_spent;

                    IF v_resting_excess > 0 THEN
                        SELECT la.ledger_account_id INTO v_resting_res_acct
                        FROM ledger.accounts la
                        WHERE la.trading_account_id = v_resting.r_account_id
                          AND la.asset_id = v_quote_asset_id
                          AND la.account_type = 'reservation';

                        SELECT la.ledger_account_id INTO v_resting_trd_acct
                        FROM ledger.accounts la
                        WHERE la.trading_account_id = v_resting.r_account_id
                          AND la.asset_id = v_quote_asset_id
                          AND la.account_type = 'trading';

                        PERFORM ledger.post_transfer(
                            v_resting.r_tenant_id, 'release', 'order', v_resting.r_order_id,
                            'Release excess after full fill',
                            v_resting_res_acct, v_resting_trd_acct,
                            v_quote_asset_id, v_resting_excess
                        );
                    END IF;
                END;
            END IF;

            v_trades_count := v_trades_count + 1;
        END LOOP;
    END IF;

    -- ─── Update incoming order status ───────────────────────────────────
    IF v_remaining = 0 THEN
        v_order_status := 'filled';
    ELSIF v_remaining < p_quantity THEN
        v_order_status := 'partially_filled';
    ELSE
        v_order_status := 'open';
    END IF;

    UPDATE trading.orders
    SET remaining_quantity = v_remaining,
        status = v_order_status,
        updated_at = now()
    WHERE trading.orders.order_id = v_order_id;

    RETURN QUERY SELECT v_order_id, v_order_status, v_remaining, v_trades_count,
        'Order placed successfully'::TEXT;
END;
$$ LANGUAGE plpgsql;
