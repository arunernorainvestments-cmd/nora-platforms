-- Migration 175: Mystery Box — pool + submission + award engine (Collections N6).
--
-- Collections spec (NORA_PLATFORMS_COLLECTIONS_SPEC.md) Phase N6, §1.5 + gate
-- G-MYSTERY. The whole system ships BEHIND A FLAG and is DISABLED in beta:
-- mystery_pool_settings.mode defaults to 'disabled', and both money-moving RPCs
-- RAISE while it is. The beta UI shows the submit button with an explainer and a
-- disabled state (N6 web side); this migration is the backend it will eventually
-- talk to.
--
-- THE LOAD-BEARING RULE (G-COLL / §1.5, structural — not config):
--   Mystery Boxes are NEVER sold, for money or for tokens. There is deliberately
--   NO purchase RPC anywhere in this migration. Boxes arrive only via
--   mystery_box_grant(), which is server-only (REVOKEd from authenticated) and
--   keyed to a gameplay context. A paid randomized pull is the brightest legal
--   line in the spec; the absence of a purchase path is the enforcement.
--
-- REPO-CHECK N6.1 (gameplay hooks) — RESOLVED:
--   No general "events framework" exists in this repo. The concrete hooks that
--   could award a box today are: evaluate-challenges (challenge completion),
--   arena-monday-rollover / arena_spotlight_assignments (Champion Spotlight, the
--   same weekly record mig 174's spotlight_champion oracle reads), and ccg match
--   finish. This migration ships the ENGINE plus a stable context-key vocabulary
--   ('challenge:<id>', 'spotlight:<week>:<user>', 'match:<id>', 'drop:<id>') and
--   wires NO call sites live — grants are unreachable while mode='disabled', so
--   wiring them now would be dead code that looks live. Hook-up is a follow-up
--   that lands WITH the mode flip, per the spec's "grants ship with challenges +
--   spotlight only at first".
--
-- Custody model (why there is no fake "platform owns it" ownership rewrite):
--   A submitted copy behaves EXACTLY like a marketplace escrow — it leaves the
--   submitter's holdings (state 'mystery_pool', already a legal state since mig
--   170) while owner_user_id stays the submitter until a winner claims it. That
--   keeps the mig-170 invariant (quantity == owned-copy count) true by
--   construction and preserves attribution end-to-end. Generic cards have no
--   submitter, so they rest with a dedicated custodian account.

-- ═══════════════════════════════════════════════════════════════════════════════
-- GENERIC CARDS — platform-authored, in-game use only, NEVER marketplace-listable
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.moment_chits
  ADD COLUMN IF NOT EXISTS is_generic BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN public.moment_chits.is_generic IS
  'Platform-authored filler card for the Mystery Pool (N6). Playable in Arena, '
  'never listable on the marketplace — enforced in marketplace_list_chit_internal.';

CREATE INDEX IF NOT EXISTS moment_chits_generic_idx
  ON public.moment_chits (is_generic) WHERE is_generic;

-- ═══════════════════════════════════════════════════════════════════════════════
-- CONFIG — mode flag + per-tier payout/draw weights (founder-set, tune by UPDATE)
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.mystery_pool_settings (
  id              BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
  mode            TEXT NOT NULL DEFAULT 'disabled'
                    CHECK (mode IN ('disabled','sim','live')),
  max_submit_pct  INTEGER NOT NULL DEFAULT 20 CHECK (max_submit_pct BETWEEN 1 AND 100),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO public.mystery_pool_settings (id) VALUES (TRUE)
ON CONFLICT DO NOTHING;

COMMENT ON TABLE public.mystery_pool_settings IS
  'G-MYSTERY gate. mode: disabled (BETA DEFAULT — submission + grants both RAISE) '
  '| sim (sim_usd_balances) | live (blocked until battle_payments_mode allows it). '
  'max_submit_pct caps how much of a collection its minter may sell into the pool.';

CREATE TABLE public.mystery_pool_tier_config (
  tier                 TEXT PRIMARY KEY,
  submit_payout_cents  INTEGER NOT NULL CHECK (submit_payout_cents > 0),
  draw_weight          INTEGER NOT NULL CHECK (draw_weight >= 0),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- PLACEHOLDER rates pending founder sign-off (same posture as platform_fee_config,
-- mig 171). Weights are generic-heavy at the bottom of the ladder: a box should
-- usually be a common card, rarely an S.
INSERT INTO public.mystery_pool_tier_config (tier, submit_payout_cents, draw_weight) VALUES
  ('F',   25, 400),
  ('E',   50, 250),
  ('D',  100, 150),
  ('C',  200,  90),
  ('B',  400,  60),
  ('A',  800,  35),
  ('S', 1600,  15)
ON CONFLICT (tier) DO NOTHING;

ALTER TABLE public.mystery_pool_settings    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mystery_pool_tier_config ENABLE ROW LEVEL SECURITY;
CREATE POLICY "mystery_pool_settings_select_all" ON public.mystery_pool_settings
  FOR SELECT USING (TRUE);
CREATE POLICY "mystery_pool_tier_config_select_all" ON public.mystery_pool_tier_config
  FOR SELECT USING (TRUE);
-- No client write policies anywhere: config is migrations / service role only.

CREATE OR REPLACE FUNCTION public.mystery_pool_mode()
RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT mode FROM public.mystery_pool_settings WHERE id;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- CUSTODIAN — holds generic-card copies (they have no submitter to rest with).
-- Flagged is_test_account so Hard Rule 15 sweeps keep it out of every ranking and
-- discovery query; it is a custody bucket, never a player.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT id INTO v_id FROM auth.users WHERE email = 'mystery-pool@noraplatforms.com';
  IF v_id IS NULL THEN
    v_id := gen_random_uuid();
    INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at, raw_user_meta_data)
    VALUES (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'mystery-pool@noraplatforms.com', '', NOW(), NOW(), NOW(),
            '{"full_name":"NORA Mystery Pool"}');
  END IF;
  UPDATE public.profiles SET is_test_account = TRUE WHERE id = v_id;
END $$;

CREATE OR REPLACE FUNCTION public.mystery_pool_custodian()
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT id FROM auth.users WHERE email = 'mystery-pool@noraplatforms.com';
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- LEDGER VOCABULARY — two new reasons on the mig-117 choke point.
-- The list must carry the WHOLE vocabulary forward: this constraint is rewritten
-- wholesale by every migration that extends it (117 → 142 → 154 → 171 → 172 → here),
-- so copying the previous migration's list is not enough — 172 added
-- 'collection_sale' after 171, and omitting it fails the re-add against live rows.
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.chit_acquisition_ledger
  DROP CONSTRAINT IF EXISTS chit_acquisition_ledger_reason_check;
ALTER TABLE public.chit_acquisition_ledger
  ADD CONSTRAINT chit_acquisition_ledger_reason_check CHECK (reason IN (
    'mint','pack_purchase','barter_in','barter_out','gift','event','platform_correction',
    'wager_escrow','wager_return','wager_won','swap_retired',
    'marketplace_escrow','marketplace_return','marketplace_purchase',
    'collection_mint','collection_sale',
    'mystery_pool_submit','mystery_box_grant'
  ));

-- ═══════════════════════════════════════════════════════════════════════════════
-- COPY MACHINERY — extend the mig-170 trigger with the two pool legs.
-- Body is mig 170's verbatim except the two marked branches; the whole function is
-- restated because CREATE OR REPLACE cannot patch a fragment.
--   negative 'mystery_pool_submit' → lowest owned serials pinned 'mystery_pool'
--   positive 'mystery_box_grant'   → claim THE pool copy named by reference_id
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.apply_chit_ledger_to_copies()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_n       INTEGER;
  v_supply  INTEGER;
  v_state   TEXT;
  v_copy    public.chit_copies%ROWTYPE;
  v_moved   INTEGER := 0;
  v_serial  INTEGER;
  i         INTEGER;
BEGIN
  SELECT total_supply INTO v_supply
  FROM public.moment_chits WHERE id = NEW.chit_id FOR UPDATE;
  IF v_supply IS NULL THEN
    RAISE EXCEPTION 'chit_copies machinery: unknown chit %', NEW.chit_id;
  END IF;

  IF NEW.quantity_delta < 0 THEN
    v_n := -NEW.quantity_delta;
    v_state := CASE NEW.reason
      WHEN 'marketplace_escrow'   THEN 'listed_escrow'
      WHEN 'wager_escrow'         THEN 'wager_escrow'
      WHEN 'mystery_pool_submit'  THEN 'mystery_pool'   -- N6
      ELSE 'released'
    END;

    FOR v_copy IN
      SELECT * FROM public.chit_copies
      WHERE chit_id = NEW.chit_id AND owner_user_id = NEW.user_id AND state = 'owned'
      ORDER BY serial_number
      LIMIT v_n
      FOR UPDATE
    LOOP
      UPDATE public.chit_copies
      SET state       = v_state,
          escrow_ref  = CASE WHEN v_state = 'released' THEN NULL ELSE NEW.reference_id END,
          transit_ref = CASE WHEN v_state = 'released' THEN NEW.reference_id ELSE NULL END,
          updated_at  = NOW()
      WHERE id = v_copy.id;
      v_moved := v_moved + 1;
    END LOOP;

    IF v_moved < v_n THEN
      RAISE EXCEPTION 'chit_copies machinery: user % holds % owned copies of chit %, needed %',
        NEW.user_id, v_moved, NEW.chit_id, v_n;
    END IF;

  ELSE
    v_n := NEW.quantity_delta;

    FOR i IN 1..v_n LOOP
      v_copy := NULL;

      IF NEW.reason = 'marketplace_purchase' THEN
        SELECT * INTO v_copy FROM public.chit_copies
        WHERE chit_id = NEW.chit_id AND state = 'listed_escrow' AND escrow_ref = NEW.reference_id
        ORDER BY serial_number LIMIT 1 FOR UPDATE;

      ELSIF NEW.reason = 'marketplace_return' THEN
        SELECT * INTO v_copy FROM public.chit_copies
        WHERE chit_id = NEW.chit_id AND state = 'listed_escrow' AND escrow_ref = NEW.reference_id
          AND owner_user_id = NEW.user_id
        ORDER BY serial_number LIMIT 1 FOR UPDATE;

      ELSIF NEW.reason = 'wager_won' THEN
        SELECT * INTO v_copy FROM public.chit_copies
        WHERE chit_id = NEW.chit_id AND state = 'wager_escrow' AND escrow_ref = NEW.reference_id
          AND owner_user_id IS NOT DISTINCT FROM NEW.counterparty_user_id
        ORDER BY serial_number LIMIT 1 FOR UPDATE;

      ELSIF NEW.reason = 'wager_return' THEN
        SELECT * INTO v_copy FROM public.chit_copies
        WHERE chit_id = NEW.chit_id AND state = 'wager_escrow' AND escrow_ref = NEW.reference_id
          AND owner_user_id = NEW.user_id
        ORDER BY serial_number LIMIT 1 FOR UPDATE;

      -- N6: the award engine names the exact copy it drew (reference_id = copy id),
      -- so a grant can never quietly hand out a different serial than the one the
      -- grant ledger recorded.
      ELSIF NEW.reason = 'mystery_box_grant' THEN
        SELECT * INTO v_copy FROM public.chit_copies
        WHERE id = NEW.reference_id AND chit_id = NEW.chit_id AND state = 'mystery_pool'
        FOR UPDATE;

      ELSIF NEW.reason IN ('mint','collection_mint') THEN
        NULL;  -- create-only below

      ELSE
        SELECT * INTO v_copy FROM public.chit_copies
        WHERE chit_id = NEW.chit_id AND state = 'released'
          AND transit_ref IS NOT DISTINCT FROM NEW.reference_id
          AND (NEW.counterparty_user_id IS NULL OR owner_user_id = NEW.counterparty_user_id)
        ORDER BY serial_number LIMIT 1 FOR UPDATE;
        IF v_copy.id IS NULL THEN
          SELECT * INTO v_copy FROM public.chit_copies
          WHERE chit_id = NEW.chit_id AND state = 'released'
            AND transit_ref IS NOT DISTINCT FROM NEW.reference_id
          ORDER BY serial_number LIMIT 1 FOR UPDATE;
        END IF;
        IF v_copy.id IS NULL THEN
          SELECT * INTO v_copy FROM public.chit_copies
          WHERE chit_id = NEW.chit_id AND state = 'released'
          ORDER BY serial_number LIMIT 1 FOR UPDATE;
        END IF;
      END IF;

      IF v_copy.id IS NOT NULL THEN
        UPDATE public.chit_copies
        SET owner_user_id = NEW.user_id, state = 'owned',
            escrow_ref = NULL, transit_ref = NULL, updated_at = NOW()
        WHERE id = v_copy.id;
        IF v_copy.owner_user_id IS DISTINCT FROM NEW.user_id THEN
          INSERT INTO public.chit_copy_transfers
            (copy_id, chit_id, serial_number, from_user_id, to_user_id, reason, reference_id)
          VALUES
            (v_copy.id, NEW.chit_id, v_copy.serial_number,
             v_copy.owner_user_id, NEW.user_id, NEW.reason, NEW.reference_id);
        END IF;

      ELSIF NEW.reason IN ('marketplace_purchase','marketplace_return','wager_won',
                           'wager_return','mystery_box_grant') THEN
        -- a pinned claim MUST find its copy — anything else is corruption
        RAISE EXCEPTION 'chit_copies machinery: no escrowed copy for % (chit %, ref %)',
          NEW.reason, NEW.chit_id, NEW.reference_id;

      ELSE
        SELECT COALESCE(MAX(serial_number), 0) + 1 INTO v_serial
        FROM public.chit_copies WHERE chit_id = NEW.chit_id;
        IF v_serial > v_supply THEN
          RAISE EXCEPTION 'chit_copies machinery: supply exhausted for chit % (% of %)',
            NEW.chit_id, v_serial, v_supply;
        END IF;
        INSERT INTO public.chit_copies
          (chit_id, serial_number, total_supply, owner_user_id, state)
        VALUES (NEW.chit_id, v_serial, v_supply, NEW.user_id, 'owned')
        RETURNING * INTO v_copy;
        INSERT INTO public.chit_copy_transfers
          (copy_id, chit_id, serial_number, from_user_id, to_user_id, reason, reference_id)
        VALUES
          (v_copy.id, NEW.chit_id, v_serial, NULL, NEW.user_id, NEW.reason, NEW.reference_id);
      END IF;
    END LOOP;
  END IF;

  RETURN NEW;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- LEDGERS — both append-only (governance: INSERT-only, never UPDATE)
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.mystery_pool_submissions (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  collection_id  UUID NOT NULL REFERENCES public.collections(id),
  chit_id        UUID NOT NULL REFERENCES public.moment_chits(id),
  user_id        UUID NOT NULL REFERENCES auth.users(id),
  copies         INTEGER NOT NULL CHECK (copies > 0),
  tier_snapshot  TEXT NOT NULL,
  payout_cents   INTEGER NOT NULL CHECK (payout_cents > 0),
  mode_snapshot  TEXT NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX mystery_pool_submissions_user_idx ON public.mystery_pool_submissions (user_id, created_at DESC);
CREATE INDEX mystery_pool_submissions_coll_idx ON public.mystery_pool_submissions (collection_id);

CREATE TABLE public.mystery_box_grants (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id),
  -- one win = one box: the gameplay context is the idempotency key
  context_key  TEXT NOT NULL UNIQUE,
  copy_id      UUID NOT NULL REFERENCES public.chit_copies(id),
  chit_id      UUID NOT NULL REFERENCES public.moment_chits(id),
  tier         TEXT NOT NULL,
  was_generic  BOOLEAN NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX mystery_box_grants_user_idx ON public.mystery_box_grants (user_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.mystery_ledger_block_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only (no UPDATE/DELETE)', TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER mystery_pool_submissions_no_mutation
  BEFORE UPDATE OR DELETE ON public.mystery_pool_submissions
  FOR EACH ROW EXECUTE FUNCTION public.mystery_ledger_block_mutation();
CREATE TRIGGER mystery_box_grants_no_mutation
  BEFORE UPDATE OR DELETE ON public.mystery_box_grants
  FOR EACH ROW EXECUTE FUNCTION public.mystery_ledger_block_mutation();

ALTER TABLE public.mystery_pool_submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mystery_box_grants       ENABLE ROW LEVEL SECURITY;

CREATE POLICY "mystery_pool_submissions_select_own" ON public.mystery_pool_submissions
  FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "mystery_box_grants_select_own" ON public.mystery_box_grants
  FOR SELECT USING (auth.uid() = user_id);
-- No client INSERT/UPDATE policies: every write goes through the RPCs below.

-- ═══════════════════════════════════════════════════════════════════════════════
-- GENERIC CARD AUTHORING — mint to the custodian, then rest in the pool
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.mystery_pool_add_generic(
  p_name TEXT, p_family TEXT, p_tier TEXT, p_copies INTEGER
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_chit  UUID;
  v_cust  UUID := public.mystery_pool_custodian();
  v_sub   UUID := gen_random_uuid();
BEGIN
  IF v_cust IS NULL THEN RAISE EXCEPTION 'mystery pool custodian account is missing'; END IF;
  IF p_copies < 1 OR p_copies > 1000 THEN RAISE EXCEPTION 'copies must be 1..1000'; END IF;

  v_chit := public.create_moment_chit(p_name, p_family, 'creature', p_tier);
  UPDATE public.moment_chits
  SET finalized_at = NOW(), original_minter_handle = '@nora',
      source_platform = 'youtube', is_generic = TRUE
  WHERE id = v_chit;

  -- supply is fixed at mint; this is a sanctioned writer (mig 170 flag protocol)
  PERFORM set_config('nora.allow_supply_set', 'on', TRUE);
  UPDATE public.moment_chits SET total_supply = p_copies WHERE id = v_chit;
  PERFORM set_config('nora.allow_supply_set', 'off', TRUE);

  PERFORM public.chit_grant(v_cust, v_chit, p_copies, 'mint');
  PERFORM public.chit_grant(v_cust, v_chit, -p_copies, 'mystery_pool_submit', v_sub);
  RETURN v_chit;
END;
$$;

REVOKE ALL ON FUNCTION public.mystery_pool_add_generic(TEXT, TEXT, TEXT, INTEGER)
  FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- SUBMISSION — Market Maker sells a slice of a collection into the pool.
-- Gated on mode; the platform pays the fixed config rate immediately on acceptance.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.mystery_pool_submit_internal(
  p_user UUID, p_collection UUID, p_chit_id UUID, p_copies INTEGER
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_mode    TEXT := public.mystery_pool_mode();
  v_pct     INTEGER;
  v_coll    public.collections%ROWTYPE;
  v_chit    public.moment_chits%ROWTYPE;
  v_cfg     public.mystery_pool_tier_config%ROWTYPE;
  v_cap     INTEGER;
  v_already INTEGER;
  v_qty     INTEGER;
  v_sub     UUID;
  v_payout  INTEGER;
BEGIN
  IF p_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF v_mode = 'disabled' THEN
    RAISE EXCEPTION 'Mystery Pool submissions are not open yet (G-MYSTERY: beta-disabled)';
  END IF;
  IF p_copies < 1 THEN RAISE EXCEPTION 'copies must be >= 1'; END IF;

  SELECT max_submit_pct INTO v_pct FROM public.mystery_pool_settings WHERE id;

  -- Serialize this user's pool writes so the cap check and the escrow are race-free.
  PERFORM pg_advisory_xact_lock(hashtextextended('mystery_submit:' || p_user::TEXT, 42));

  SELECT * INTO v_coll FROM public.collections WHERE id = p_collection;
  IF NOT FOUND THEN RAISE EXCEPTION 'Collection % not found', p_collection; END IF;
  IF v_coll.market_maker_user_id <> p_user THEN
    RAISE EXCEPTION 'Only the collection minter may submit its cards';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.collection_chits
                 WHERE collection_id = p_collection AND chit_id = p_chit_id) THEN
    RAISE EXCEPTION 'Chit % is not a member of collection %', p_chit_id, p_collection;
  END IF;

  SELECT * INTO v_chit FROM public.moment_chits WHERE id = p_chit_id;
  IF v_chit.retired_at IS NOT NULL OR NOT v_chit.is_active OR v_chit.finalized_at IS NULL THEN
    RAISE EXCEPTION 'Chit % is not a live, finalized chit', p_chit_id;
  END IF;

  SELECT * INTO v_cfg FROM public.mystery_pool_tier_config WHERE tier = v_chit.tier;
  IF NOT FOUND THEN RAISE EXCEPTION 'No pool rate for tier %', v_chit.tier; END IF;

  -- Cap: at most max_submit_pct of this card's fixed supply, cumulative.
  v_cap := GREATEST((v_chit.total_supply * v_pct) / 100, 1);
  SELECT COALESCE(SUM(copies), 0) INTO v_already
  FROM public.mystery_pool_submissions WHERE chit_id = p_chit_id;
  IF v_already + p_copies > v_cap THEN
    RAISE EXCEPTION 'Submission cap reached for chit % (% of % allowed, % already submitted)',
      p_chit_id, v_cap, v_chit.total_supply, v_already;
  END IF;

  SELECT quantity INTO v_qty FROM public.chit_ownership
  WHERE user_id = p_user AND chit_id = p_chit_id FOR UPDATE;
  IF COALESCE(v_qty, 0) < p_copies THEN
    RAISE EXCEPTION 'You hold % copies of chit %, cannot submit %',
      COALESCE(v_qty, 0), p_chit_id, p_copies;
  END IF;

  v_payout := v_cfg.submit_payout_cents * p_copies;

  INSERT INTO public.mystery_pool_submissions
    (collection_id, chit_id, user_id, copies, tier_snapshot, payout_cents, mode_snapshot)
  VALUES (p_collection, p_chit_id, p_user, p_copies, v_chit.tier, v_payout, v_mode)
  RETURNING id INTO v_sub;

  -- Copies leave circulation into the pool (mig-170 machinery pins the lowest serials).
  PERFORM public.chit_grant(p_user, p_chit_id, -p_copies, 'mystery_pool_submit', v_sub);

  -- Platform buys them outright — paid immediately on acceptance (§1.5). USD rail
  -- only (Hard Rule 33: never token_transactions); ccg_usd_credit still refuses
  -- while battle_payments_mode is 'live' and the Treasury prereqs are unmet.
  PERFORM public.ccg_usd_credit(p_user, v_payout, v_sub, 'Mystery Pool submission', 'distribution');

  RETURN v_sub;
END;
$$;

CREATE OR REPLACE FUNCTION public.mystery_pool_submit(
  p_collection UUID, p_chit_id UUID, p_copies INTEGER DEFAULT 1
)
RETURNS UUID
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.mystery_pool_submit_internal(auth.uid(), p_collection, p_chit_id, p_copies);
$$;

REVOKE ALL ON FUNCTION public.mystery_pool_submit_internal(UUID, UUID, UUID, INTEGER)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mystery_pool_submit(UUID, UUID, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mystery_pool_submit(UUID, UUID, INTEGER) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- AWARD ENGINE — server-only. NO purchase path exists, by construction.
-- Weighted draw across tiers that actually have inventory, then a random copy of
-- that tier. Idempotent per gameplay context key: one win = one box, forever.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.mystery_box_grant(p_user UUID, p_context_key TEXT)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_existing UUID;
  v_tier     TEXT;
  v_copy     public.chit_copies%ROWTYPE;
  v_chit     public.moment_chits%ROWTYPE;
  v_grant    UUID;
BEGIN
  IF p_user IS NULL OR p_context_key IS NULL OR btrim(p_context_key) = '' THEN
    RAISE EXCEPTION 'mystery_box_grant needs a user and a context key';
  END IF;
  IF public.mystery_pool_mode() = 'disabled' THEN
    RAISE EXCEPTION 'Mystery Box awards are not open yet (G-MYSTERY: beta-disabled)';
  END IF;

  -- Idempotency: a replayed win returns the original grant, never a second box.
  SELECT id INTO v_existing FROM public.mystery_box_grants WHERE context_key = p_context_key;
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;

  -- One drawer at a time: two boxes must never draw the same copy.
  PERFORM pg_advisory_xact_lock(hashtextextended('mystery_draw', 42));

  -- Re-check under the lock (a concurrent grant may have just landed).
  SELECT id INTO v_existing FROM public.mystery_box_grants WHERE context_key = p_context_key;
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;

  -- Weighted tier pick, restricted to tiers with inventory. random() * total_weight
  -- walked against a running sum — standard weighted draw, no extension needed.
  WITH avail AS (
    SELECT mc.tier, SUM(1) AS n
    FROM public.chit_copies cc
    JOIN public.moment_chits mc ON mc.id = cc.chit_id
    WHERE cc.state = 'mystery_pool'
    GROUP BY mc.tier
  ),
  weighted AS (
    SELECT a.tier, GREATEST(t.draw_weight, 0) AS w
    FROM avail a
    JOIN public.mystery_pool_tier_config t ON t.tier = a.tier
    WHERE t.draw_weight > 0
  ),
  running AS (
    SELECT tier, w,
           SUM(w) OVER (ORDER BY tier) AS cum,
           SUM(w) OVER () AS total
    FROM weighted
  )
  SELECT tier INTO v_tier
  FROM running
  WHERE cum >= (random() * total)
  ORDER BY cum
  LIMIT 1;

  IF v_tier IS NULL THEN
    RAISE EXCEPTION 'Mystery Pool is empty — no copy available to award';
  END IF;

  SELECT cc.* INTO v_copy
  FROM public.chit_copies cc
  JOIN public.moment_chits mc ON mc.id = cc.chit_id
  WHERE cc.state = 'mystery_pool' AND mc.tier = v_tier
  ORDER BY random()
  LIMIT 1
  FOR UPDATE OF cc;

  IF v_copy.id IS NULL THEN
    RAISE EXCEPTION 'Mystery Pool draw found no copy for tier %', v_tier;
  END IF;

  SELECT * INTO v_chit FROM public.moment_chits WHERE id = v_copy.chit_id;

  -- reference_id = the exact copy drawn, so the machinery cannot hand over another.
  PERFORM public.chit_grant(p_user, v_copy.chit_id, 1, 'mystery_box_grant', v_copy.id);

  INSERT INTO public.mystery_box_grants
    (user_id, context_key, copy_id, chit_id, tier, was_generic)
  VALUES (p_user, p_context_key, v_copy.id, v_copy.chit_id, v_tier, v_chit.is_generic)
  RETURNING id INTO v_grant;

  RETURN v_grant;
END;
$$;

-- SERVER-ONLY. Boxes are earned through gameplay, never requested by a client and
-- never bought. Granting execute to `authenticated` would create the purchase-free
-- but self-serve path this gate exists to prevent.
REVOKE ALL ON FUNCTION public.mystery_box_grant(UUID, TEXT) FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- MARKETPLACE GUARD — generic cards can never be listed, in any currency.
-- mig 172's body verbatim plus the is_generic gate (marked).
--
-- FIRST: drop the stale 3-arg overload. mig 172 added the 4-arg form via CREATE OR
-- REPLACE, which does NOT replace a different signature — so prod carried BOTH
-- marketplace_list_chit_internal(uuid,uuid,text) and (uuid,uuid,text,integer). The
-- legacy one has neither N3's seller-set pricing nor the generic ban below, and its
-- existence made every 3-arg call ambiguous (this migration's own smoke caught it).
-- Only the 4-arg wrapper references it in the live DB, and every other caller is a
-- historical migration smoke, so dropping it is safe and leaves exactly one
-- listing path — the one carrying all the guards.
-- ═══════════════════════════════════════════════════════════════════════════════
DROP FUNCTION IF EXISTS public.marketplace_list_chit_internal(UUID, UUID, TEXT);

CREATE OR REPLACE FUNCTION public.marketplace_list_chit_internal(
  p_user UUID, p_chit_id UUID, p_currency TEXT DEFAULT 'token', p_price_cents INTEGER DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_chit    public.moment_chits%ROWTYPE;
  v_price   public.marketplace_tier_pricing%ROWTYPE;
  v_qty     INTEGER;
  v_active  INTEGER;
  v_listing UUID;
  v_usd     INTEGER;
  v_feebps  INTEGER;
BEGIN
  IF p_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF p_currency NOT IN ('token','usd') THEN
    RAISE EXCEPTION 'Unknown currency: %', p_currency;
  END IF;

  SELECT * INTO v_chit FROM public.moment_chits WHERE id = p_chit_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Chit not found: %', p_chit_id; END IF;

  -- N6: platform-authored generic cards are in-game use only. Structural, not config.
  IF v_chit.is_generic THEN
    RAISE EXCEPTION 'Generic cards cannot be listed on the marketplace';
  END IF;

  SELECT * INTO v_price FROM public.marketplace_tier_pricing WHERE tier = v_chit.tier;
  IF NOT FOUND THEN RAISE EXCEPTION 'No marketplace pricing for tier %', v_chit.tier; END IF;

  IF p_currency = 'usd' THEN
    IF NOT public.marketplace_usd_enabled() THEN
      RAISE EXCEPTION 'usd marketplace lane not enabled';
    END IF;
    IF NOT public.is_eligible_for_real_money(p_user) THEN
      RAISE EXCEPTION 'USD listings require KYC verification';
    END IF;
    IF EXISTS (SELECT 1 FROM public.chit_acquisition_ledger
               WHERE user_id = p_user AND chit_id = p_chit_id
                 AND acquired_currency = 'token') THEN
      RAISE EXCEPTION 'Token-bought copies are token-resale-only (provenance lock)';
    END IF;
    v_usd := COALESCE(p_price_cents, v_price.usd_cents);
    IF v_usd < COALESCE(v_price.usd_min_cents, 1)
       OR v_usd > COALESCE(v_price.usd_max_cents, v_price.usd_cents * 3) THEN
      RAISE EXCEPTION 'USD price % is outside the tier % band (%–%)',
        v_usd, v_chit.tier, v_price.usd_min_cents, v_price.usd_max_cents;
    END IF;
    v_feebps := public.platform_fee('marketplace_sale_fee_bps');
  ELSE
    v_usd := v_price.usd_cents;
    v_feebps := v_price.fee_bps;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('marketplace_list:' || p_user::TEXT, 42));

  IF v_chit.retired_at IS NOT NULL OR NOT v_chit.is_active OR v_chit.finalized_at IS NULL THEN
    RAISE EXCEPTION 'Chit % is not a live, finalized chit', p_chit_id;
  END IF;

  SELECT quantity INTO v_qty FROM public.chit_ownership
  WHERE user_id = p_user AND chit_id = p_chit_id
  FOR UPDATE;
  IF COALESCE(v_qty, 0) < 1 THEN
    RAISE EXCEPTION 'You do not hold a copy of chit %', p_chit_id;
  END IF;

  IF EXISTS (SELECT 1 FROM public.ccg_wager_escrow
             WHERE user_id = p_user AND chit_id = p_chit_id AND status = 'escrowed') THEN
    RAISE EXCEPTION 'Chit % is escrowed in an active wager match', p_chit_id;
  END IF;
  IF EXISTS (SELECT 1 FROM public.marketplace_listings
             WHERE seller_user_id = p_user AND chit_id = p_chit_id AND status = 'active') THEN
    RAISE EXCEPTION 'Chit % is already listed', p_chit_id;
  END IF;

  SELECT COUNT(*) INTO v_active FROM public.marketplace_listings
  WHERE seller_user_id = p_user AND status = 'active';
  IF v_active >= public.marketplace_listing_allowance(p_user) THEN
    RAISE EXCEPTION 'Listing allowance reached (% active)', v_active;
  END IF;

  INSERT INTO public.marketplace_listings
    (chit_id, seller_user_id, currency, tier_snapshot,
     price_snapshot, fee_bps_snapshot, usd_cents_snapshot)
  VALUES
    (p_chit_id, p_user, p_currency, v_chit.tier,
     v_price.token_price, v_feebps, v_usd)
  RETURNING id INTO v_listing;

  PERFORM public.chit_grant(p_user, p_chit_id, -1, 'marketplace_escrow', v_listing);

  RETURN v_listing;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- SEED — a minimal generic set so the pool is never empty when the gate opens.
-- One card per tier, 25 copies each. Idempotent: skipped if generics already exist.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.moment_chits WHERE is_generic) THEN
    PERFORM public.mystery_pool_add_generic('Practice Rookie',   'gamer',     'F', 25);
    PERFORM public.mystery_pool_add_generic('Practice Striker',  'athlete',   'E', 25);
    PERFORM public.mystery_pool_add_generic('Practice Soloist',  'musician',  'D', 25);
    PERFORM public.mystery_pool_add_generic('Practice Sketch',   'artist',    'C', 25);
    PERFORM public.mystery_pool_add_generic('Practice Theorem',  'scientist', 'B', 25);
    PERFORM public.mystery_pool_add_generic('Practice Punchline','comedian',  'A', 25);
    PERFORM public.mystery_pool_add_generic('Practice Legend',   'gamer',     'S', 25);
  END IF;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- APPLY-TIME SMOKE — proves the gate, the cap, the custody round-trip, idempotency,
-- the generic listing ban, and that no paid path exists. Runs on the mig-155 smoke
-- identities (is_test_account; P7 sweeps them). Restores mode='disabled' at the end
-- even though it never leaves this transaction — the flag is the product gate.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_u1 UUID; v_u2 UUID;
  v_coll UUID; v_chit UUID; v_gen UUID;
  v_sub UUID; v_g1 UUID; v_g2 UUID;
  v_usd BIGINT; v_cur BIGINT;
  v_q INTEGER; v_c INTEGER; v_err BOOLEAN; v_msg TEXT;
  v_row public.chit_copies%ROWTYPE;
  v_grant public.mystery_box_grants%ROWTYPE;
BEGIN
  SELECT id INTO v_u1 FROM auth.users WHERE email = 'mkt-smoke-1@noraplatforms.com';
  SELECT id INTO v_u2 FROM auth.users WHERE email = 'mkt-smoke-2@noraplatforms.com';
  IF v_u1 IS NULL OR v_u2 IS NULL THEN
    RAISE EXCEPTION 'mig 175 smoke needs the mig-155 smoke users';
  END IF;
  -- The submission leg pays real (sim) dollars; ccg_usd_credit refuses under 'live'.
  IF public.battle_payments_mode() <> 'sim' THEN
    RAISE NOTICE 'N6 smoke SKIPPED (battle_payments_mode is live)';
    RETURN;
  END IF;

  -- ── the gate itself: everything RAISEs while disabled ────────────────────────
  IF public.mystery_pool_mode() <> 'disabled' THEN
    RAISE EXCEPTION 'SMOKE FAIL: beta default mode must be disabled (G-MYSTERY)';
  END IF;
  v_err := FALSE;
  BEGIN
    PERFORM public.mystery_box_grant(v_u2, 'smoke:gate-check');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM;
  END;
  IF NOT v_err OR v_msg NOT LIKE '%beta-disabled%' THEN
    RAISE EXCEPTION 'SMOKE FAIL: grants must be blocked while disabled (got %)', v_msg;
  END IF;

  -- ── generics seeded and in the pool ─────────────────────────────────────────
  SELECT COUNT(*) INTO v_c FROM public.moment_chits WHERE is_generic;
  IF v_c < 7 THEN RAISE EXCEPTION 'SMOKE FAIL: generic set must be seeded (got %)', v_c; END IF;
  SELECT id INTO v_gen FROM public.moment_chits WHERE is_generic AND tier = 'S' LIMIT 1;
  SELECT COUNT(*) INTO v_c FROM public.chit_copies
  WHERE chit_id = v_gen AND state = 'mystery_pool';
  IF v_c <> 25 THEN
    RAISE EXCEPTION 'SMOKE FAIL: generic copies must rest in mystery_pool (got %)', v_c;
  END IF;
  -- and the custodian holds none of them as live holdings
  SELECT COALESCE(quantity, 0) INTO v_q FROM public.chit_ownership
  WHERE user_id = public.mystery_pool_custodian() AND chit_id = v_gen;
  IF COALESCE(v_q, 0) <> 0 THEN
    RAISE EXCEPTION 'SMOKE FAIL: pooled generics must leave custodian holdings (got %)', v_q;
  END IF;

  -- ── generic cards are never listable ────────────────────────────────────────
  v_err := FALSE;
  BEGIN
    PERFORM public.marketplace_list_chit_internal(public.mystery_pool_custodian(), v_gen, 'token', NULL);
  EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM;
  END;
  IF NOT v_err OR v_msg NOT LIKE '%Generic cards cannot be listed%' THEN
    RAISE EXCEPTION 'SMOKE FAIL: generic listing must be blocked (got %)', v_msg;
  END IF;

  -- ── open the gate (transaction-local) and run the real flow ─────────────────
  UPDATE public.mystery_pool_settings SET mode = 'sim' WHERE id;

  -- Minter eligibility (mig-172 smoke pattern): KYC + a linked social. Both are
  -- idempotent here — the mig-172 residue may already satisfy is_collection_minter.
  IF NOT public.is_collection_minter(v_u1) THEN
    INSERT INTO public.kyc_verifications (user_id, status) VALUES (v_u1, 'approved');
    INSERT INTO public.platform_connections
      (user_id, platform, platform_user_id, platform_username, access_token, is_active)
    VALUES (v_u1, 'youtube', 'n6-smoke', '@n6_smoke', 'tok', TRUE);
  END IF;

  -- a 10-copy collection card owned by u1
  v_coll := public.collection_create_internal(v_u1, 'N6 smoke collection', NULL, NULL);
  v_chit := public.create_moment_chit('N6 smoke card', 'athlete', 'creature', 'C');
  UPDATE public.moment_chits
  SET finalized_at = NOW(), original_minter_handle = '@n6_smoke', source_platform = 'youtube'
  WHERE id = v_chit;
  PERFORM set_config('nora.allow_supply_set', 'on', TRUE);
  UPDATE public.moment_chits SET total_supply = 10 WHERE id = v_chit;
  PERFORM set_config('nora.allow_supply_set', 'off', TRUE);
  INSERT INTO public.collection_chits (collection_id, chit_id) VALUES (v_coll, v_chit);
  PERFORM public.chit_grant(v_u1, v_chit, 10, 'event');

  -- cap: 20% of 10 = 2, so 3 must be refused
  v_err := FALSE;
  BEGIN
    PERFORM public.mystery_pool_submit_internal(v_u1, v_coll, v_chit, 3);
  EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM;
  END;
  IF NOT v_err OR v_msg NOT LIKE '%Submission cap reached%' THEN
    RAISE EXCEPTION 'SMOKE FAIL: over-cap submission must be blocked (got %)', v_msg;
  END IF;

  -- a legal 2-copy submission pays the tier-C rate (200c each = 400c)
  PERFORM public.sim_seed_balance(v_u1);
  SELECT balance_usd_cents INTO v_usd FROM public.sim_usd_balances WHERE user_id = v_u1;
  v_sub := public.mystery_pool_submit_internal(v_u1, v_coll, v_chit, 2);
  SELECT balance_usd_cents INTO v_cur FROM public.sim_usd_balances WHERE user_id = v_u1;
  IF v_cur <> v_usd + 400 THEN
    RAISE EXCEPTION 'SMOKE FAIL: submitter must be paid 400c (was %, now %)', v_usd, v_cur;
  END IF;
  SELECT quantity INTO v_q FROM public.chit_ownership WHERE user_id = v_u1 AND chit_id = v_chit;
  IF v_q <> 8 THEN RAISE EXCEPTION 'SMOKE FAIL: submitter must hold 8 after submitting 2 (got %)', v_q; END IF;
  SELECT COUNT(*) INTO v_c FROM public.chit_copies
  WHERE chit_id = v_chit AND state = 'mystery_pool' AND escrow_ref = v_sub;
  IF v_c <> 2 THEN RAISE EXCEPTION 'SMOKE FAIL: 2 copies must rest in the pool (got %)', v_c; END IF;

  -- a second submission would exceed the cumulative cap
  v_err := FALSE;
  BEGIN
    PERFORM public.mystery_pool_submit_internal(v_u1, v_coll, v_chit, 1);
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: cumulative cap must hold across submissions'; END IF;

  -- non-minter cannot submit someone else's collection
  v_err := FALSE;
  BEGIN
    PERFORM public.mystery_pool_submit_internal(v_u2, v_coll, v_chit, 1);
  EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM;
  END;
  IF NOT v_err OR v_msg NOT LIKE '%Only the collection minter%' THEN
    RAISE EXCEPTION 'SMOKE FAIL: non-minter submission must be blocked (got %)', v_msg;
  END IF;

  -- ── award: a box hands over a real serialized copy ──────────────────────────
  v_g1 := public.mystery_box_grant(v_u2, 'smoke:match:n6-1');
  SELECT * INTO v_grant FROM public.mystery_box_grants WHERE id = v_g1;
  SELECT * INTO v_row FROM public.chit_copies WHERE id = v_grant.copy_id;
  IF v_row.owner_user_id <> v_u2 OR v_row.state <> 'owned' THEN
    RAISE EXCEPTION 'SMOKE FAIL: granted copy must transfer to the winner as owned';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.chit_copy_transfers
                 WHERE copy_id = v_grant.copy_id AND to_user_id = v_u2
                   AND reason = 'mystery_box_grant') THEN
    RAISE EXCEPTION 'SMOKE FAIL: the grant must be logged in copy history';
  END IF;

  -- idempotency: one win = one box, replay returns the same grant
  v_g2 := public.mystery_box_grant(v_u2, 'smoke:match:n6-1');
  IF v_g2 <> v_g1 THEN RAISE EXCEPTION 'SMOKE FAIL: replayed context key must not grant a second box'; END IF;
  SELECT COUNT(*) INTO v_c FROM public.mystery_box_grants WHERE context_key = 'smoke:match:n6-1';
  IF v_c <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: exactly one grant row per context key (got %)', v_c; END IF;

  -- ── structural: there is no paid path to a box ──────────────────────────────
  SELECT COUNT(*) INTO v_c FROM pg_proc
  WHERE proname ILIKE '%mystery%'
    AND (proname ILIKE '%buy%' OR proname ILIKE '%purchase%' OR proname ILIKE '%open_box%');
  IF v_c > 0 THEN
    RAISE EXCEPTION 'SMOKE FAIL: a purchase path to Mystery Boxes exists (% fns) — structural ban', v_c;
  END IF;

  -- whole-table invariant still holds after all the pool movement
  SELECT COUNT(*) INTO v_c FROM (
    SELECT o.user_id, o.chit_id, o.quantity,
           (SELECT COUNT(*) FROM public.chit_copies c
            WHERE c.chit_id = o.chit_id AND c.owner_user_id = o.user_id
              AND c.state = 'owned') AS copies
    FROM public.chit_ownership o
  ) t WHERE t.quantity <> t.copies;
  IF v_c > 0 THEN
    RAISE EXCEPTION 'SMOKE FAIL: % rows where quantity <> owned copies', v_c;
  END IF;

  -- ── cleanup: unwind the smoke card, restore the gate ────────────────────────
  PERFORM public.chit_grant(v_u1, v_chit, -8, 'platform_correction');
  SELECT COALESCE(quantity, 0) INTO v_q FROM public.chit_ownership
  WHERE user_id = v_u2 AND chit_id = v_grant.chit_id;
  IF v_q > 0 THEN
    PERFORM public.chit_grant(v_u2, v_grant.chit_id, -v_q, 'platform_correction');
  END IF;
  UPDATE public.moment_chits
  SET is_active = FALSE, retired_at = NOW(), retired_reason = 'admin'
  WHERE id = v_chit;
  UPDATE public.collections SET status = 'closed' WHERE id = v_coll;

  UPDATE public.mystery_pool_settings SET mode = 'disabled' WHERE id;
  IF public.mystery_pool_mode() <> 'disabled' THEN
    RAISE EXCEPTION 'SMOKE FAIL: the gate must be left disabled';
  END IF;

  RAISE NOTICE 'N6 smoke OK: gate blocks, cap holds, custody round-trips, grants idempotent, generics unlistable, no paid path';
END $$;
