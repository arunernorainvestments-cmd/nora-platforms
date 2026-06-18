-- ─────────────────────────────────────────────────────────────────────────────
-- Migration 115 — Mobile IAP idempotency ledger (doc6: Arena/Battle mobile app)
-- The nora-arena mobile app sells token packs and Battle Chit packs through
-- RevenueCat (App Store + Google Play). On purchase confirmation the app calls the
-- mobile_iap_confirm edge function with the store purchase token. This table is the
-- idempotency anchor: purchase_token is the PRIMARY KEY, so a replayed / retried
-- confirmation can never double-credit (the function claims the row first, then
-- credits — see CLAUDE.md doc6 "token credit functions are idempotent").
--
-- Server-only. RLS is enabled with NO policies, so only the service-role edge
-- function can read or write it; clients never see raw receipts.
-- Runs after migration 114 (profiles.fcm_token_mobile).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.mobile_iap_receipts (
  -- RevenueCat / store transaction id. Globally unique → the idempotency key.
  purchase_token  TEXT PRIMARY KEY,
  user_id         UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  product_id      TEXT NOT NULL,
  store           TEXT,                                   -- app_store | play_store | sim
  -- What this receipt actually credited (filled in after the credit succeeds).
  -- Lets a replayed confirmation echo the original grant without re-crediting.
  tokens_credited INTEGER NOT NULL DEFAULT 0,
  chits_credited  JSONB   NOT NULL DEFAULT '[]'::jsonb,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS mobile_iap_receipts_user_id_idx
  ON public.mobile_iap_receipts (user_id);

-- Service-role only. No client SELECT/INSERT/UPDATE/DELETE policies, ever.
ALTER TABLE public.mobile_iap_receipts ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.mobile_iap_receipts IS
  'Idempotency ledger for nora-arena mobile in-app purchases (RevenueCat). '
  'purchase_token PK prevents double-credit on retries. Server-only (RLS, no policies).';
