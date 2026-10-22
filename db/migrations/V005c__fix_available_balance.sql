-- VerityTick Migration V005c
-- Fix: available_balance was double-counting reservations
--
-- The reservation model moves funds FROM trading TO reservation account.
-- So trading balance already reflects the deduction.
-- available_balance should just return the trading balance directly.

CREATE OR REPLACE FUNCTION ledger.available_balance(
    p_trading_account_id UUID,
    p_asset_id UUID
) RETURNS NUMERIC(30, 18) AS $$
DECLARE
    v_trading_bal NUMERIC(30, 18);
BEGIN
    -- Available = trading balance (reservations already moved out)
    SELECT COALESCE(balance, 0) INTO v_trading_bal
    FROM ledger.accounts
    WHERE trading_account_id = p_trading_account_id
      AND asset_id = p_asset_id
      AND account_type = 'trading';

    RETURN COALESCE(v_trading_bal, 0);
END;
$$ LANGUAGE plpgsql STABLE;
