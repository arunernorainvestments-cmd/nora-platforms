-- Migration 170: chit_copies — per-copy identity + "# of N" serialization.
--
-- Collections spec (NORA_PLATFORMS_COLLECTIONS_SPEC.md) Phase N2.1. Mig 117 made
-- copies fungible (chit_ownership quantity); serialized "# of N" copies require
-- unique copy INSTANCES. This migration adds them WITHOUT moving the source of
-- truth: the append-only chit_acquisition_ledger (mig 117) stays the ledger,
-- chit_ownership stays the trigger-maintained quantity table every existing
-- consumer reads (deck validation 118, barter 119, wager 142, marketplace 155/156,
-- P5 passive slice), and copy rows are maintained by a SECOND trigger on the SAME
-- ledger inserts — one choke point, so quantities and copy identity cannot diverge.
--
-- REPO-CHECK N2.1 resolutions (recorded here per spec §0):
--   (a) card_serial (mig 148, 'NORA-####') is DEFINITION-level — the catalog serial
--       of the card design. chit_copies.serial_number is the per-copy "# of N"
--       index. They answer different questions and both display: "NORA-0042 · #3
--       of 100". No rename needed; the two never told the same story.
--   (b) chit_ownership REMAINS the derived holdings table (not replaced by a view:
--       its FOR UPDATE row locks and the mig-117 trigger machinery are load-bearing
--       for every money path). Invariant enforced by construction: quantity ==
--       COUNT(copies owned by that user in state 'owned').
-- REPO-CHECK N2.2: consumers traced — deck entry (118), barter (119), wager escrow
--   (142), marketplace escrow (155/156), settlement passive slice (133/145) all
--   read quantities and keep working unmodified; wager + marketplace escrow now pin
--   a SPECIFIC copy (state + escrow_ref on the copy row) via the machinery below.
--
-- Copy states: owned | listed_escrow | wager_escrow | mystery_pool (spec resting
-- states) + 'released' (left the owner's circulation: disposal/swap-retire, or the
-- outbound leg of a transfer awaiting its inbound claim — barter writes -N then +N
-- with the same reference_id, mig 119).
--
-- Supply: moment_chits.total_supply (1–1000, Hard-Rule-locked: FIXED AT MINT, never
-- increasable — G-COLL). The ONLY sanctioned writer is the collection publish flow
-- (mig 171), which flags itself via set_config('nora.allow_supply_set', 'on', true)
-- inside its SECURITY DEFINER body; everything else RAISEs.

-- ── total_supply on the definition ────────────────────────────────────────────────
ALTER TABLE public.moment_chits
  ADD COLUMN IF NOT EXISTS total_supply INTEGER NOT NULL DEFAULT 1
    CHECK (total_supply BETWEEN 1 AND 1000);

-- ── chit_copies: one row per physical copy ────────────────────────────────────────
CREATE TABLE public.chit_copies (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  chit_id        UUID NOT NULL REFERENCES public.moment_chits(id),
  serial_number  INTEGER NOT NULL CHECK (serial_number BETWEEN 1 AND 1000),
  -- denormalized for display ("#3 of 100") — copied from the definition at creation
  total_supply   INTEGER NOT NULL CHECK (total_supply BETWEEN 1 AND 1000),
  owner_user_id  UUID NOT NULL REFERENCES auth.users(id),
  state          TEXT NOT NULL DEFAULT 'owned' CHECK (state IN (
    'owned','listed_escrow','wager_escrow','mystery_pool','released'
  )),
  escrow_ref     UUID,   -- listing id / match id while escrowed
  transit_ref    UUID,   -- outbound reference while 'released' (claimed by the inbound leg)
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (chit_id, serial_number)
);

CREATE INDEX chit_copies_owner_idx  ON public.chit_copies (owner_user_id, state);
CREATE INDEX chit_copies_chit_idx   ON public.chit_copies (chit_id, state);
CREATE INDEX chit_copies_escrow_idx ON public.chit_copies (escrow_ref) WHERE escrow_ref IS NOT NULL;

COMMENT ON TABLE public.chit_copies IS
  'One row per serialized copy of a moment chit ("#serial of total_supply"). '
  'Maintained ONLY by the chit_acquisition_ledger trigger machinery (mig 170) — '
  'no client writes, no direct RPC writes outside that choke point.';

-- ── chit_copy_transfers: append-only ownership history per copy (Rule 29) ─────────
CREATE TABLE public.chit_copy_transfers (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  copy_id       UUID NOT NULL REFERENCES public.chit_copies(id),
  chit_id       UUID NOT NULL REFERENCES public.moment_chits(id),
  serial_number INTEGER NOT NULL,
  from_user_id  UUID REFERENCES auth.users(id),   -- NULL = copy created (mint)
  to_user_id    UUID NOT NULL REFERENCES auth.users(id),
  reason        TEXT NOT NULL,                     -- the ledger reason that moved it
  reference_id  UUID,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX chit_copy_transfers_copy_idx ON public.chit_copy_transfers (copy_id, created_at);
CREATE INDEX chit_copy_transfers_user_idx ON public.chit_copy_transfers (to_user_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.chit_copy_transfers_block_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'chit_copy_transfers is append-only (no UPDATE/DELETE)';
END;
$$;

CREATE TRIGGER chit_copy_transfers_no_mutation
  BEFORE UPDATE OR DELETE ON public.chit_copy_transfers
  FOR EACH ROW EXECUTE FUNCTION public.chit_copy_transfers_block_mutation();

-- ── RLS: owners read their copies; listed copies are public (the listing already
--    is); transfer history readable by either party. No client writes anywhere. ───
ALTER TABLE public.chit_copies         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chit_copy_transfers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "chit_copies_select_own_or_listed" ON public.chit_copies
  FOR SELECT USING (auth.uid() = owner_user_id OR state = 'listed_escrow');

CREATE POLICY "chit_copy_transfers_select_party" ON public.chit_copy_transfers
  FOR SELECT USING (auth.uid() IN (from_user_id, to_user_id));

-- ═══════════════════════════════════════════════════════════════════════════════
-- BACKFILL — existing holdings + open escrows become copy rows; total_supply
-- becomes the outstanding copy count (existing single mints stay 1). Runs BEFORE
-- the immutability trigger exists, so it may write total_supply freely.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  r RECORD;
  v_serial INTEGER;
BEGIN
  FOR r IN SELECT DISTINCT chit_id FROM (
             SELECT chit_id FROM public.chit_ownership WHERE quantity > 0
             UNION
             SELECT chit_id FROM public.marketplace_listings WHERE status = 'active'
             UNION
             SELECT chit_id FROM public.ccg_wager_escrow WHERE status = 'escrowed'
           ) s
  LOOP
    v_serial := 0;

    -- owned quantities (deterministic order: by user)
    INSERT INTO public.chit_copies (chit_id, serial_number, total_supply, owner_user_id, state)
    SELECT r.chit_id,
           v_serial + ROW_NUMBER() OVER (ORDER BY o.user_id, gs.n),
           1,  -- placeholder; fixed below once the outstanding count is known
           o.user_id, 'owned'
    FROM public.chit_ownership o
    CROSS JOIN LATERAL generate_series(1, o.quantity) AS gs(n)
    WHERE o.chit_id = r.chit_id AND o.quantity > 0;
    SELECT COALESCE(MAX(serial_number), 0) INTO v_serial
    FROM public.chit_copies WHERE chit_id = r.chit_id;

    -- active marketplace escrows (the copy left the seller's quantity at list time)
    INSERT INTO public.chit_copies (chit_id, serial_number, total_supply, owner_user_id, state, escrow_ref)
    SELECT r.chit_id,
           v_serial + ROW_NUMBER() OVER (ORDER BY ml.created_at),
           1, ml.seller_user_id, 'listed_escrow', ml.id
    FROM public.marketplace_listings ml
    WHERE ml.chit_id = r.chit_id AND ml.status = 'active';
    SELECT COALESCE(MAX(serial_number), 0) INTO v_serial
    FROM public.chit_copies WHERE chit_id = r.chit_id;

    -- open wager escrows
    INSERT INTO public.chit_copies (chit_id, serial_number, total_supply, owner_user_id, state, escrow_ref)
    SELECT r.chit_id,
           v_serial + ROW_NUMBER() OVER (ORDER BY we.created_at),
           1, we.user_id, 'wager_escrow', we.match_id
    FROM public.ccg_wager_escrow we
    WHERE we.chit_id = r.chit_id AND we.status = 'escrowed';
    SELECT COALESCE(MAX(serial_number), 0) INTO v_serial
    FROM public.chit_copies WHERE chit_id = r.chit_id;

    -- fix supply: outstanding copies (min 1), stamped on definition + copies
    UPDATE public.moment_chits SET total_supply = GREATEST(v_serial, 1) WHERE id = r.chit_id;
    UPDATE public.chit_copies  SET total_supply = GREATEST(v_serial, 1) WHERE chit_id = r.chit_id;
  END LOOP;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- SUPPLY IMMUTABILITY — total_supply is fixed at mint (G-COLL product promise).
-- The ONLY writer is the sanctioned collection-publish path (mig 171), which sets
-- the transaction-local flag inside its SECURITY DEFINER body. Even that path may
-- never DECREASE below serials already issued (enforced there); this trigger is
-- the unconditional backstop against everything else.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.moment_chits_lock_supply()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.total_supply IS DISTINCT FROM OLD.total_supply
     AND COALESCE(current_setting('nora.allow_supply_set', TRUE), '') <> 'on' THEN
    RAISE EXCEPTION 'total_supply is immutable after mint (chit %)', OLD.id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER moment_chits_supply_immutable
  BEFORE UPDATE ON public.moment_chits
  FOR EACH ROW EXECUTE FUNCTION public.moment_chits_lock_supply();

-- ═══════════════════════════════════════════════════════════════════════════════
-- COPY MACHINERY — the second trigger on chit_acquisition_ledger. Every quantity
-- movement already flows through ledger inserts with (reason, reference_id,
-- counterparty), so copy identity is derived at the same choke point:
--
--   negative delta:
--     marketplace_escrow → lowest owned serials pinned 'listed_escrow' (ref=listing)
--     wager_escrow       → lowest owned serials pinned 'wager_escrow'  (ref=match)
--     anything else      → lowest owned serials 'released' (transit_ref=reference —
--                          barter/gift outbound legs, swap-retire, corrections)
--   positive delta:
--     marketplace_purchase → claim the listed_escrow copy by escrow_ref → new owner
--     marketplace_return   → the seller's listed_escrow copy back to 'owned'
--     wager_won            → claim the loser's wager_escrow copy by match → winner
--     wager_return         → own wager_escrow copy back to 'owned'
--     mint / collection_mint → CREATE the next serials (1..N; hard-capped by
--                          total_supply — supply can never inflate)
--     anything else        → claim a 'released' copy: same transit_ref + counterparty
--                          first, then same transit_ref, then any released copy of
--                          the chit, then create a fresh serial if supply allows.
--
-- Owner changes append to chit_copy_transfers (Rule 29 history per copy).
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
  -- Serialize all copy movement per chit (also guards serial assignment races).
  SELECT total_supply INTO v_supply
  FROM public.moment_chits WHERE id = NEW.chit_id FOR UPDATE;
  IF v_supply IS NULL THEN
    RAISE EXCEPTION 'chit_copies machinery: unknown chit %', NEW.chit_id;
  END IF;

  IF NEW.quantity_delta < 0 THEN
    v_n := -NEW.quantity_delta;
    v_state := CASE NEW.reason
      WHEN 'marketplace_escrow' THEN 'listed_escrow'
      WHEN 'wager_escrow'       THEN 'wager_escrow'
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

      ELSIF NEW.reason IN ('mint','collection_mint') THEN
        NULL;  -- create-only below

      ELSE
        -- generic inbound: matched transit first, then ref-only, then any released
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

      ELSIF NEW.reason IN ('marketplace_purchase','marketplace_return','wager_won','wager_return') THEN
        -- an escrow claim MUST find its pinned copy — anything else is corruption
        RAISE EXCEPTION 'chit_copies machinery: no escrowed copy for % (chit %, ref %)',
          NEW.reason, NEW.chit_id, NEW.reference_id;

      ELSE
        -- create the next serial — hard-capped by the fixed supply (never inflate)
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

-- Named to sort AFTER chit_ledger_apply_holdings (Postgres fires same-event
-- triggers in name order) so the mig-117 negative-balance guard runs first.
CREATE TRIGGER chit_ledger_maintain_copies
  AFTER INSERT ON public.chit_acquisition_ledger
  FOR EACH ROW EXECUTE FUNCTION public.apply_chit_ledger_to_copies();

-- ═══════════════════════════════════════════════════════════════════════════════
-- APPLY-TIME SMOKE — full copy lifecycle on the mkt-smoke identities (mig 155
-- discipline: append-only residue lives on is_test_account users; P7 sweeps).
-- Proves: creation serials · quantity==owned-copies invariant · supply immutability
-- (flagged path allowed, unflagged RAISEs) · marketplace escrow/purchase pins +
-- transfers a specific serial · wager stakes specific copies + winner takes the
-- exact staked serial · generic release/claim pairing (barter/gift shape) ·
-- supply exhaustion RAISEs · backfill consistency across the whole table.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_u1 UUID; v_u2 UUID;
  v_T UUID; v_lst UUID; v_match UUID; v_gift UUID := gen_random_uuid();
  v_bal1 INTEGER; v_bal2 INTEGER; v_cur INTEGER;
  v_q INTEGER; v_c INTEGER; v_err BOOLEAN;
  v_row public.chit_copies%ROWTYPE;
  v_bad INTEGER;
BEGIN
  SELECT id INTO v_u1 FROM auth.users WHERE email = 'mkt-smoke-1@noraplatforms.com';
  SELECT id INTO v_u2 FROM auth.users WHERE email = 'mkt-smoke-2@noraplatforms.com';
  IF v_u1 IS NULL OR v_u2 IS NULL THEN
    RAISE EXCEPTION 'mig 170 smoke requires the mig-155 smoke users';
  END IF;
  SELECT available_tokens INTO v_bal1 FROM public.token_balances WHERE user_id = v_u1;
  SELECT available_tokens INTO v_bal2 FROM public.token_balances WHERE user_id = v_u2;

  -- Multi-copy smoke chit: supply 3 via the sanctioned flag (the mig-171 publish
  -- path in miniature), then prove the unflagged write is blocked.
  v_T := public.create_moment_chit('N2 smoke copies', 'gamer', 'creature', 'C');
  UPDATE public.moment_chits
  SET finalized_at = NOW(), original_minter_handle = '@n2_smoke_minter', source_platform = 'youtube'
  WHERE id = v_T;
  PERFORM set_config('nora.allow_supply_set', 'on', TRUE);
  UPDATE public.moment_chits SET total_supply = 3 WHERE id = v_T;
  PERFORM set_config('nora.allow_supply_set', 'off', TRUE);
  v_err := FALSE;
  BEGIN
    UPDATE public.moment_chits SET total_supply = 5 WHERE id = v_T;
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: unsanctioned total_supply write must RAISE'; END IF;

  -- Grant 3 → serials 1..3 created, owned by u1; invariant holds.
  PERFORM public.chit_grant(v_u1, v_T, 3, 'event');
  SELECT COUNT(*) INTO v_c FROM public.chit_copies
  WHERE chit_id = v_T AND owner_user_id = v_u1 AND state = 'owned';
  SELECT quantity INTO v_q FROM public.chit_ownership WHERE user_id = v_u1 AND chit_id = v_T;
  IF v_c <> 3 OR v_q <> 3 THEN
    RAISE EXCEPTION 'SMOKE FAIL: grant must create 3 owned copies (copies %, qty %)', v_c, v_q;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.chit_copies WHERE chit_id = v_T AND serial_number = 1)
     OR EXISTS (SELECT 1 FROM public.chit_copies WHERE chit_id = v_T AND serial_number > 3) THEN
    RAISE EXCEPTION 'SMOKE FAIL: serials must be exactly 1..3';
  END IF;

  -- Marketplace: list pins the LOWEST owned serial; buy transfers that exact copy.
  v_lst := public.marketplace_list_chit_internal(v_u1, v_T, 'token');
  SELECT * INTO v_row FROM public.chit_copies WHERE chit_id = v_T AND serial_number = 1;
  IF v_row.state <> 'listed_escrow' OR v_row.escrow_ref <> v_lst THEN
    RAISE EXCEPTION 'SMOKE FAIL: list must pin serial 1 (state %, ref %)', v_row.state, v_row.escrow_ref;
  END IF;
  PERFORM public.increment_token_balance(v_u2, 1000);
  PERFORM public.marketplace_buy_chit_internal(v_u2, v_lst);
  SELECT * INTO v_row FROM public.chit_copies WHERE chit_id = v_T AND serial_number = 1;
  IF v_row.owner_user_id <> v_u2 OR v_row.state <> 'owned' THEN
    RAISE EXCEPTION 'SMOKE FAIL: buy must transfer the pinned serial to the buyer';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.chit_copy_transfers
                 WHERE chit_id = v_T AND serial_number = 1
                   AND from_user_id = v_u1 AND to_user_id = v_u2
                   AND reason = 'marketplace_purchase') THEN
    RAISE EXCEPTION 'SMOKE FAIL: purchase transfer must be logged';
  END IF;

  -- Wager: both players stake copies of the SAME definition; the winner takes the
  -- loser's exact staked serial.
  v_match := public.ccg_create_wager_match(v_u1, NULL, v_T, v_u2, NULL, v_T, TRUE);
  SELECT * INTO v_row FROM public.chit_copies WHERE chit_id = v_T AND serial_number = 2;
  IF v_row.state <> 'wager_escrow' OR v_row.escrow_ref <> v_match OR v_row.owner_user_id <> v_u1 THEN
    RAISE EXCEPTION 'SMOKE FAIL: u1 stake must pin serial 2';
  END IF;
  SELECT * INTO v_row FROM public.chit_copies WHERE chit_id = v_T AND serial_number = 1;
  IF v_row.state <> 'wager_escrow' OR v_row.owner_user_id <> v_u2 THEN
    RAISE EXCEPTION 'SMOKE FAIL: u2 stake must pin serial 1';
  END IF;
  UPDATE public.ccg_matches SET status = 'finished', winner_seat = 1, finished_at = NOW()
  WHERE id = v_match;
  SELECT * INTO v_row FROM public.chit_copies WHERE chit_id = v_T AND serial_number = 1;
  IF v_row.owner_user_id <> v_u1 OR v_row.state <> 'owned' THEN
    RAISE EXCEPTION 'SMOKE FAIL: winner must take the loser''s exact staked serial';
  END IF;
  SELECT * INTO v_row FROM public.chit_copies WHERE chit_id = v_T AND serial_number = 2;
  IF v_row.owner_user_id <> v_u1 OR v_row.state <> 'owned' THEN
    RAISE EXCEPTION 'SMOKE FAIL: winner''s own stake must return';
  END IF;

  -- Generic transfer pairing (barter/gift shape: -N then +N, same ref+counterparty).
  PERFORM public.chit_grant(v_u1, v_T, -1, 'gift', v_gift, v_u2);
  SELECT * INTO v_row FROM public.chit_copies WHERE chit_id = v_T AND serial_number = 1;
  IF v_row.state <> 'released' OR v_row.transit_ref <> v_gift THEN
    RAISE EXCEPTION 'SMOKE FAIL: outbound leg must release the lowest owned serial';
  END IF;
  PERFORM public.chit_grant(v_u2, v_T, 1, 'gift', v_gift, v_u1);
  SELECT * INTO v_row FROM public.chit_copies WHERE chit_id = v_T AND serial_number = 1;
  IF v_row.owner_user_id <> v_u2 OR v_row.state <> 'owned' THEN
    RAISE EXCEPTION 'SMOKE FAIL: inbound leg must claim the released copy by ref';
  END IF;

  -- Supply exhaustion: all 3 serials live → a 4th copy can never exist.
  v_err := FALSE;
  BEGIN
    PERFORM public.chit_grant(v_u2, v_T, 1, 'event');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: supply exhaustion must RAISE (never inflate)'; END IF;

  -- Whole-table consistency: every (user, chit) quantity equals its owned copies.
  SELECT COUNT(*) INTO v_bad FROM (
    SELECT o.user_id, o.chit_id, o.quantity,
           (SELECT COUNT(*) FROM public.chit_copies c
            WHERE c.chit_id = o.chit_id AND c.owner_user_id = o.user_id
              AND c.state = 'owned') AS copies
    FROM public.chit_ownership o
  ) t WHERE t.quantity <> t.copies;
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'SMOKE FAIL: % (user, chit) rows where quantity <> owned copies', v_bad;
  END IF;

  -- Cleanup: dispose holdings (copies → released), restore balances, retire chit.
  -- (u1 holds serials 2+3, u2 holds serial 1 at this point.)
  PERFORM public.chit_grant(v_u1, v_T, -2, 'platform_correction');
  PERFORM public.chit_grant(v_u2, v_T, -1, 'platform_correction');
  SELECT available_tokens INTO v_cur FROM public.token_balances WHERE user_id = v_u1;
  PERFORM public.increment_token_balance(v_u1, v_bal1 - v_cur);
  SELECT available_tokens INTO v_cur FROM public.token_balances WHERE user_id = v_u2;
  PERFORM public.increment_token_balance(v_u2, v_bal2 - v_cur);
  UPDATE public.moment_chits
  SET is_active = FALSE, retired_at = NOW(), retired_reason = 'admin'
  WHERE id = v_T;

  RAISE NOTICE 'N2.1 smoke OK: serials 1..3, pinned escrows, exact-serial transfers, exhaustion guarded, invariant holds';
END $$;
