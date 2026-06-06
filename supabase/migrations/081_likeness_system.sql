-- ─────────────────────────────────────────────────────────────────────────────
-- 081 — Likeness Offerings & Cards (Redesign Doc 1)
--
-- Replaces the Campaigns royalty framework. Collectible character cards grant
-- Battle eligibility for a creator and a proportional share of match rewards
-- when that character plays. Language MUST be collectible/game-asset throughout
-- — never "investment", "return", "yield", "dividend", "revenue share".
--
-- Also extends sim_usd_transactions.type CHECK to allow 'card_purchase' and
-- 'card_sale'. The doc missed this; without the extension the likeness_mint_card
-- RPC fails on INSERT into sim_usd_transactions.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Extend sim_usd_transactions.type CHECK ──────────────────────────────────
ALTER TABLE public.sim_usd_transactions
  DROP CONSTRAINT IF EXISTS sim_usd_transactions_type_check;

ALTER TABLE public.sim_usd_transactions
  ADD CONSTRAINT sim_usd_transactions_type_check CHECK (type IN (
    'seed','investment','refund','distribution','secondary_purchase',
    'secondary_sale','fee','governance_release',
    -- New types from Likeness Cards:
    'card_purchase','card_sale'
  ));

-- ── likeness_offerings ──────────────────────────────────────────────────────
CREATE TABLE likeness_offerings (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id                  UUID NOT NULL REFERENCES auth.users(id),

  character_name              TEXT NOT NULL,
  character_image_url         TEXT,
  archetype                   TEXT NOT NULL
    CHECK (archetype IN (
      'athlete','musician','business','comedian','artist',
      'gamer','influencer','scientist','politician','actor',
      'healthcare','performer','educator','religion'
    )),

  total_pct_offered           DECIMAL(10,6) NOT NULL
    CHECK (total_pct_offered > 0 AND total_pct_offered <= 75),
  card_print_run              INTEGER NOT NULL
    CHECK (card_print_run BETWEEN 1 AND 10000),
  pct_per_card                DECIMAL(10,6) NOT NULL,

  price_per_card_usd_cents    BIGINT NOT NULL
    CHECK (price_per_card_usd_cents >= 100),

  mode                        TEXT NOT NULL DEFAULT 'simulated'
    CHECK (mode IN ('simulated', 'live')),
  status                      TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'active', 'sold_out', 'closed')),

  cards_minted                INTEGER NOT NULL DEFAULT 0
    CHECK (cards_minted >= 0),

  platform_listing_fee_pct    DECIMAL(5,4) NOT NULL DEFAULT 0.1000,

  listed_at                   TIMESTAMPTZ,
  closed_at                   TIMESTAMPTZ,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT pct_per_card_correct CHECK (
    ABS(pct_per_card - (total_pct_offered / card_print_run)) < 0.001
  )
);

CREATE INDEX offerings_creator_idx ON likeness_offerings (creator_id, status);
CREATE INDEX offerings_status_idx  ON likeness_offerings (status);

-- ── likeness_cards ──────────────────────────────────────────────────────────
-- card_number rarity tiers:
--   #1       = legendary
--   #2–10    = rare
--   #11+     = standard
CREATE TABLE likeness_cards (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  offering_id                 UUID NOT NULL REFERENCES likeness_offerings(id),
  creator_id                  UUID NOT NULL REFERENCES auth.users(id),
  card_number                 INTEGER NOT NULL,
  royalty_pct                 DECIMAL(10,6) NOT NULL,

  rarity                      TEXT NOT NULL
    GENERATED ALWAYS AS (
      CASE
        WHEN card_number = 1 THEN 'legendary'
        WHEN card_number <= 10 THEN 'rare'
        ELSE 'standard'
      END
    ) STORED,

  current_owner_id            UUID REFERENCES auth.users(id),

  is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
  minted_at                   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (offering_id, card_number)
);

CREATE INDEX cards_owner_idx    ON likeness_cards (current_owner_id, is_active);
CREATE INDEX cards_creator_idx  ON likeness_cards (creator_id);
CREATE INDEX cards_offering_idx ON likeness_cards (offering_id);

-- ── likeness_card_transfers (append-only ledger) ────────────────────────────
CREATE TABLE likeness_card_transfers (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  card_id                     UUID NOT NULL REFERENCES likeness_cards(id),
  offering_id                 UUID NOT NULL REFERENCES likeness_offerings(id),
  creator_id                  UUID NOT NULL REFERENCES auth.users(id),

  from_user_id                UUID REFERENCES auth.users(id),
  to_user_id                  UUID NOT NULL REFERENCES auth.users(id),

  usd_cents_paid              BIGINT NOT NULL DEFAULT 0,
  transfer_type               TEXT NOT NULL CHECK (transfer_type IN (
    'mint',
    'marketplace_sale',
    'gift',
    'platform_correction'
  )),

  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,
  stripe_payment_intent_id    TEXT,
  notes                       TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX transfers_card_idx     ON likeness_card_transfers (card_id, created_at DESC);
CREATE INDEX transfers_to_user_idx  ON likeness_card_transfers (to_user_id, created_at DESC);
CREATE INDEX transfers_creator_idx  ON likeness_card_transfers (creator_id);

-- ── current_owner update trigger ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION update_card_owner_on_transfer()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE likeness_cards
  SET current_owner_id = NEW.to_user_id
  WHERE id = NEW.card_id;
  RETURN NEW;
END;
$$;

CREATE TRIGGER after_card_transfer
  AFTER INSERT ON likeness_card_transfers
  FOR EACH ROW EXECUTE FUNCTION update_card_owner_on_transfer();

-- ── likeness_mint_card RPC ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION likeness_mint_card(
  p_offering_id UUID,
  p_buyer_user_id UUID
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_offering      likeness_offerings%ROWTYPE;
  v_card_number   INTEGER;
  v_card_id       UUID;
BEGIN
  SELECT * INTO v_offering
  FROM likeness_offerings
  WHERE id = p_offering_id AND status = 'active'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Offering not found or not active: %', p_offering_id;
  END IF;

  IF v_offering.cards_minted >= v_offering.card_print_run THEN
    RAISE EXCEPTION 'Offering sold out';
  END IF;

  v_card_number := v_offering.cards_minted + 1;

  IF v_offering.mode = 'simulated' THEN
    UPDATE sim_usd_balances
    SET balance_usd_cents = balance_usd_cents - v_offering.price_per_card_usd_cents,
        lifetime_invested_cents = lifetime_invested_cents + v_offering.price_per_card_usd_cents,
        updated_at = NOW()
    WHERE user_id = p_buyer_user_id
      AND balance_usd_cents >= v_offering.price_per_card_usd_cents;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Insufficient sim balance';
    END IF;

    INSERT INTO sim_usd_transactions (
      user_id, type, amount_usd_cents, reference_id, description
    ) VALUES (
      p_buyer_user_id,
      'card_purchase',
      -v_offering.price_per_card_usd_cents,
      p_offering_id,
      'Card #' || v_card_number || ' — ' || v_offering.character_name
    );
  END IF;
  -- Live mode: Stripe payment intent confirmed before calling this RPC.

  INSERT INTO likeness_cards (
    offering_id, creator_id, card_number, royalty_pct, current_owner_id
  ) VALUES (
    p_offering_id,
    v_offering.creator_id,
    v_card_number,
    v_offering.pct_per_card,
    p_buyer_user_id
  ) RETURNING id INTO v_card_id;

  INSERT INTO likeness_card_transfers (
    card_id, offering_id, creator_id,
    from_user_id, to_user_id,
    usd_cents_paid, transfer_type, is_simulated
  ) VALUES (
    v_card_id, p_offering_id, v_offering.creator_id,
    NULL,
    p_buyer_user_id,
    v_offering.price_per_card_usd_cents,
    'mint',
    v_offering.mode = 'simulated'
  );

  UPDATE likeness_offerings
  SET cards_minted = v_card_number,
      status = CASE WHEN v_card_number = card_print_run THEN 'sold_out' ELSE status END
  WHERE id = p_offering_id;

  RETURN v_card_id;
END;
$$;

-- ── RLS ─────────────────────────────────────────────────────────────────────
ALTER TABLE likeness_offerings        ENABLE ROW LEVEL SECURITY;
ALTER TABLE likeness_cards            ENABLE ROW LEVEL SECURITY;
ALTER TABLE likeness_card_transfers   ENABLE ROW LEVEL SECURITY;

-- Public reads on offerings visible to all (active/sold_out only); creator can see drafts.
CREATE POLICY "offerings_public_read"
  ON likeness_offerings FOR SELECT
  USING (status IN ('active', 'sold_out') OR auth.uid() = creator_id);

CREATE POLICY "offerings_creator_write"
  ON likeness_offerings FOR INSERT
  WITH CHECK (auth.uid() = creator_id);

CREATE POLICY "offerings_creator_update"
  ON likeness_offerings FOR UPDATE
  USING (auth.uid() = creator_id);

CREATE POLICY "cards_public_read"
  ON likeness_cards FOR SELECT
  USING (TRUE);

-- Transfers: owner and creator can read; writes only via SECURITY DEFINER RPCs.
CREATE POLICY "transfers_participant_read"
  ON likeness_card_transfers FOR SELECT
  USING (
    auth.uid() = from_user_id
    OR auth.uid() = to_user_id
    OR auth.uid() = creator_id
  );
