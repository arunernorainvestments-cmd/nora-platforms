-- ─────────────────────────────────────────────────────────────────────────────
-- 082 — Card Marketplace (Redesign Doc 1)
--
-- Secondary market for likeness cards. Buy-now listings only (MVP). One active
-- listing per card at any time, enforced via an EXCLUDE constraint.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE card_marketplace_listings (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  card_id                     UUID NOT NULL REFERENCES likeness_cards(id),
  seller_user_id              UUID NOT NULL REFERENCES auth.users(id),
  offering_id                 UUID NOT NULL REFERENCES likeness_offerings(id),
  creator_id                  UUID NOT NULL REFERENCES auth.users(id),

  asking_price_usd_cents      BIGINT NOT NULL CHECK (asking_price_usd_cents > 0),
  status                      TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'sold', 'cancelled')),

  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  sold_at                     TIMESTAMPTZ,

  CONSTRAINT one_active_listing_per_card EXCLUDE (card_id WITH =)
    WHERE (status = 'active')
);

CREATE TABLE card_marketplace_sales (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id                  UUID NOT NULL REFERENCES card_marketplace_listings(id),
  card_id                     UUID NOT NULL REFERENCES likeness_cards(id),
  buyer_user_id               UUID NOT NULL REFERENCES auth.users(id),
  seller_user_id              UUID NOT NULL REFERENCES auth.users(id),
  creator_id                  UUID NOT NULL REFERENCES auth.users(id),

  price_paid_usd_cents        BIGINT NOT NULL,
  platform_fee_usd_cents      BIGINT NOT NULL DEFAULT 0,
  seller_proceeds_usd_cents   BIGINT NOT NULL DEFAULT 0,

  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,
  stripe_payment_intent_id    TEXT,
  completed_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX listings_creator_idx  ON card_marketplace_listings (creator_id, status);
CREATE INDEX listings_seller_idx   ON card_marketplace_listings (seller_user_id, status);
CREATE INDEX sales_buyer_idx       ON card_marketplace_sales (buyer_user_id);
CREATE INDEX sales_seller_idx      ON card_marketplace_sales (seller_user_id);

-- ── card_marketplace_purchase RPC ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION card_marketplace_purchase(
  p_listing_id UUID,
  p_buyer_user_id UUID
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_listing     card_marketplace_listings%ROWTYPE;
  v_fee         BIGINT;
  v_proceeds    BIGINT;
  v_sale_id     UUID;
BEGIN
  SELECT * INTO v_listing
  FROM card_marketplace_listings
  WHERE id = p_listing_id AND status = 'active'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Listing not found or already sold';
  END IF;

  IF v_listing.seller_user_id = p_buyer_user_id THEN
    RAISE EXCEPTION 'Cannot purchase your own listing';
  END IF;

  v_fee      := ROUND(v_listing.asking_price_usd_cents * 0.05);
  v_proceeds := v_listing.asking_price_usd_cents - v_fee;

  IF v_listing.is_simulated THEN
    UPDATE sim_usd_balances
    SET balance_usd_cents = balance_usd_cents - v_listing.asking_price_usd_cents,
        updated_at = NOW()
    WHERE user_id = p_buyer_user_id
      AND balance_usd_cents >= v_listing.asking_price_usd_cents;
    IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient sim balance'; END IF;

    UPDATE sim_usd_balances
    SET balance_usd_cents = balance_usd_cents + v_proceeds,
        lifetime_returned_cents = lifetime_returned_cents + v_proceeds,
        updated_at = NOW()
    WHERE user_id = v_listing.seller_user_id;

    -- Buyer + seller ledger rows
    INSERT INTO sim_usd_transactions (
      user_id, type, amount_usd_cents, reference_id, description
    ) VALUES (
      p_buyer_user_id,
      'card_purchase',
      -v_listing.asking_price_usd_cents,
      p_listing_id,
      'Marketplace card purchase'
    );

    INSERT INTO sim_usd_transactions (
      user_id, type, amount_usd_cents, reference_id, description
    ) VALUES (
      v_listing.seller_user_id,
      'card_sale',
      v_proceeds,
      p_listing_id,
      'Marketplace card sale (95% of price)'
    );
  END IF;

  UPDATE card_marketplace_listings
  SET status = 'sold', sold_at = NOW()
  WHERE id = p_listing_id;

  INSERT INTO likeness_card_transfers (
    card_id, offering_id, creator_id,
    from_user_id, to_user_id,
    usd_cents_paid, transfer_type, is_simulated
  ) VALUES (
    v_listing.card_id, v_listing.offering_id, v_listing.creator_id,
    v_listing.seller_user_id, p_buyer_user_id,
    v_listing.asking_price_usd_cents, 'marketplace_sale',
    v_listing.is_simulated
  );

  INSERT INTO card_marketplace_sales (
    listing_id, card_id, buyer_user_id, seller_user_id, creator_id,
    price_paid_usd_cents, platform_fee_usd_cents, seller_proceeds_usd_cents,
    is_simulated
  ) VALUES (
    p_listing_id, v_listing.card_id, p_buyer_user_id,
    v_listing.seller_user_id, v_listing.creator_id,
    v_listing.asking_price_usd_cents, v_fee, v_proceeds,
    v_listing.is_simulated
  ) RETURNING id INTO v_sale_id;

  RETURN v_sale_id;
END;
$$;

-- ── RLS ─────────────────────────────────────────────────────────────────────
ALTER TABLE card_marketplace_listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE card_marketplace_sales    ENABLE ROW LEVEL SECURITY;

CREATE POLICY "listings_public_read_active"
  ON card_marketplace_listings FOR SELECT
  USING (status = 'active' OR auth.uid() = seller_user_id);

CREATE POLICY "listings_seller_cancel"
  ON card_marketplace_listings FOR UPDATE
  USING (auth.uid() = seller_user_id);

CREATE POLICY "sales_participant_read"
  ON card_marketplace_sales FOR SELECT
  USING (auth.uid() = buyer_user_id OR auth.uid() = seller_user_id);
