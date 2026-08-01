-- Migration 182: the 30-card Standard Playset + the signup grant (Playset spec PHASE S2).
--
-- Every account holds a real deck on day one: 30 platform-authored starter cards, 2 copies
-- of each (60-card pool), granted free at signup. The playset is the FLOOR that makes the
-- one personal mint meaningful — "here's a real deck; now add YOUR moment to it".
--
-- Slate: 10 archetype families × 3 cards (2 creatures + 1 spell-moment), each card anchored
-- on one of that family's three authored Wave-1 effect templates (migs 123/152). Tier spread
-- F×10 · E×9 · D×7 · C×4 — NO A/S STARTERS (locked economy guard, enforced in
-- admin_seed_chit, asserted below). Every card is Lane A: an original meme-FORMAT /
-- trend-archetype brief, no real person, no third-party character, no specific existing
-- video (gate G-IP). Names are the sourcing briefs the render pipeline fills in.
--
-- REPO-CHECK resolutions:
--
--   1.2 (can 30 cards draw effects without tripping min_tier_band at F–C?) — YES, no
--     adjustment needed. All 30 Wave-1 templates are complexity = 1 with min_tier_band NULL
--     (mig 151 only gates compound Wave-2 templates), so every template is eligible at every
--     tier. The ladder does not disagree; the F10/E9/D7/C4 spread stands as specified.
--
--   S2.1 (backfill existing beta accounts?) — YES, backfill all (the spec default). Done at
--     the bottom of this migration for every non-test account; the same idempotent RPC then
--     covers new signups. Test/custody identities (Hard Rule 15) are excluded: they author
--     and hold custody, they never play.
--
--   S2.2 (extend the shipped onboarding, don't rebuild) — the shipped 6-page welcome tour
--     (flutter_app/lib/features/onboarding/widgets/welcome_tour.dart) gains one page for the
--     playset + the "now mint YOUR moment" CTA; the deck-builder and /collection surfaces are
--     unchanged apart from the starter badge. No new onboarding flow.
--
-- Grant safety: the signup trigger calls the grant BEST-EFFORT (a failure warns, it never
-- breaks account creation), and the client can always self-heal through claim_starter_playset().
-- Both paths are the same RPC, and its unit of idempotency is the (account, CARD) receipt
-- row — so "grant twice" is structurally impossible, AND a starter card authored after
-- launch tops up every existing account on the next call instead of reaching new signups
-- only. Adding cards later is the expected case, not an exception.

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. CONFIG + RECEIPT LEDGER
-- copies_per_card / is_enabled are the founder's sunset lever (§4 Q4): as the minted
-- supply grows, new-account playsets can shrink by UPDATE — config, not code.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.starter_playset_settings (
  id               BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
  is_enabled       BOOLEAN NOT NULL DEFAULT TRUE,
  copies_per_card  INTEGER NOT NULL DEFAULT 2 CHECK (copies_per_card BETWEEN 1 AND 2),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO public.starter_playset_settings (id) VALUES (TRUE) ON CONFLICT DO NOTHING;

COMMENT ON TABLE public.starter_playset_settings IS
  'Standard Playset grant config (spec S2). copies_per_card is capped at deck_max_copies() '
  '— a starter can never be granted more copies than a deck may legally run.';

-- The receipt is per (account, card), not per account. That is what makes the grant
-- idempotent AND top-up-aware: a starter card authored later is handed to accounts
-- that already hold the rest, exactly once, without a backfill script. The primary
-- key does the work — ON CONFLICT DO NOTHING means a double-grant is structurally
-- impossible even under concurrency, not merely unlikely.
CREATE TABLE IF NOT EXISTS public.starter_playset_grants (
  user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  chit_id     UUID NOT NULL REFERENCES public.moment_chits(id),
  copies      INTEGER NOT NULL CHECK (copies > 0),
  granted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, chit_id)
);

CREATE INDEX IF NOT EXISTS starter_playset_grants_user_idx
  ON public.starter_playset_grants (user_id, granted_at DESC);

COMMENT ON TABLE public.starter_playset_grants IS
  'One row per (account, starter card), forever: the receipt that makes '
  'grant_starter_playset idempotent per card, so cards added after launch top up '
  'existing accounts automatically.';

CREATE OR REPLACE FUNCTION public.starter_playset_grants_block_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'starter_playset_grants is append-only (no UPDATE/DELETE)';
END;
$$;

DROP TRIGGER IF EXISTS starter_playset_grants_no_mutation ON public.starter_playset_grants;
CREATE TRIGGER starter_playset_grants_no_mutation
  BEFORE UPDATE OR DELETE ON public.starter_playset_grants
  FOR EACH ROW EXECUTE FUNCTION public.starter_playset_grants_block_mutation();

ALTER TABLE public.starter_playset_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.starter_playset_grants   ENABLE ROW LEVEL SECURITY;

CREATE POLICY "starter_playset_settings_select_all" ON public.starter_playset_settings
  FOR SELECT USING (TRUE);
CREATE POLICY "starter_playset_grants_select_own" ON public.starter_playset_grants
  FOR SELECT USING (auth.uid() = user_id);
-- No client write policies: the RPC below is the only writer.

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. THE SLATE — 30 Lane-A briefs authored through the S1 seed path.
-- Idempotent: keyed on the moment slug, skipped wholesale if the playset already
-- exists (re-running is how a media upgrade lands, not how a second set appears).
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  r        RECORD;
  v_mom    UUID;
  v_tmpl   UUID;
  v_slug   TEXT;
  v_count  INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM public.moment_chits WHERE is_starter;
  IF v_count > 0 THEN
    RAISE NOTICE 'Standard Playset already seeded (% cards) — slate insert skipped', v_count;
    RETURN;
  END IF;

  FOR r IN
    SELECT * FROM (VALUES
      -- name, family, chit_type, tier, effect template key, extra keywords, brief/flavor
      -- ── athlete — stadium / sports-glory energy (authored timeless, not WC-specific)
      ('Last-Minute Volley',        'athlete',    'creature',     'F', 'athlete_on_summon_rush',        ARRAY['charge']::TEXT[],  'The strike that arrives a heartbeat before the whistle.'),
      ('Trophy-Lift Roar',          'athlete',    'creature',     'E', 'athlete_on_summon_highlight',   '{}'::TEXT[],             'Both arms up, the whole stand goes with them.'),
      ('Comeback Breath',           'athlete',    'spell_moment', 'D', 'athlete_activated_secondwind',  '{}'::TEXT[],             'Hands on knees, then somehow going again.'),

      -- ── musician — escalation formats ("it gets louder")
      ('Volume Rising',             'musician',   'creature',     'F', 'musician_on_summon_encore',     '{}'::TEXT[],             'It was background music four seconds ago.'),
      ('Mosh Pit Surge',            'musician',   'creature',     'E', 'musician_on_summon_moshpit',    '{}'::TEXT[],             'The floor becomes one animal.'),
      ('Slow Ballad',               'musician',   'spell_moment', 'D', 'musician_activated_ballad',     '{}'::TEXT[],             'The one everybody films with a phone light.'),

      -- ── artist — creator-life / studio chaos
      ('Mural Sunrise',             'artist',     'creature',     'F', 'artist_on_summon_inspire',      '{}'::TEXT[],             'A wall that was grey at midnight.'),
      ('The Muse Visits',           'artist',     'creature',     'E', 'artist_triggered_muse',         '{}'::TEXT[],             'Always at 3am, never at the desk.'),
      ('Masterpiece Reveal',        'artist',     'spell_moment', 'D', 'artist_on_summon_masterpiece',  '{}'::TEXT[],             'The cloth comes off. Nobody breathes.'),

      -- ── scientist — science / tech spectacle
      ('Rocket Sticks the Landing', 'scientist',  'creature',     'F', 'scientist_on_summon_experiment','{}'::TEXT[],             'Legs out, dust up, dead centre.'),
      ('Lab Coat Aegis',            'scientist',  'creature',     'E', 'scientist_activated_formula',   ARRAY['shield']::TEXT[],  'Safety goggles are, in fact, load-bearing.'),
      ('Containment Purge',         'scientist',  'spell_moment', 'C', 'scientist_activated_purge',     '{}'::TEXT[],             'Whatever that was, it is not any more.'),

      -- ── comedian — 2016-nostalgia wave (the Great Meme Reset)
      ('Frozen Crowd',              'comedian',   'creature',     'F', 'comedian_on_summon_heckle',     '{}'::TEXT[],             'Everyone stops mid-step. The camera walks through.'),
      ('Punchline Lands',           'comedian',   'creature',     'E', 'comedian_on_summon_punchline',  '{}'::TEXT[],             'A half-second of silence, then the room goes.'),
      ('The Roast',                 'comedian',   'spell_moment', 'D', 'comedian_activated_roast',      '{}'::TEXT[],             'Said with love. Mostly.'),

      -- ── influencer — creator-life self-reference
      ('Ring Light Down!',          'influencer', 'creature',     'F', 'influencer_on_summon_viral',    ARRAY['stealth']::TEXT[], 'The take was perfect right up until it was not.'),
      ('1M Subs Button',            'influencer', 'creature',     'E', 'influencer_on_summon_trending', '{}'::TEXT[],             'Unboxed on camera, obviously.'),
      ('The Clapback',              'influencer', 'spell_moment', 'C', 'influencer_activated_clapback', '{}'::TEXT[],             'Typed, deleted, typed again, posted.'),

      -- ── politician — absurdist-news energy
      ('Breaking: Local Legend',    'politician', 'creature',     'F', 'politician_trig_rally',         '{}'::TEXT[],             'Six o''clock news, and the whole town already knew.'),
      ('Take the Podium',           'politician', 'creature',     'E', 'politician_on_summon_takethehit',ARRAY['taunt']::TEXT[],  'Steps up so nobody else has to.'),
      ('The Filibuster',            'politician', 'spell_moment', 'D', 'politician_activated_filibuster','{}'::TEXT[],            'Reading the phone book, with feeling.'),

      -- ── business — absurdist-news / heist energy
      ('The Great Chocolate Caper', 'business',   'creature',     'F', 'business_on_summon_dividend',   '{}'::TEXT[],             'A truck. A warehouse. An unreasonable amount of cocoa.'),
      ('Overnight Empire',          'business',   'creature',     'E', 'business_on_summon_investment', ARRAY['taunt']::TEXT[],   'Founded in a kitchen, defended like a fortress.'),
      ('Hostile Acquisition',       'business',   'spell_moment', 'D', 'business_activated_acquisition','{}'::TEXT[],             'The offer nobody could refuse, itemised.'),

      -- ── gamer — open-world chaos (get-ahead cluster; original city, original NPCs)
      ('Physics Glitch Ballet',     'gamer',      'creature',     'F', 'gamer_on_summon_multikill',     ARRAY['charge']::TEXT[],  'The engine invents a new dance and commits to it.'),
      ('NPC Moment',                'gamer',      'creature',     'C', 'gamer_activated_grind',         ARRAY['stealth']::TEXT[], 'Background character. Main-character energy.'),
      ('Five-Star Getaway',         'gamer',      'spell_moment', 'C', 'gamer_activated_snipe',         '{}'::TEXT[],             'Every siren in the city, one alley.'),

      -- ── actor — 2016-nostalgia + Q4 seasonal
      ('The Understudy',            'actor',      'creature',     'F', 'actor_counter_understudy',      ARRAY['shield']::TEXT[],  'Learned every line for a night that finally came.'),
      ('Costume Reveal',            'actor',      'creature',     'E', 'actor_triggered_recovery',      '{}'::TEXT[],             'Two hours of latex for four seconds of screaming.'),
      ('Stunt Double Swap',         'actor',      'spell_moment', 'D', 'actor_on_summon_stuntdouble',   '{}'::TEXT[],             'Same jacket, braver knees.')
    ) AS s(name, family, chit_type, tier, tmpl_key, keywords, flavor)
  LOOP
    v_slug := 'playset:' || lower(regexp_replace(r.name, '[^a-zA-Z0-9]+', '-', 'g'));

    SELECT id INTO v_tmpl FROM public.effect_templates WHERE key = r.tmpl_key;
    IF v_tmpl IS NULL THEN
      RAISE EXCEPTION 'Playset slate references unknown effect template %', r.tmpl_key;
    END IF;

    -- 1. platform source record (tier target = engagement band floor, S1.2)
    v_mom := public.admin_seed_moment(v_slug, r.tier, NULL, r.name);

    -- 2. pre-generation moderation — platform content is NOT exempt (spec S1).
    --    Sim verdict at seed time; the live render pass re-runs the real classifier on
    --    the generated MP4 before admin_seed_attach_media will accept it.
    PERFORM public.moment_pre_gen_moderate(
      v_mom, 'approved',
      jsonb_build_object('lane', 'A_original_format', 'brief', r.name, 'real_person', FALSE),
      FALSE, 'sim');

    -- 3. mint through the sanctioned path (ladder-derived stats, generic + starter stamps)
    PERFORM public.admin_seed_chit(
      v_mom, r.name, r.family, r.chit_type, v_tmpl, r.keywords, r.flavor, NULL, TRUE, NULL);
  END LOOP;

  RAISE NOTICE 'Standard Playset seeded: 30 Lane-A starter cards';
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. grant_starter_playset — each starter card, once per account, forever.
--
-- Top-up semantics, deliberately: the unit of idempotency is the CARD, not the
-- account. Re-running for an account that holds the whole set is a no-op; running
-- it after a new starter card is authored hands over exactly that card. Without
-- this, every post-launch addition would need a hand-written backfill and would
-- silently skip everyone who signed up before it existed.
--
-- The receipt INSERT is what decides: rows that survive ON CONFLICT DO NOTHING are
-- the cards this account has never been given, and only those are granted. A
-- concurrent second call loses the conflict and grants nothing, so double-granting
-- is impossible by construction (the advisory lock is belt to that suspenders).
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.grant_starter_playset(p_user UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_cfg    public.starter_playset_settings%ROWTYPE;
  v_copies INTEGER;
  v_cards  INTEGER := 0;
  r        RECORD;
BEGIN
  IF p_user IS NULL THEN RAISE EXCEPTION 'grant_starter_playset needs a user'; END IF;

  SELECT * INTO v_cfg FROM public.starter_playset_settings WHERE id;
  IF NOT COALESCE(v_cfg.is_enabled, TRUE) THEN
    RETURN jsonb_build_object('granted', FALSE, 'reason', 'disabled', 'cards', 0);
  END IF;

  -- A starter can never be granted more copies than a deck may legally run.
  v_copies := LEAST(COALESCE(v_cfg.copies_per_card, 2), public.deck_max_copies());

  PERFORM pg_advisory_xact_lock(hashtextextended('starter_playset:' || p_user::TEXT, 42));

  FOR r IN
    INSERT INTO public.starter_playset_grants (user_id, chit_id, copies)
    SELECT p_user, mc.id, v_copies
    FROM public.moment_chits mc
    WHERE mc.is_starter AND mc.is_active AND mc.retired_at IS NULL
    ON CONFLICT (user_id, chit_id) DO NOTHING
    RETURNING chit_id
  LOOP
    PERFORM public.chit_grant(p_user, r.chit_id, v_copies, 'starter_grant');
    v_cards := v_cards + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'granted',     v_cards > 0,
    'reason',      CASE WHEN v_cards > 0 THEN 'granted' ELSE 'up_to_date' END,
    'cards',       v_cards,
    'copies_each', v_copies);
END;
$$;

-- Client-callable self-heal: idempotent by construction, so exposing it costs nothing
-- and covers accounts whose signup-time grant failed (or predates this migration).
CREATE OR REPLACE FUNCTION public.claim_starter_playset()
RETURNS JSONB
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.grant_starter_playset(auth.uid());
$$;

-- Operator health check: how many real accounts are missing how many starters.
-- With a per-card receipt, "rows in starter_playset_grants" is no longer a headcount,
-- so the tooling asks this instead of counting rows and guessing.
CREATE OR REPLACE FUNCTION public.starter_playset_coverage()
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'starter_cards',    (SELECT COUNT(*) FROM public.moment_chits
                         WHERE is_starter AND is_active AND retired_at IS NULL),
    'accounts',         (SELECT COUNT(*) FROM public.profiles WHERE NOT is_test_account),
    'fully_granted',    (SELECT COUNT(*) FROM (
                           SELECT g.user_id FROM public.starter_playset_grants g
                           JOIN public.profiles p ON p.id = g.user_id AND NOT p.is_test_account
                           GROUP BY g.user_id
                           HAVING COUNT(*) >= (SELECT COUNT(*) FROM public.moment_chits
                                               WHERE is_starter AND is_active AND retired_at IS NULL)
                         ) t),
    'card_grants',      (SELECT COUNT(*) FROM public.starter_playset_grants));
$$;

REVOKE ALL ON FUNCTION public.grant_starter_playset(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.starter_playset_coverage() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_starter_playset() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_starter_playset() TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. SIGNUP WIRING — mig 021's handle_new_user body verbatim plus the marked block.
-- BEST-EFFORT: the playset is a nice-to-have at t=0 and account creation is not. A
-- failure here warns and lets signup finish; claim_starter_playset() then heals it on
-- the client's first authenticated call.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger AS $$
DECLARE
  v_referral_code     text;
  v_referred_by_code  text;
  v_referrer_id       uuid;
  v_is_approved       boolean;
BEGIN
  LOOP
    v_referral_code := lower(substring(md5(random()::text), 1, 8));
    EXIT WHEN NOT EXISTS (
      SELECT 1 FROM public.profiles WHERE referral_code = v_referral_code
    );
  END LOOP;

  v_referred_by_code := new.raw_user_meta_data->>'referred_by_code';
  IF v_referred_by_code IS NOT NULL THEN
    SELECT id INTO v_referrer_id
    FROM public.profiles
    WHERE referral_code = v_referred_by_code;
  END IF;

  SELECT (approved_at IS NOT NULL) INTO v_is_approved
  FROM public.waitlist
  WHERE email = lower(new.email)
  LIMIT 1;

  v_is_approved := COALESCE(v_is_approved, false);

  INSERT INTO public.profiles (id, display_name, avatar_url, referral_code, referred_by, is_approved)
  VALUES (
    new.id,
    new.raw_user_meta_data->>'full_name',
    new.raw_user_meta_data->>'avatar_url',
    v_referral_code,
    v_referrer_id,
    v_is_approved
  );

  INSERT INTO public.balances (user_id) VALUES (new.id);

  INSERT INTO public.token_balances (user_id, available_tokens, lifetime_earned)
  VALUES (new.id, 100, 100);

  INSERT INTO public.token_transactions (user_id, type, amount, description)
  VALUES (new.id, 'signup_bonus', 100, 'Welcome bonus — 100 free tokens');

  IF v_referrer_id IS NOT NULL THEN
    UPDATE public.token_balances
    SET available_tokens = available_tokens + 25,
        lifetime_earned  = lifetime_earned  + 25,
        updated_at       = now()
    WHERE user_id = v_referrer_id;

    INSERT INTO public.token_transactions (user_id, type, amount, reference_id, description)
    VALUES (v_referrer_id, 'referral_bonus', 25, new.id, 'Referral bonus — new user signed up with your code');
  END IF;

  -- ── S2 (mig 182): the Standard Playset, best-effort ──────────────────────────
  BEGIN
    PERFORM public.grant_starter_playset(new.id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'starter playset grant failed for % (%) — claim_starter_playset will heal it',
      new.id, SQLERRM;
  END;

  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. BACKFILL (REPO-CHECK S2.1: all existing accounts).
-- Test/custody identities are excluded (Hard Rule 15): the playset identity, the
-- Mystery Pool custodian and the smoke users author and hold, they never play.
-- ═══════════════════════════════════════════════════════════════════════════════
-- The grant is idempotent per card, so this is just "run it for everyone" — the same
-- call is what tops accounts up whenever a new starter card is authored later.
DO $$
DECLARE r RECORD; v_res JSONB; v_n INTEGER := 0; v_cards INTEGER := 0;
BEGIN
  FOR r IN
    SELECT p.id FROM public.profiles p
    WHERE NOT COALESCE(p.is_test_account, FALSE)
  LOOP
    v_res := public.grant_starter_playset(r.id);
    IF (v_res->>'cards')::INTEGER > 0 THEN
      v_n := v_n + 1;
      v_cards := v_cards + (v_res->>'cards')::INTEGER;
    END IF;
  END LOOP;
  RAISE NOTICE 'Standard Playset: % card grant(s) across % account(s)', v_cards, v_n;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- APPLY-TIME SMOKE — the slate's shape is the product promise, so it is asserted,
-- not assumed: 30 cards · the exact tier spread · no A/S · all four timing types ·
-- all four keywords · every ACTIVE launch fusion rule discoverable with starters
-- alone · a legal 20-card starter-only deck · grant idempotency.
-- The deck/grant legs run in a rollback-sentinel subtxn (mig 150/157) — no residue.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_n INTEGER; v_bad INTEGER; v_spread TEXT; r RECORD;
  v_u UUID; v_deck UUID; v_res JSONB; v_g1 JSONB; v_g2 JSONB; v_chits JSONB;
  v_mom UUID; v_new UUID;
BEGIN
  -- ── slate shape ──────────────────────────────────────────────────────────────
  SELECT COUNT(*) INTO v_n FROM public.moment_chits WHERE is_starter;
  IF v_n <> 30 THEN RAISE EXCEPTION 'SMOKE FAIL: playset must be 30 cards (got %)', v_n; END IF;

  SELECT COUNT(*) INTO v_bad FROM public.moment_chits
  WHERE is_starter AND (NOT is_generic OR seed_source IS DISTINCT FROM 'platform'
        OR finalized_at IS NULL OR original_minter_handle <> 'NORA');
  IF v_bad > 0 THEN RAISE EXCEPTION 'SMOKE FAIL: % starter(s) missing platform stamps', v_bad; END IF;

  SELECT string_agg(tier || ':' || n, ' ' ORDER BY tier) INTO v_spread
  FROM (SELECT tier, COUNT(*) AS n FROM public.moment_chits WHERE is_starter GROUP BY tier) t;
  IF v_spread <> 'C:4 D:7 E:9 F:10' THEN
    RAISE EXCEPTION 'SMOKE FAIL: tier spread must be F10/E9/D7/C4 (got %)', v_spread;
  END IF;

  SELECT COUNT(*) INTO v_bad FROM public.moment_chits WHERE is_starter AND tier IN ('A','S','B');
  IF v_bad > 0 THEN RAISE EXCEPTION 'SMOKE FAIL: % starter(s) above tier C', v_bad; END IF;

  -- 10 families × 3 cards, each family 2 creatures + 1 spell
  SELECT COUNT(*) INTO v_bad FROM (
    SELECT archetype_family,
           COUNT(*) AS n,
           COUNT(*) FILTER (WHERE chit_type = 'creature')     AS creatures,
           COUNT(*) FILTER (WHERE chit_type = 'spell_moment') AS spells
    FROM public.moment_chits WHERE is_starter GROUP BY archetype_family
  ) t WHERE t.n <> 3 OR t.creatures <> 2 OR t.spells <> 1;
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'SMOKE FAIL: % family/families are not 2 creatures + 1 spell', v_bad;
  END IF;

  -- ── coverage: timings, keywords ──────────────────────────────────────────────
  FOR r IN SELECT unnest(ARRAY['on_summon','activated','triggered','counter']) AS t LOOP
    IF NOT EXISTS (SELECT 1 FROM public.moment_chits WHERE is_starter AND timing_type = r.t) THEN
      RAISE EXCEPTION 'SMOKE FAIL: no starter covers timing type %', r.t;
    END IF;
  END LOOP;

  FOR r IN SELECT unnest(ARRAY['taunt','charge','shield','stealth']) AS k LOOP
    IF NOT EXISTS (SELECT 1 FROM public.moment_chits WHERE is_starter AND r.k = ANY(keywords)) THEN
      RAISE EXCEPTION 'SMOKE FAIL: no starter carries keyword %', r.k;
    END IF;
  END LOOP;

  -- ── coverage: fusion is DISCOVERABLE with starters alone ────────────────────
  -- Every active launch rule needs min_count qualifying starter CREATURES (fusion
  -- detection matches summoned creatures, mig 128).
  FOR r IN SELECT * FROM public.fusion_rules WHERE is_active LOOP
    SELECT COUNT(*) INTO v_n
    FROM public.moment_chits mc
    WHERE mc.is_starter AND mc.chit_type = 'creature'
      AND (r.match_family  IS NULL OR mc.archetype_family = r.match_family)
      AND (r.match_keyword IS NULL OR r.match_keyword = ANY(mc.keywords));
    IF v_n < r.min_count THEN
      RAISE EXCEPTION 'SMOKE FAIL: fusion rule % needs % starter creatures, playset offers %',
        r.key, r.min_count, v_n;
    END IF;
  END LOOP;

  -- ── the grant: legal starter-only deck + idempotency ────────────────────────
  BEGIN
    v_u := gen_random_uuid();
    INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at, raw_user_meta_data)
    VALUES (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'playset-smoke@noraplatforms.com', '', NOW(), NOW(), NOW(),
            '{"full_name":"Playset Smoke"}');
    -- (handle_new_user already granted the playset on that INSERT — that IS the wiring test)
    UPDATE public.profiles SET is_test_account = TRUE WHERE id = v_u;

    IF NOT EXISTS (SELECT 1 FROM public.starter_playset_grants WHERE user_id = v_u) THEN
      RAISE EXCEPTION 'SMOKE FAIL: signup must grant the playset';
    END IF;

    SELECT COUNT(*) INTO v_n FROM public.chit_ownership co
    JOIN public.moment_chits mc ON mc.id = co.chit_id
    WHERE co.user_id = v_u AND mc.is_starter AND co.quantity = 2;
    IF v_n <> 30 THEN
      RAISE EXCEPTION 'SMOKE FAIL: new account must hold 2 copies of all 30 starters (got %)', v_n;
    END IF;

    -- a second grant is a no-op, and holdings do not move
    v_g1 := public.grant_starter_playset(v_u);
    IF (v_g1->>'granted')::BOOLEAN OR (v_g1->>'cards')::INTEGER <> 0 THEN
      RAISE EXCEPTION 'SMOKE FAIL: the playset must never be granted twice (%)', v_g1;
    END IF;
    SELECT COALESCE(SUM(quantity), 0) INTO v_n FROM public.chit_ownership co
    JOIN public.moment_chits mc ON mc.id = co.chit_id
    WHERE co.user_id = v_u AND mc.is_starter;
    IF v_n <> 60 THEN
      RAISE EXCEPTION 'SMOKE FAIL: starter pool must stay at 60 copies (got %)', v_n;
    END IF;

    -- TOP-UP: a starter card authored AFTER this account was granted reaches it on
    -- the next call — exactly that card, exactly once, nothing else re-granted.
    v_mom := public.admin_seed_moment('playset:s2-topup-smoke', 'F', NULL, 'Top-up smoke');
    PERFORM public.moment_pre_gen_moderate(v_mom, 'approved', NULL, FALSE, 'sim');
    v_new := public.admin_seed_chit(v_mom, 'S2 top-up smoke card', 'gamer', 'creature',
               (SELECT id FROM public.effect_templates WHERE key = 'gamer_on_summon_multikill'));
    v_g2 := public.grant_starter_playset(v_u);
    IF NOT (v_g2->>'granted')::BOOLEAN OR (v_g2->>'cards')::INTEGER <> 1 THEN
      RAISE EXCEPTION 'SMOKE FAIL: a newly authored starter must top up exactly 1 card (%)', v_g2;
    END IF;
    SELECT quantity INTO v_n FROM public.chit_ownership WHERE user_id = v_u AND chit_id = v_new;
    IF v_n <> 2 THEN
      RAISE EXCEPTION 'SMOKE FAIL: the topped-up card must land as 2 copies (got %)', v_n;
    END IF;
    SELECT COALESCE(SUM(quantity), 0) INTO v_n FROM public.chit_ownership co
    JOIN public.moment_chits mc ON mc.id = co.chit_id
    WHERE co.user_id = v_u AND mc.is_starter;
    IF v_n <> 62 THEN
      RAISE EXCEPTION 'SMOKE FAIL: top-up must add 2 copies and re-grant nothing (got %)', v_n;
    END IF;
    -- and a third call is a no-op again
    v_g2 := public.grant_starter_playset(v_u);
    IF (v_g2->>'cards')::INTEGER <> 0 THEN
      RAISE EXCEPTION 'SMOKE FAIL: the top-up itself must be idempotent (%)', v_g2;
    END IF;

    -- a 20-card deck built from starters alone is LEGAL (10 uniques × 2)
    INSERT INTO public.decks (user_id, name) VALUES (v_u, 'Starter smoke') RETURNING id INTO v_deck;
    SELECT jsonb_agg(jsonb_build_object('chit_id', id, 'quantity', 2)) INTO v_chits
    FROM (SELECT id FROM public.moment_chits WHERE is_starter ORDER BY tier, name LIMIT 10) s;
    INSERT INTO public.deck_chits (deck_id, chit_id, quantity)
    SELECT v_deck, (e->>'chit_id')::UUID, (e->>'quantity')::INTEGER
    FROM jsonb_array_elements(v_chits) AS e;
    v_res := public.deck_validate(v_deck);
    IF NOT (v_res->>'is_valid')::BOOLEAN THEN
      RAISE EXCEPTION 'SMOKE FAIL: a starter-only deck must be legal (%)', v_res;
    END IF;

    -- starters are unserialized (mig 181 S1.4): 60 copies, zero copy rows
    SELECT COUNT(*) INTO v_n FROM public.chit_copies cc
    JOIN public.moment_chits mc ON mc.id = cc.chit_id WHERE mc.is_starter;
    IF v_n <> 0 THEN
      RAISE EXCEPTION 'SMOKE FAIL: starters must never be serialized (got % copy rows)', v_n;
    END IF;

    RAISE EXCEPTION 'SMOKE_ROLLBACK_OK';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'SMOKE_ROLLBACK_OK' THEN
        RAISE NOTICE 'S2 smoke OK: 30 cards F10/E9/D7/C4, all timings + keywords, every fusion rule discoverable, signup grants once, starter-only deck legal';
      ELSE
        RAISE;
      END IF;
  END;
END $$;
