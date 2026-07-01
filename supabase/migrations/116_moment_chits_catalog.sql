-- Migration 116: v3 moment-chit catalog (Phase 1 — the asset definition layer).
--
-- The "moment chit" is the v3 card asset: a creature or spell-moment minted from a
-- real viral social moment. This is DISTINCT from the legacy powerup system in
-- `battle_chit_definitions`/`user_battle_chits` (mig 086, now dormant — Hard Rule 27).
--
-- Tier/cost/atk/hp/effect are DERIVED from the tier ladder (P2) at mint (P6), never
-- user-set (Hard Rule 34). Enforcement: RLS grants public SELECT only; all writes go
-- through SECURITY DEFINER paths (mint P6, pack grant, seed). No client INSERT/UPDATE.
--
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 1; plan P1.1.

-- ── moments (minimal anchor; the P6 minting pipeline fills the rest) ─────────────
-- A chit is minted FROM a moment. The moment records the owner (who earns the
-- creator/passive payout slices in P5 — "summon your friend, your friend earns") and
-- the consent + engagement signals the tier assignment reads. Kept minimal here;
-- Phase 6 (minting) expands social-link / animation / moderation fields.
CREATE TABLE public.moments (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id         UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  source_platform       TEXT,                       -- 'tiktok' | 'instagram' | ... (P6)
  source_external_id    TEXT,                        -- platform post id
  source_url            TEXT,
  thumbnail_url         TEXT,                         -- becomes the chit card art
  consent_granted_at    TIMESTAMPTZ,                  -- consent recorded at social link (P6)
  engagement_count      BIGINT NOT NULL DEFAULT 0,    -- normalized post-engagement (tier signal)
  engagement_synced_at  TIMESTAMPTZ,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (source_platform, source_external_id)
);

CREATE INDEX moments_owner_idx ON public.moments (owner_user_id);

-- ── moment_chits (the catalog / chit definition) ────────────────────────────────
CREATE TABLE public.moment_chits (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Provenance. NULL moment_id allowed for licensed/system chits that don't originate
  -- from a user social post (licensed packs carry the licensor, not a user moment).
  moment_id           UUID REFERENCES public.moments(id) ON DELETE SET NULL,

  name                TEXT NOT NULL,
  description         TEXT,

  -- Value layer (base vs premium).
  character_class     TEXT NOT NULL DEFAULT 'consent_minted'
    CHECK (character_class IN ('consent_minted','licensed')),

  -- Card kind.
  chit_type           TEXT NOT NULL
    CHECK (chit_type IN ('creature','spell_moment')),

  -- Effect-family classifier (the only surviving meaning of "archetype"). The v3
  -- canonical 10 families. (Legacy category set adds healthcare/performer/educator/
  -- religion — those are mapped into these 10 by classification, never stored here.)
  archetype_family    TEXT NOT NULL CHECK (archetype_family IN (
    'athlete','musician','artist','scientist','comedian',
    'influencer','politician','business','gamer','actor'
  )),

  -- Balance (cost-banded tier — Hard Rule 34). All derived from the tier ladder (P2).
  tier                TEXT NOT NULL CHECK (tier IN ('F','E','D','C','B','A','S')),
  aura_cost           INTEGER NOT NULL CHECK (aura_cost >= 0),
  atk                 INTEGER CHECK (atk >= 0),   -- creatures only
  hp                  INTEGER CHECK (hp >= 0),    -- creatures only

  -- Effect model (vocabulary enforced here; templates/magnitudes land in P2/P3).
  timing_type         TEXT CHECK (timing_type IN ('on_summon','activated','triggered','counter')),
  keywords            TEXT[] NOT NULL DEFAULT '{}'
    CHECK (keywords <@ ARRAY['taunt','charge','shield','stealth']::TEXT[]),
  effect_ref          UUID,   -- FK to effect_templates added in P2 (nullable until then)

  -- Second resource gate: minimum Vibe (0–100) required to play. NULL = ungated.
  vibe_gate           INTEGER CHECK (vibe_gate BETWEEN 0 AND 100),

  -- Presentation (shared-3D summon compositing — P3 client contract).
  card_art_url        TEXT,
  moment_video_ref    TEXT,

  is_active           BOOLEAN NOT NULL DEFAULT TRUE,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- creatures carry ATK+HP (no AP); spell-moments carry neither.
  CONSTRAINT moment_chits_stat_shape CHECK (
    (chit_type = 'creature'     AND atk IS NOT NULL AND hp IS NOT NULL) OR
    (chit_type = 'spell_moment' AND atk IS NULL     AND hp IS NULL)
  )
);

CREATE INDEX moment_chits_active_idx  ON public.moment_chits (is_active);
CREATE INDEX moment_chits_family_idx  ON public.moment_chits (archetype_family, tier);
CREATE INDEX moment_chits_moment_idx  ON public.moment_chits (moment_id);
CREATE INDEX moment_chits_class_idx   ON public.moment_chits (character_class);

COMMENT ON TABLE public.moment_chits IS
  'v3 card-battler asset catalog (creatures + spell-moments). Distinct from legacy '
  'battle_chit_definitions powerups (Hard Rule 27). Stats are tier-ladder-derived, '
  'never user-set (Hard Rule 34); writes are server-only (mint P6 / pack grant / seed).';

-- ── RLS: catalog is public-read; no client writes (server-authoritative) ────────
ALTER TABLE public.moments      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.moment_chits ENABLE ROW LEVEL SECURITY;

-- Owners can see their own moments; catalog rows readable when active.
CREATE POLICY "moments_select_own" ON public.moments
  FOR SELECT USING (auth.uid() = owner_user_id);

CREATE POLICY "moment_chits_select_active" ON public.moment_chits
  FOR SELECT USING (is_active);

-- No INSERT/UPDATE/DELETE policies: only SECURITY DEFINER functions (owner role,
-- which bypasses RLS) and migrations may write. This is the "users never set power"
-- enforcement (Hard Rule 34).

-- ── updated_at touch ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.touch_moment_chit_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER moment_chits_touch_updated
  BEFORE UPDATE ON public.moment_chits
  FOR EACH ROW EXECUTE FUNCTION public.touch_moment_chit_updated_at();
