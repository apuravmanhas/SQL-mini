-- VerityTick Migration V005
-- Matching Engine Functions
--
-- Core PL/pgSQL functions for:
-- 1. Order placement with validation, reservation, and matching
-- 2. Order cancellation
-- 3. Per-market serialization via row lock on markets table
--
-- MATCHING RULES:
-- - Buy orders match sell orders priced at or below the buy limit
-- - Sell orders match buy orders priced at or above the sell limit
-- - Lowest sell price has priority (for incoming buy)
-- - Highest buy price has priority (for incoming sell)
-- - At same price, earliest priority_seq wins
-- - Execution price = resting order's limit price
-- - An incoming order may match multiple resting orders
-- - Partial fills leave the resting order at its original priority

-- =============================================================================
-- Helper: Ensure ledger accounts exist for a trading account + asset
-- =============================================================================

CREATE OR REPLACE FUNCTION ledger.ensure_accounts(
    p_tenant_id UUID,
    p_trading_account_id UUID,
    p_asset_id UUID
) RETURNS void AS $$
BEGIN
    -- Trading balance account
    INSERT INTO ledger.accounts
        (tenant_id, trading_account_id, asset_id, account_type, label)
    VALUES
        (p_tenant_id, p_trading_account_id, p_asset_id, 'trading', 'main')
    ON CONFLICT (trading_account_id, asset_id, account_type, label) DO NOTHING;

    -- Reservation account
    INSERT INTO ledger.accounts
        (tenant_id, trading_account_id, asset_id, account_type, label)
    VALUES
        (p_tenant_id, p_trading_account_id, p_asset_id, 'reservation', 'main')
    ON CONFLICT (trading_account_id, asset_id, account_type, label) DO NOTHING;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- Helper: Get available balance (trading balance minus reservations)
-- =============================================================================

CREATE OR REPLACE FUNCTION ledger.available_balance(
    p_trading_account_id UUID,
    p_asset_id UUID
) RETURNS NUMERIC(30, 18) AS $$
DECLARE
    v_trading_bal NUMERIC(30, 18);
    v_reserved NUMERIC(30, 18);
BEGIN
    SELECT COALESCE(balance, 0) INTO v_trading_bal
    FROM ledger.accounts
    WHERE trading_account_id = p_trading_account_id
      AND asset_id = p_asset_id
      AND account_type = 'trading';

    SELECT COALESCE(balance, 0) INTO v_reserved
    FROM ledger.accounts
    WHERE trading_account_id = p_trading_account_id
      AND asset_id = p_asset_id
      AND account_type = 'reservation';

    RETURN COALESCE(v_trading_bal, 0) - COALESCE(v_reserved, 0);
END;
$$ LANGUAGE plpgsql STABLE;

-- =============================================================================
-- Internal: Post a ledger journal with entries
-- =============================================================================

CREATE OR REPLACE FUNCTION ledger.post_transfer(
    p_tenant_id UUID,
    p_journal_type TEXT,
    p_reference_type TEXT,
    p_reference_id UUID,
    p_description TEXT,
    p_debit_account_id UUID,
    p_credit_account_id UUID,
    p_asset_id UUID,
    p_amount NUMERIC(30, 18)
) RETURNS UUID AS $$
DECLARE
    v_journal_id UUID;
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Transfer amount must be positive: %', p_amount;
    END IF;

    -- Create journal header
    INSERT INTO ledger.journals
        (tenant_id, journal_type, reference_type, reference_id, description)
    VALUES
        (p_tenant_id, p_journal_type, p_reference_type, p_reference_id, p_description)
    RETURNING journal_id INTO v_journal_id;

    -- Create entry
    INSERT INTO ledger.entries
        (journal_id, debit_account_id, credit_account_id, asset_id, amount)
    VALUES
        (v_journal_id, p_debit_account_id, p_credit_account_id, p_asset_id, p_amount);

    -- Update maintained balances
    UPDATE ledger.accounts SET balance = balance - p_amount, updated_at = now()
    WHERE ledger_account_id = p_debit_account_id;

    UPDATE ledger.accounts SET balance = balance + p_amount, updated_at = now()
    WHERE ledger_account_id = p_credit_account_id;

    RETURN v_journal_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- Deposit funds into a trading account
-- =============================================================================

CREATE OR REPLACE FUNCTION ledger.deposit(
    p_tenant_id UUID,
    p_trading_account_id UUID,
    p_asset_id UUID,
    p_amount NUMERIC(30, 18)
) RETURNS UUID AS $$
DECLARE
    v_system_account UUID;
    v_trading_account UUID;
BEGIN
    -- Ensure accounts exist
    PERFORM ledger.ensure_accounts(p_tenant_id, p_trading_account_id, p_asset_id);

    -- Get or create system account for this asset
    INSERT INTO ledger.accounts
        (tenant_id, asset_id, account_type, label)
    VALUES
        (p_tenant_id, p_asset_id, 'system', 'deposits')
    ON CONFLICT (trading_account_id, asset_id, account_type, label) DO NOTHING;

    -- System deposit account (no trading_account_id)
    SELECT ledger_account_id INTO v_system_account
    FROM ledger.accounts
    WHERE tenant_id = p_tenant_id
      AND trading_account_id IS NULL
      AND asset_id = p_asset_id
      AND account_type = 'system'
      AND label = 'deposits';

    IF v_system_account IS NULL THEN
        INSERT INTO ledger.accounts
            (tenant_id, asset_id, account_type, label)
        VALUES
            (p_tenant_id, p_asset_id, 'system', 'deposits')
        RETURNING ledger_account_id INTO v_system_account;
    END IF;

    -- Trading balance account
    SELECT ledger_account_id INTO v_trading_account
    FROM ledger.accounts
    WHERE trading_account_id = p_trading_account_id
      AND asset_id = p_asset_id
      AND account_type = 'trading';

    RETURN ledger.post_transfer(
        p_tenant_id, 'deposit', 'deposit', NULL,
        'Deposit ' || p_amount || ' of asset',
        v_system_account, v_trading_account, p_asset_id, p_amount
    );
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- CORE: Place an order with validation, reservation, and matching
-- =============================================================================

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
    -- Lock the market row for serialized matching within this market
    SELECT m.*, m.base_asset_id, m.quote_asset_id
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
    SELECT a.* INTO v_account
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

    -- Check notional (price * quantity)
    IF p_limit_price * p_quantity < v_market.min_notional THEN
        RETURN QUERY SELECT NULL::UUID, 'rejected'::TEXT, 0::NUMERIC(30,18), 0,
            ('Notional value must be >= ' || v_market.min_notional)::TEXT;
        RETURN;
    END IF;

    -- ─── Ensure ledger accounts ─────────────────────────────────────────
    PERFORM ledger.ensure_accounts(p_tenant_id, p_account_id, v_base_asset_id);
    PERFORM ledger.ensure_accounts(p_tenant_id, p_account_id, v_quote_asset_id);

    -- ─── Reserve funds ──────────────────────────────────────────────────
    -- Buy: reserve quote asset (price * quantity)
    -- Sell: reserve base asset (quantity)
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

    -- Get ledger account IDs for reservation
    SELECT ledger_account_id INTO v_trading_acct_id
    FROM ledger.accounts
    WHERE trading_account_id = p_account_id
      AND asset_id = v_reserve_asset_id
      AND account_type = 'trading';

    SELECT ledger_account_id INTO v_reservation_acct_id
    FROM ledger.accounts
    WHERE trading_account_id = p_account_id
      AND asset_id = v_reserve_asset_id
      AND account_type = 'reservation';

    -- Post reservation: move from trading to reservation
    PERFORM ledger.post_transfer(
        p_tenant_id, 'reservation', 'order', NULL,
        'Reserve for ' || p_side || ' order',
        v_trading_acct_id, v_reservation_acct_id,
        v_reserve_asset_id, v_reserve_amount
    );

    -- ─── Assign priority sequence ───────────────────────────────────────
    UPDATE core.markets
    SET next_priority_seq = next_priority_seq + 1
    WHERE market_id = p_market_id
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

    -- Record acceptance event
    INSERT INTO trading.order_events (order_id, event_type, remaining_after, details)
    VALUES (v_order_id, 'accepted', p_quantity,
            jsonb_build_object('price', p_limit_price, 'quantity', p_quantity, 'side', p_side));

    v_remaining := p_quantity;

    -- ─── Match against resting orders ───────────────────────────────────
    IF p_side = 'buy' THEN
        -- Match against eligible sells: price <= buy limit, lowest price first
        FOR v_resting IN
            SELECT o.order_id, o.account_id, o.tenant_id, o.limit_price, o.remaining_quantity, o.side
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

            v_fill_qty := LEAST(v_remaining, v_resting.remaining_quantity);
            v_fill_price := v_resting.limit_price;  -- resting order's price

            -- Create trade
            INSERT INTO trading.trades (
                market_id, buy_order_id, buy_account_id,
                sell_order_id, sell_account_id, price, quantity
            ) VALUES (
                p_market_id, v_order_id, p_account_id,
                v_resting.order_id, v_resting.account_id, v_fill_price, v_fill_qty
            ) RETURNING trading.trades.trade_id INTO v_trade_id;

            -- Update resting order
            UPDATE trading.orders
            SET remaining_quantity = remaining_quantity - v_fill_qty,
                status = CASE
                    WHEN remaining_quantity - v_fill_qty = 0 THEN 'filled'
                    ELSE 'partially_filled'
                END,
                updated_at = now()
            WHERE trading.orders.order_id = v_resting.order_id;

            -- Update incoming order remaining
            v_remaining := v_remaining - v_fill_qty;

            -- Record events for both sides
            INSERT INTO trading.order_events
                (order_id, event_type, trade_id, fill_quantity, fill_price, remaining_after)
            VALUES
                (v_resting.order_id,
                 CASE WHEN v_resting.remaining_quantity - v_fill_qty = 0
                      THEN 'filled' ELSE 'partially_filled' END,
                 v_trade_id, v_fill_qty, v_fill_price,
                 v_resting.remaining_quantity - v_fill_qty),
                (v_order_id,
                 CASE WHEN v_remaining = 0 THEN 'filled' ELSE 'partially_filled' END,
                 v_trade_id, v_fill_qty, v_fill_price, v_remaining);

            -- ─── Settlement: move assets between accounts ───────────────
            -- Ensure counterparty ledger accounts exist
            PERFORM ledger.ensure_accounts(v_resting.tenant_id, v_resting.account_id, v_base_asset_id);
            PERFORM ledger.ensure_accounts(v_resting.tenant_id, v_resting.account_id, v_quote_asset_id);

            -- Buyer pays quote asset: release from buyer reservation → seller trading
            SELECT ledger_account_id INTO v_counter_trading_acct_id
            FROM ledger.accounts
            WHERE trading_account_id = v_resting.account_id
              AND asset_id = v_quote_asset_id
              AND account_type = 'trading';

            PERFORM ledger.post_transfer(
                p_tenant_id, 'trade_settlement', 'trade', v_trade_id,
                'Buyer pays quote',
                v_reservation_acct_id, v_counter_trading_acct_id,
                v_quote_asset_id, v_fill_price * v_fill_qty
            );

            -- Seller delivers base asset: release from seller reservation → buyer trading
            SELECT ledger_account_id INTO v_counter_reservation_acct_id
            FROM ledger.accounts
            WHERE trading_account_id = v_resting.account_id
              AND asset_id = v_base_asset_id
              AND account_type = 'reservation';

            SELECT ledger_account_id INTO v_counter_trading_acct_id
            FROM ledger.accounts
            WHERE trading_account_id = p_account_id
              AND asset_id = v_base_asset_id
              AND account_type = 'trading';

            PERFORM ledger.post_transfer(
                v_resting.tenant_id, 'trade_settlement', 'trade', v_trade_id,
                'Seller delivers base',
                v_counter_reservation_acct_id, v_counter_trading_acct_id,
                v_base_asset_id, v_fill_qty
            );

            v_trades_count := v_trades_count + 1;
        END LOOP;

        -- Release excess reservation if partially filled at better prices
        -- Buy reserved at limit_price * quantity, but may have filled at lower prices
        DECLARE
            v_total_quote_spent NUMERIC(30, 18);
            v_excess NUMERIC(30, 18);
        BEGIN
            SELECT COALESCE(SUM(t.price * t.quantity), 0)
            INTO v_total_quote_spent
            FROM trading.trades t
            WHERE t.buy_order_id = v_order_id;

            IF v_remaining = 0 THEN
                -- Fully filled: release any excess (filled at better prices than limit)
                v_excess := v_reserve_amount - v_total_quote_spent;
                IF v_excess > 0 THEN
                    PERFORM ledger.post_transfer(
                        p_tenant_id, 'release', 'order', v_order_id,
                        'Release excess reservation after full fill',
                        v_reservation_acct_id, v_trading_acct_id,
                        v_reserve_asset_id, v_excess
                    );
                END IF;
            END IF;
        END;

    ELSE  -- p_side = 'sell'
        -- Match against eligible buys: price >= sell limit, highest price first
        FOR v_resting IN
            SELECT o.order_id, o.account_id, o.tenant_id, o.limit_price, o.remaining_quantity, o.side
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

            v_fill_qty := LEAST(v_remaining, v_resting.remaining_quantity);
            v_fill_price := v_resting.limit_price;  -- resting order's price

            -- Create trade
            INSERT INTO trading.trades (
                market_id, buy_order_id, buy_account_id,
                sell_order_id, sell_account_id, price, quantity
            ) VALUES (
                p_market_id, v_resting.order_id, v_resting.account_id,
                v_order_id, p_account_id, v_fill_price, v_fill_qty
            ) RETURNING trading.trades.trade_id INTO v_trade_id;

            -- Update resting order
            UPDATE trading.orders
            SET remaining_quantity = remaining_quantity - v_fill_qty,
                status = CASE
                    WHEN remaining_quantity - v_fill_qty = 0 THEN 'filled'
                    ELSE 'partially_filled'
                END,
                updated_at = now()
            WHERE trading.orders.order_id = v_resting.order_id;

            v_remaining := v_remaining - v_fill_qty;

            -- Record events
            INSERT INTO trading.order_events
                (order_id, event_type, trade_id, fill_quantity, fill_price, remaining_after)
            VALUES
                (v_resting.order_id,
                 CASE WHEN v_resting.remaining_quantity - v_fill_qty = 0
                      THEN 'filled' ELSE 'partially_filled' END,
                 v_trade_id, v_fill_qty, v_fill_price,
                 v_resting.remaining_quantity - v_fill_qty),
                (v_order_id,
                 CASE WHEN v_remaining = 0 THEN 'filled' ELSE 'partially_filled' END,
                 v_trade_id, v_fill_qty, v_fill_price, v_remaining);

            -- ─── Settlement ─────────────────────────────────────────────
            PERFORM ledger.ensure_accounts(v_resting.tenant_id, v_resting.account_id, v_base_asset_id);
            PERFORM ledger.ensure_accounts(v_resting.tenant_id, v_resting.account_id, v_quote_asset_id);

            -- Buyer (resting) pays quote: from buyer reservation → seller trading
            SELECT ledger_account_id INTO v_counter_reservation_acct_id
            FROM ledger.accounts
            WHERE trading_account_id = v_resting.account_id
              AND asset_id = v_quote_asset_id
              AND account_type = 'reservation';

            SELECT ledger_account_id INTO v_counter_trading_acct_id
            FROM ledger.accounts
            WHERE trading_account_id = p_account_id
              AND asset_id = v_quote_asset_id
              AND account_type = 'trading';

            PERFORM ledger.post_transfer(
                v_resting.tenant_id, 'trade_settlement', 'trade', v_trade_id,
                'Buyer pays quote',
                v_counter_reservation_acct_id, v_counter_trading_acct_id,
                v_quote_asset_id, v_fill_price * v_fill_qty
            );

            -- Seller delivers base: from seller reservation → buyer trading
            SELECT ledger_account_id INTO v_counter_trading_acct_id
            FROM ledger.accounts
            WHERE trading_account_id = v_resting.account_id
              AND asset_id = v_base_asset_id
              AND account_type = 'trading';

            PERFORM ledger.post_transfer(
                p_tenant_id, 'trade_settlement', 'trade', v_trade_id,
                'Seller delivers base',
                v_reservation_acct_id, v_counter_trading_acct_id,
                v_base_asset_id, v_fill_qty
            );

            -- Release excess quote reservation for resting buyer
            -- (resting buyer reserved at their limit, but the fill price IS their limit for buys)
            -- For resting buy that's fully filled, release any remaining reservation
            IF v_resting.remaining_quantity - v_fill_qty = 0 THEN
                DECLARE
                    v_resting_total_spent NUMERIC(30, 18);
                    v_resting_reserved NUMERIC(30, 18);
                    v_resting_excess NUMERIC(30, 18);
                    v_resting_res_acct UUID;
                    v_resting_trd_acct UUID;
                BEGIN
                    -- Calculate total quote spent by this resting buy order
                    SELECT COALESCE(SUM(t.price * t.quantity), 0)
                    INTO v_resting_total_spent
                    FROM trading.trades t
                    WHERE t.buy_order_id = v_resting.order_id;

                    -- Resting buy originally reserved: limit_price * original_quantity
                    SELECT o.limit_price * o.original_quantity INTO v_resting_reserved
                    FROM trading.orders o WHERE o.order_id = v_resting.order_id;

                    v_resting_excess := v_resting_reserved - v_resting_total_spent;

                    IF v_resting_excess > 0 THEN
                        SELECT ledger_account_id INTO v_resting_res_acct
                        FROM ledger.accounts
                        WHERE trading_account_id = v_resting.account_id
                          AND asset_id = v_quote_asset_id
                          AND account_type = 'reservation';

                        SELECT ledger_account_id INTO v_resting_trd_acct
                        FROM ledger.accounts
                        WHERE trading_account_id = v_resting.account_id
                          AND asset_id = v_quote_asset_id
                          AND account_type = 'trading';

                        PERFORM ledger.post_transfer(
                            v_resting.tenant_id, 'release', 'order', v_resting.order_id,
                            'Release excess after full fill',
                            v_resting_res_acct, v_resting_trd_acct,
                            v_quote_asset_id, v_resting_excess
                        );
                    END IF;
                END;
            END IF;

            v_trades_count := v_trades_count + 1;
        END LOOP;

        -- Release excess base reservation if fully filled
        IF v_remaining = 0 THEN
            -- Sell orders reserve exact quantity, so no excess unless partial cancel
            NULL;
        END IF;
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

-- =============================================================================
-- Cancel an order
-- =============================================================================

CREATE OR REPLACE FUNCTION trading.cancel_order(
    p_tenant_id UUID,
    p_order_id UUID
) RETURNS TABLE (
    order_id UUID,
    status TEXT,
    released_quantity NUMERIC(30, 18),
    message TEXT
) AS $$
DECLARE
    v_order RECORD;
    v_market RECORD;
    v_release_asset_id UUID;
    v_release_amount NUMERIC(30, 18);
    v_reservation_acct_id UUID;
    v_trading_acct_id UUID;
BEGIN
    -- Lock the market first (same lock hierarchy as place_order)
    SELECT o.*, m.base_asset_id, m.quote_asset_id
    INTO v_order
    FROM trading.orders o
    JOIN core.markets m ON o.market_id = m.market_id
    WHERE o.order_id = p_order_id
      AND o.tenant_id = p_tenant_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT p_order_id, 'not_found'::TEXT, 0::NUMERIC(30,18),
            'Order not found'::TEXT;
        RETURN;
    END IF;

    -- Lock the market for serialization
    PERFORM 1 FROM core.markets WHERE market_id = v_order.market_id FOR UPDATE;

    -- Re-read order under lock
    SELECT * INTO v_order
    FROM trading.orders o
    WHERE o.order_id = p_order_id
    FOR UPDATE;

    IF v_order.status NOT IN ('open', 'partially_filled') THEN
        RETURN QUERY SELECT p_order_id, v_order.status, 0::NUMERIC(30,18),
            ('Cannot cancel order in status: ' || v_order.status)::TEXT;
        RETURN;
    END IF;

    -- Determine how much to release
    IF v_order.side = 'buy' THEN
        v_release_asset_id := (SELECT quote_asset_id FROM core.markets WHERE market_id = v_order.market_id);
        v_release_amount := v_order.limit_price * v_order.remaining_quantity;
    ELSE
        v_release_asset_id := (SELECT base_asset_id FROM core.markets WHERE market_id = v_order.market_id);
        v_release_amount := v_order.remaining_quantity;
    END IF;

    -- Update order
    UPDATE trading.orders
    SET status = 'cancelled',
        cancelled_at = now(),
        updated_at = now()
    WHERE trading.orders.order_id = p_order_id;

    -- Record event
    INSERT INTO trading.order_events (order_id, event_type, remaining_after)
    VALUES (p_order_id, 'cancelled', v_order.remaining_quantity);

    -- Release reservation
    IF v_release_amount > 0 THEN
        SELECT ledger_account_id INTO v_reservation_acct_id
        FROM ledger.accounts
        WHERE trading_account_id = v_order.account_id
          AND asset_id = v_release_asset_id
          AND account_type = 'reservation';

        SELECT ledger_account_id INTO v_trading_acct_id
        FROM ledger.accounts
        WHERE trading_account_id = v_order.account_id
          AND asset_id = v_release_asset_id
          AND account_type = 'trading';

        IF v_reservation_acct_id IS NOT NULL AND v_trading_acct_id IS NOT NULL THEN
            PERFORM ledger.post_transfer(
                p_tenant_id, 'release', 'order', p_order_id,
                'Release reservation on cancel',
                v_reservation_acct_id, v_trading_acct_id,
                v_release_asset_id, v_release_amount
            );
        END IF;
    END IF;

    RETURN QUERY SELECT p_order_id, 'cancelled'::TEXT, v_order.remaining_quantity,
        'Order cancelled'::TEXT;
END;
$$ LANGUAGE plpgsql;
