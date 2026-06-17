# NORA Redesign — Doc 5: Right of Publicity Licensing Marketplace
# For Claude Code — Read in full before touching any file.
# Migrations begin at 108. Apply after docs 1–4.
# Companion docs: doc1–4, doc6_mobile_app.md

---

## CLAUDE CODE SELF-AUDIT PROTOCOL
## Run this checklist before implementing any section below.

1. READ these files in full before writing a single line:
   - CLAUDE.md (canonical rules — nothing in this spec overrides them)
   - docs/scoring-and-db-spec.md (verify no table name conflicts)
   - docs/infra.md (verify no edge function name conflicts)
   - docs/campaigns-framework.md (archived — do not resurrect)
   - Current highest migration number in supabase/migrations/ (confirm it is 107)
   - All routes in lib/router.dart (verify new routes are unique)

2. VERIFY before each migration:
   - Migration number does not already exist in supabase/migrations/
   - No new table name duplicates an existing table
   - No new edge function name duplicates an existing function
   - All table/column references to existing schema use exact current names

3. RESOLVE CONFLICTS this way:
   - Spec references a table that was renamed or doesn't exist → find the current
     equivalent and adjust the spec's SQL before running
   - Spec contradicts a CLAUDE.md hard rule → STOP and flag before proceeding
   - An existing migration already covers some of this ground → skip those parts
     and add a comment noting the existing migration that handles it

4. ADJUSTMENT PRINCIPLE:
   - This spec describes intent. The SQL is a starting point, not sacred.
   - If the codebase requires a different approach to achieve the same outcome,
     make it and leave a // ADJUSTED: [reason] comment inline.
   - When in doubt between this spec and CLAUDE.md: CLAUDE.md wins.

---

## What This Document Builds

N.O.R.A. Platforms is repositioned as a Right of Publicity licensing marketplace.
Individuals and entities sell licenses to their likeness and image. Buyers hold
verifiable legal rights to use that likeness within the parameters the licensor sets.
N.O.R.A. is the source of truth. A public REST API allows any third-party platform
to verify license validity in real time.

This is not a financial product. Licenses are commercial agreements for intellectual
property use rights, governed by the Right of Publicity.

---

## Architecture Overview

```
Licensor (creator/celeb/agent)
  → creates a listing on N.O.R.A. Platforms
  → sets parameters via toggle UI → AI generates legal contract language
  → listing goes live in marketplace

Buyer (licensee)
  → browses, purchases license
  → receives signed license record (license_id + signed JSON)
  → can use the license on any compliant platform

Third-party platform (Spotify, AI tool, Arena/Battle app, etc.)
  → calls api.noraplatforms.com/v1/verify
  → N.O.R.A. returns signed response: valid/invalid + restrictions
  → platform decides whether to allow the use
```

N.O.R.A. never holds funds. Stripe processes payments.
License records are append-only (blockchain-ready).
The REST API is public, free up to tier limits, cryptographically signed.

---

## Revenue Model

| Event | Fee |
|---|---|
| License listing | Free |
| License sale | 5% commission (deducted from sale price before creator receives funds) |
| Verification API calls | Free tier: 1,000 calls/day per API key |
| Verification API (commercial) | $0.001 per call above free tier |
| Partners Portal application | Free |
| Featured listing placement | Future (post-launch) |

---

## Migration 108 — Licensor Profiles & Verification

File: `supabase/migrations/108_lkn_licensors.sql`

```sql
-- Licensor verification tiers:
-- Tier 1: Self — individual using their own likeness (KYC only)
-- Tier 2: Agent — management/label/legal rep acting for talent (Partners Portal)
-- Tier 3: Platform-verified celeb — from existing celebs table (celebrity-integration-seed)

ALTER TABLE profiles
  ADD COLUMN lkn_licensor_status TEXT DEFAULT NULL
    CHECK (lkn_licensor_status IN ('pending', 'verified', 'suspended', 'rejected')),
  ADD COLUMN lkn_licensor_tier  TEXT DEFAULT NULL
    CHECK (lkn_licensor_tier IN ('self', 'agent', 'celeb')),
  ADD COLUMN lkn_verified_at    TIMESTAMPTZ;

-- Licensor verification records (one per verification event)
CREATE TABLE lkn_licensor_verifications (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                     UUID NOT NULL REFERENCES auth.users(id),

  verification_tier           TEXT NOT NULL CHECK (verification_tier IN ('self','agent','celeb')),

  -- Tier 1 (self): KYC + social media links
  kyc_verification_id         UUID REFERENCES kyc_verifications(id),
  -- Minimum 1 linked platform required for self-tier
  linked_platform_count       INTEGER NOT NULL DEFAULT 0,

  -- Tier 2 (agent): Partners Portal approval
  partner_application_id      UUID,  -- FK to lkn_partners below

  -- Tier 3 (celeb): linked from celebs table
  celeb_id                    UUID REFERENCES celebs(id),

  status                      TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','approved','rejected')),
  reviewed_by                 UUID REFERENCES auth.users(id),  -- N.O.R.A. staff account
  reviewed_at                 TIMESTAMPTZ,
  rejection_reason            TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX lkn_verif_user_idx   ON lkn_licensor_verifications (user_id, status);
CREATE INDEX lkn_verif_status_idx ON lkn_licensor_verifications (status, created_at DESC);

-- N.O.R.A. Partners Portal submissions
-- Management, labels, legal reps apply here to act on behalf of talent.
CREATE TABLE lkn_partners (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Applicant contact
  company_name                TEXT NOT NULL,
  representative_name         TEXT NOT NULL,
  representative_email        TEXT NOT NULL,
  representative_phone        TEXT,
  company_website             TEXT,

  -- Talent they represent
  talent_names                TEXT[] NOT NULL,  -- list of names they manage
  representation_type         TEXT NOT NULL CHECK (representation_type IN (
    'management', 'label', 'legal', 'publicist', 'studio', 'agency', 'other'
  )),

  -- Supporting documents (stored in Supabase Storage, private bucket 'lkn-partner-docs')
  document_storage_paths      TEXT[] NOT NULL DEFAULT '{}',

  -- Review
  status                      TEXT NOT NULL DEFAULT 'submitted'
    CHECK (status IN ('submitted', 'under_review', 'approved', 'rejected')),
  nora_notes                  TEXT,
  reviewed_by                 UUID REFERENCES auth.users(id),
  reviewed_at                 TIMESTAMPTZ,

  -- Once approved, this partner gets a user account on the platform
  partner_user_id             UUID REFERENCES auth.users(id),

  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX lkn_partners_status_idx ON lkn_partners (status, created_at DESC);
CREATE INDEX lkn_partners_email_idx  ON lkn_partners (representative_email);
```

---

## Migration 109 — License Listings & Templates

File: `supabase/migrations/109_lkn_listings.sql`

```sql
-- A license listing is what the licensor puts on the marketplace.
-- One listing can have multiple license tiers (e.g., a $50 basic license and a $500 exclusive).
-- The license_template holds all the toggle parameters.

CREATE TABLE lkn_listings (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  licensor_user_id            UUID NOT NULL REFERENCES auth.users(id),

  -- The likeness being licensed
  listing_title               TEXT NOT NULL,         -- e.g., "Drake — Official Likeness License"
  listing_description         TEXT,
  licensor_display_name       TEXT NOT NULL,         -- the name that appears in search
  licensor_image_url          TEXT,
  category                    TEXT NOT NULL CHECK (category IN (
    'musician', 'athlete', 'actor', 'comedian', 'politician', 'entrepreneur',
    'influencer', 'content_creator', 'artist', 'scientist', 'other'
  )),

  -- What the license covers (at least one must be true)
  covers_name                 BOOLEAN NOT NULL DEFAULT TRUE,
  covers_image                BOOLEAN NOT NULL DEFAULT TRUE,
  covers_voice                BOOLEAN NOT NULL DEFAULT FALSE,
  covers_signature            BOOLEAN NOT NULL DEFAULT FALSE,
  covers_persona              BOOLEAN NOT NULL DEFAULT FALSE,  -- catch-all personality traits

  -- Listing state
  status                      TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'pending_review', 'active', 'paused', 'closed')),
  featured                    BOOLEAN NOT NULL DEFAULT FALSE,  -- future: paid placement

  -- Search/discovery
  tags                        TEXT[] DEFAULT '{}',
  search_vector               TSVECTOR,  -- populated by trigger for full-text search

  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  published_at                TIMESTAMPTZ,
  closed_at                   TIMESTAMPTZ
);

-- Full-text search trigger
CREATE OR REPLACE FUNCTION lkn_update_search_vector()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.search_vector := to_tsvector('english',
    COALESCE(NEW.licensor_display_name, '') || ' ' ||
    COALESCE(NEW.listing_title, '') || ' ' ||
    COALESCE(NEW.listing_description, '') || ' ' ||
    COALESCE(array_to_string(NEW.tags, ' '), '')
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER lkn_listing_search_vector
  BEFORE INSERT OR UPDATE ON lkn_listings
  FOR EACH ROW EXECUTE FUNCTION lkn_update_search_vector();

CREATE INDEX lkn_listings_search_idx   ON lkn_listings USING GIN (search_vector);
CREATE INDEX lkn_listings_status_idx   ON lkn_listings (status, published_at DESC);
CREATE INDEX lkn_listings_licensor_idx ON lkn_listings (licensor_user_id, status);
CREATE INDEX lkn_listings_category_idx ON lkn_listings (category, status);

-- License tiers within a listing (e.g., Basic, Standard, Exclusive)
CREATE TABLE lkn_license_tiers (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id                  UUID NOT NULL REFERENCES lkn_listings(id) ON DELETE CASCADE,
  tier_name                   TEXT NOT NULL,          -- e.g., "Basic", "Commercial", "Exclusive"
  tier_description            TEXT,
  price_usd_cents             BIGINT NOT NULL CHECK (price_usd_cents >= 0),

  -- Supply (for exclusive/limited tiers)
  is_exclusive                BOOLEAN NOT NULL DEFAULT FALSE,
  max_licenses                INTEGER,                -- NULL = unlimited
  licenses_sold               INTEGER NOT NULL DEFAULT 0,

  is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX lkn_tiers_listing_idx ON lkn_license_tiers (listing_id, is_active);
```

---

## Migration 110 — License Templates (Toggle Parameters)

File: `supabase/migrations/110_lkn_templates.sql`

```sql
-- The license template defines all the parameters for a given tier.
-- The AI uses this to generate the legal contract language.
-- All toggles default to the most restrictive setting (false = not allowed).
-- The licensor explicitly enables what they permit.

CREATE TABLE lkn_license_templates (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tier_id                     UUID NOT NULL UNIQUE REFERENCES lkn_license_tiers(id) ON DELETE CASCADE,
  listing_id                  UUID NOT NULL REFERENCES lkn_listings(id),  -- denorm

  -- ── DURATION ──
  duration_type               TEXT NOT NULL DEFAULT 'fixed'
    CHECK (duration_type IN ('perpetual', 'fixed', 'project_specific')),
  expires_at                  TIMESTAMPTZ,       -- required if duration_type = 'fixed'
  project_description         TEXT,              -- required if duration_type = 'project_specific'

  -- ── TERRITORY ──
  territory                   TEXT NOT NULL DEFAULT 'worldwide'
    CHECK (territory IN ('worldwide', 'us_only', 'eu_only', 'specific')),
  territory_countries         TEXT[],            -- populated if territory = 'specific'

  -- ── PURPOSE (what the licensee can use the likeness FOR) ──
  purpose_ai_generated_content  BOOLEAN NOT NULL DEFAULT FALSE,
  purpose_ai_voice_cloning      BOOLEAN NOT NULL DEFAULT FALSE,
  purpose_ai_image_generation   BOOLEAN NOT NULL DEFAULT FALSE,
  purpose_ai_model_training     BOOLEAN NOT NULL DEFAULT FALSE,  -- training datasets
  purpose_commercial_advertising BOOLEAN NOT NULL DEFAULT FALSE,
  purpose_entertainment_film    BOOLEAN NOT NULL DEFAULT FALSE,
  purpose_entertainment_tv      BOOLEAN NOT NULL DEFAULT FALSE,
  purpose_entertainment_game    BOOLEAN NOT NULL DEFAULT FALSE,  -- video games / apps
  purpose_music                 BOOLEAN NOT NULL DEFAULT FALSE,  -- music video, album art
  purpose_social_media          BOOLEAN NOT NULL DEFAULT FALSE,
  purpose_merchandise           BOOLEAN NOT NULL DEFAULT FALSE,  -- physical products
  purpose_nft_digital_asset     BOOLEAN NOT NULL DEFAULT FALSE,
  purpose_editorial_news        BOOLEAN NOT NULL DEFAULT TRUE,   -- always true (free speech baseline)
  purpose_custom_description    TEXT,                            -- additional allowed use

  -- ── CONTENT RESTRICTIONS (what the licensee CANNOT depict) ──
  restrict_profanity            BOOLEAN NOT NULL DEFAULT TRUE,   -- true = profanity NOT allowed
  restrict_adult_content        BOOLEAN NOT NULL DEFAULT TRUE,
  restrict_political_content    BOOLEAN NOT NULL DEFAULT FALSE,
  restrict_religious_content    BOOLEAN NOT NULL DEFAULT FALSE,
  restrict_violence             BOOLEAN NOT NULL DEFAULT TRUE,
  restrict_substance_use        BOOLEAN NOT NULL DEFAULT TRUE,   -- alcohol, tobacco, drugs
  restrict_competitor_brands    BOOLEAN NOT NULL DEFAULT FALSE,
  restrict_illegal_activity     BOOLEAN NOT NULL DEFAULT TRUE,   -- always enforced
  restricted_topics             TEXT[],                          -- free-text list of banned topics
  -- e.g., ['cancer', 'abortion', 'specific competitor name']

  -- ── AI-SPECIFIC CONTROLS ──
  ai_generated_must_be_labeled  BOOLEAN NOT NULL DEFAULT TRUE,   -- "AI-generated" disclosure required
  ai_max_generated_instances    INTEGER,                         -- NULL = unlimited
  ai_no_deepfake_sexual         BOOLEAN NOT NULL DEFAULT TRUE,   -- always enforced; legal baseline
  ai_no_misleading_context      BOOLEAN NOT NULL DEFAULT TRUE,   -- cannot be used to create false impressions

  -- ── SUBLICENSING ──
  sublicensing_allowed          BOOLEAN NOT NULL DEFAULT FALSE,
  sublicensing_requires_approval BOOLEAN NOT NULL DEFAULT TRUE,

  -- ── APPROVAL RIGHTS ──
  approval_required_before_publish BOOLEAN NOT NULL DEFAULT FALSE,
  approval_required_before_commercial_release BOOLEAN NOT NULL DEFAULT FALSE,
  approval_contact_email        TEXT,

  -- ── REVENUE SHARE ──
  revenue_share_pct             DECIMAL(5,2) NOT NULL DEFAULT 0,  -- 0 = no ongoing share
  revenue_share_applies_to      TEXT CHECK (revenue_share_applies_to IN (
    'gross_revenue', 'net_revenue', 'advertising_revenue', NULL
  )),

  -- ── REVOCATION ──
  revocation_type               TEXT NOT NULL DEFAULT 'for_cause'
    CHECK (revocation_type IN ('for_cause', 'at_will_30_days', 'irrevocable')),

  -- ── CUSTOM ADDENDUM ──
  -- Attorney-drafted additional terms uploaded as PDF
  addendum_storage_path         TEXT,              -- Supabase Storage path
  addendum_description          TEXT,              -- plain-English summary of addendum contents

  -- ── AI-GENERATED CONTRACT ──
  -- Populated after licensor submits the template for contract generation
  generated_contract_text       TEXT,              -- the full contract in plain English
  generated_contract_html       TEXT,              -- formatted version for display/signing
  contract_generated_at         TIMESTAMPTZ,
  contract_model_used           TEXT DEFAULT 'claude-sonnet-4-6',

  created_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

---

## Migration 111 — License Agreements (Purchases)

File: `supabase/migrations/111_lkn_agreements.sql`

```sql
-- A license agreement is created when a buyer purchases a tier.
-- This is the legal record. It is append-only (never UPDATE).
-- license_id is the externally-facing identifier used in API calls.

CREATE TABLE lkn_agreements (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- This is the public-facing license identifier (short, URL-safe)
  -- Format: LKN-[year]-[random 8 chars uppercase]
  -- e.g., LKN-2026-A4X9B2CQ
  license_id                  TEXT NOT NULL UNIQUE,

  listing_id                  UUID NOT NULL REFERENCES lkn_listings(id),
  tier_id                     UUID NOT NULL REFERENCES lkn_license_tiers(id),
  template_id                 UUID NOT NULL REFERENCES lkn_license_templates(id),

  licensor_user_id            UUID NOT NULL REFERENCES auth.users(id),
  licensee_user_id            UUID NOT NULL REFERENCES auth.users(id),

  -- Snapshot of key terms at time of purchase (template may change after)
  -- These are the actual terms in force — never query the template for verification
  terms_snapshot              JSONB NOT NULL,   -- complete copy of lkn_license_templates row at purchase

  -- Effective dates
  effective_date              DATE NOT NULL DEFAULT CURRENT_DATE,
  expiration_date             DATE,             -- NULL if perpetual

  -- State
  status                      TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'expired', 'revoked', 'suspended', 'transferred')),
  revoked_at                  TIMESTAMPTZ,
  revoked_reason              TEXT,

  -- Payment
  price_paid_usd_cents        BIGINT NOT NULL,
  platform_fee_usd_cents      BIGINT NOT NULL,
  licensor_receives_usd_cents BIGINT NOT NULL,
  stripe_payment_intent_id    TEXT,
  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,

  -- Cryptographic signature of the license record
  -- Signed with N.O.R.A. private key on creation; verifiable with public key
  record_hash                 TEXT NOT NULL,    -- SHA-256 of the core license fields
  signature                   TEXT,             -- RSA/ECDSA signature of record_hash

  -- Licensee agreed to terms
  licensee_agreed_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  licensor_countersigned_at   TIMESTAMPTZ,      -- for approval-required tiers

  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX agreements_licensor_idx  ON lkn_agreements (licensor_user_id, status);
CREATE INDEX agreements_licensee_idx  ON lkn_agreements (licensee_user_id, status);
CREATE INDEX agreements_listing_idx   ON lkn_agreements (listing_id);
CREATE INDEX agreements_expiry_idx    ON lkn_agreements (expiration_date, status)
  WHERE status = 'active';

-- Agreement change log (append-only audit trail)
CREATE TABLE lkn_agreement_events (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agreement_id                UUID NOT NULL REFERENCES lkn_agreements(id),
  event_type                  TEXT NOT NULL CHECK (event_type IN (
    'created', 'activated', 'revoked', 'suspended', 'reinstated',
    'expired', 'transferred', 'countersigned', 'addendum_added'
  )),
  actor_user_id               UUID REFERENCES auth.users(id),  -- who triggered the event
  notes                       TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX agreement_events_idx ON lkn_agreement_events (agreement_id, created_at DESC);
```

---

## Migration 112 — Verification API Keys & Call Log

File: `supabase/migrations/112_lkn_api.sql`

```sql
-- API keys for third-party platforms wanting to query the verification endpoint.
-- Free to register. Free tier: 1,000 calls/day. Paid: $0.001/call above that.

CREATE TABLE lkn_api_keys (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  api_key                     TEXT NOT NULL UNIQUE,  -- generated: lkn_live_[40 random chars]
  api_key_preview             TEXT NOT NULL,          -- first 12 chars for display: lkn_live_xxxx...
  owner_name                  TEXT NOT NULL,
  owner_email                 TEXT NOT NULL,
  owner_website               TEXT,
  intended_use_description    TEXT,

  -- Tier
  tier                        TEXT NOT NULL DEFAULT 'free'
    CHECK (tier IN ('free', 'commercial', 'partner')),
  daily_call_limit            INTEGER NOT NULL DEFAULT 1000,

  -- Usage tracking (reset daily by cron)
  calls_today                 INTEGER NOT NULL DEFAULT 0,
  calls_total                 BIGINT NOT NULL DEFAULT 0,
  last_reset_date             DATE NOT NULL DEFAULT CURRENT_DATE,

  is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX lkn_api_keys_key_idx ON lkn_api_keys (api_key, is_active);

-- Verification call log (for billing, abuse detection, analytics)
CREATE TABLE lkn_api_call_log (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  api_key_id                  UUID NOT NULL REFERENCES lkn_api_keys(id),

  -- What was queried
  license_id                  TEXT,             -- if querying a specific license
  licensor_nora_id            UUID,             -- if querying by licensor
  licensee_nora_id            UUID,             -- if querying by licensee
  use_category                TEXT,             -- what the caller wants to do

  -- Result
  response_status             TEXT NOT NULL CHECK (response_status IN (
    'valid', 'invalid', 'expired', 'not_found', 'rate_limited', 'error'
  )),
  response_time_ms            INTEGER,

  caller_ip_hash              TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX lkn_call_log_key_idx  ON lkn_api_call_log (api_key_id, created_at DESC);
CREATE INDEX lkn_call_log_lic_idx  ON lkn_api_call_log (license_id);

-- Daily reset of calls_today
SELECT cron.schedule(
  'lkn-api-daily-reset',
  '0 0 * * *',
  $$UPDATE lkn_api_keys SET calls_today = 0, last_reset_date = CURRENT_DATE
    WHERE last_reset_date < CURRENT_DATE;$$
);
```

---

## Migration 113 — License Badges & Public Registry

File: `supabase/migrations/113_lkn_public_registry.sql`

```sql
-- Public-facing license status page for each agreement.
-- Accessible at: noraplatforms.com/license/[license_id]
-- No PII. Shows: licensor display name, license status, expiration, permitted uses.

CREATE TABLE lkn_public_registry (
  license_id                  TEXT PRIMARY KEY REFERENCES lkn_agreements(license_id),
  licensor_display_name       TEXT NOT NULL,
  licensor_image_url          TEXT,
  listing_category            TEXT NOT NULL,
  license_status              TEXT NOT NULL,
  effective_date              DATE NOT NULL,
  expiration_date             DATE,
  territory                   TEXT NOT NULL,
  permitted_purposes          TEXT[] NOT NULL,  -- human-readable list
  content_restrictions        TEXT[] NOT NULL,  -- human-readable list
  ai_use_allowed              BOOLEAN NOT NULL,
  last_verified_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- Updated by trigger after lkn_agreements INSERT or status change.

CREATE OR REPLACE FUNCTION sync_lkn_public_registry()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_listing lkn_listings%ROWTYPE;
  v_template lkn_license_templates%ROWTYPE;
  v_purposes TEXT[] := '{}';
  v_restrictions TEXT[] := '{}';
BEGIN
  SELECT * INTO v_listing FROM lkn_listings WHERE id = NEW.listing_id;
  SELECT * INTO v_template FROM lkn_license_templates WHERE id = NEW.template_id;

  -- Build human-readable permitted purposes from template
  IF v_template.purpose_ai_generated_content THEN v_purposes := v_purposes || 'AI-generated content'; END IF;
  IF v_template.purpose_entertainment_game   THEN v_purposes := v_purposes || 'Video games & apps'; END IF;
  IF v_template.purpose_commercial_advertising THEN v_purposes := v_purposes || 'Commercial advertising'; END IF;
  IF v_template.purpose_entertainment_film   THEN v_purposes := v_purposes || 'Film production'; END IF;
  IF v_template.purpose_music                THEN v_purposes := v_purposes || 'Music & music video'; END IF;
  IF v_template.purpose_social_media         THEN v_purposes := v_purposes || 'Social media content'; END IF;
  IF v_template.purpose_merchandise          THEN v_purposes := v_purposes || 'Merchandise'; END IF;

  -- Build restrictions list
  IF v_template.restrict_profanity      THEN v_restrictions := v_restrictions || 'No profanity'; END IF;
  IF v_template.restrict_adult_content  THEN v_restrictions := v_restrictions || 'No adult content'; END IF;
  IF v_template.restrict_violence       THEN v_restrictions := v_restrictions || 'No depictions of violence'; END IF;

  INSERT INTO lkn_public_registry (
    license_id, licensor_display_name, licensor_image_url, listing_category,
    license_status, effective_date, expiration_date, territory,
    permitted_purposes, content_restrictions, ai_use_allowed
  ) VALUES (
    NEW.license_id, v_listing.licensor_display_name, v_listing.licensor_image_url,
    v_listing.category, NEW.status, NEW.effective_date, NEW.expiration_date,
    v_template.territory, v_purposes, v_restrictions,
    v_template.purpose_ai_generated_content OR v_template.purpose_ai_voice_cloning
    OR v_template.purpose_ai_image_generation
  )
  ON CONFLICT (license_id) DO UPDATE SET
    license_status = EXCLUDED.license_status,
    last_verified_at = NOW();

  RETURN NEW;
END;
$$;

CREATE TRIGGER lkn_sync_public_registry
  AFTER INSERT OR UPDATE ON lkn_agreements
  FOR EACH ROW EXECUTE FUNCTION sync_lkn_public_registry();
```

---

## REST Verification API

File: `supabase/functions/lkn-verify/index.ts`

Endpoint: `GET https://api.noraplatforms.com/v1/verify`

Deploy `--no-verify-jwt`. Gate with API key in header.

```typescript
// Request: GET /v1/verify
// Headers: X-NORA-API-Key: lkn_live_xxxxxxxxxxxx
// Query params (at least one of license_id OR licensor_nora_id required):
//   license_id:        TEXT   — query a specific agreement
//   licensor_nora_id:  UUID   — N.O.R.A. user ID of the licensor
//   licensee_nora_id:  UUID   — N.O.R.A. user ID of the licensee
//   use_category:      TEXT   — the intended use to check against restrictions

// Response 200 — license valid:
{
  "license_id": "LKN-2026-A4X9B2CQ",
  "license_status": "active",
  "licensor": {
    "nora_id": "uuid",
    "display_name": "Drake",
    "verified": true,
    "verification_tier": "agent"
  },
  "licensee": {
    "nora_id": "uuid"
  },
  "effective_date": "2026-01-01",
  "expiration_date": "2027-01-01",
  "territory": "worldwide",
  "use_category_permitted": true,  // whether the requested use_category is allowed
  "restrictions": {
    "profanity_allowed": false,
    "adult_content_allowed": false,
    "political_content_allowed": false,
    "ai_voice_allowed": true,
    "ai_image_allowed": true,
    "ai_model_training_allowed": false,
    "ai_generated_must_be_labeled": true,
    "sublicensing_allowed": false,
    "restricted_topics": ["violence", "drug use"]
  },
  "nora_source_url": "https://noraplatforms.com/license/LKN-2026-A4X9B2CQ",
  "record_hash": "sha256:...",
  "signature": "base64_encoded_ecdsa_signature",
  "public_key_url": "https://noraplatforms.com/.well-known/nora-public-key.pem",
  "verified_at": "2026-06-17T12:00:00Z"
}

// Response 200 — license not found or invalid:
{
  "license_status": "not_found",
  "use_category_permitted": false,
  "verified_at": "2026-06-17T12:00:00Z"
}

// Response 429 — rate limited:
{ "error": "rate_limit_exceeded", "daily_limit": 1000, "resets_at": "2026-06-18T00:00:00Z" }
```

### Cryptographic Signing Implementation

```typescript
// N.O.R.A. signs each verification response with ECDSA (P-256 curve).
// The private key is stored in Supabase Vault (never in code).
// Third parties verify the response using N.O.R.A.'s public key at:
// https://noraplatforms.com/.well-known/nora-public-key.pem

// In lkn-verify edge function:
import { crypto } from 'https://deno.land/std@0.168.0/crypto/mod.ts';

async function signResponse(payload: object): Promise<{ hash: string; signature: string }> {
  const keyPem = Deno.env.get('NORA_SIGNING_PRIVATE_KEY');
  const payloadStr = JSON.stringify(payload);
  const encoder = new TextEncoder();

  // SHA-256 hash of payload
  const hashBuffer = await crypto.subtle.digest('SHA-256', encoder.encode(payloadStr));
  const hash = 'sha256:' + Array.from(new Uint8Array(hashBuffer))
    .map(b => b.toString(16).padStart(2, '0')).join('');

  // ECDSA signature (P-256)
  // In production, use Deno's crypto.subtle.sign with the imported private key
  // The signature proves the response came from N.O.R.A. and was not tampered with

  return { hash, signature: 'ecdsa_signature_here' };
}
```

Note for Claude Code: The actual ECDSA key generation and storage must be done via
Supabase Vault. Store the key as `NORA_SIGNING_PRIVATE_KEY`. The public key is
served as a static file via Vercel at `/.well-known/nora-public-key.pem`.

---

## AI Contract Generation Edge Function

File: `supabase/functions/lkn-generate-contract/index.ts`

Called when a licensor submits their template for contract generation.
Uses claude-sonnet-4-6. Fills in N.O.R.A.'s attorney-approved base template
with the licensor's parameters.

IMPORTANT: Claude Code must NOT generate novel legal language. The contract
is generated by filling a pre-approved template structure. The AI's job is
to accurately translate the toggle settings into the correct legal clause
from the template library. The template library is maintained by N.O.R.A.'s
legal team and stored in `lkn_contract_clauses` table (seed manually from
attorney-approved language before launch).

```typescript
// System prompt for contract generation:
const SYSTEM = `You are a contract assembly assistant for N.O.R.A. Platforms.
You receive a license template with toggle settings and a clause library.
Your job is to select the correct pre-written clause for each setting and assemble
them into a coherent Right of Publicity license agreement.

Do NOT write novel legal language. Only use clauses from the provided library.
Do NOT add provisions that are not in the template settings.
Assemble the clauses in the standard order: Parties, Recitals, Grant of Rights,
Restrictions, Duration, Territory, Compensation, Approval Rights, Revocation,
General Provisions.

Return JSON: { contract_text: string, contract_html: string }`;
```

---

## License ID Generation

```sql
CREATE OR REPLACE FUNCTION generate_license_id()
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  v_year TEXT := EXTRACT(YEAR FROM NOW())::TEXT;
  v_chars TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- no ambiguous chars
  v_code TEXT := '';
  i INTEGER;
BEGIN
  FOR i IN 1..8 LOOP
    v_code := v_code || substr(v_chars, floor(random() * length(v_chars))::int + 1, 1);
  END LOOP;
  RETURN 'LKN-' || v_year || '-' || v_code;
END;
$$;

-- Use in lkn_agreements: license_id = generate_license_id()
-- Verify uniqueness before inserting (retry on collision — statistically impossible at scale)
```

---

## New Edge Functions

Add to docs/infra.md:

```
### Licensing Marketplace
lkn-register-api-key       — registers a third-party API key (public, no auth)
lkn-verify                 — verification API endpoint (public, API key auth)
lkn-create-listing         — licensor creates a listing (auth required)
lkn-submit-template        — licensor submits toggle parameters (auth required)
lkn-generate-contract      — AI generates contract from template (internal)
lkn-purchase-license       — buyer purchases a license tier (auth required)
lkn-revoke-license         — licensor revokes a license (auth required)
lkn-partner-apply          — partner submits application via Partners Portal (public)
lkn-register-licensor      — verify licensor KYC + social links (auth required)
```

---

## Flutter Screens

### New Screens

**LicensingMarketplaceHomeScreen** (`/licenses`)
Public-facing landing page. Hero: "License real likeness and image rights, verified
on N.O.R.A. Platforms." Search bar (full-text against `lkn_listings`). Filter chips:
category, purpose (AI use, advertising, game use, etc.), price range. Grid of
`LicensingListingCard` widgets.

**LicensingListingDetailScreen** (`/licenses/:listingId`)
Shows: licensor name/image, description, verification badge (Tier 1/2/3),
license tiers (cards with price and included permissions). "Buy This License" CTA.
Permitted uses visual: icon grid of what's allowed. Content restrictions visual.

**LicenseCheckoutScreen** (`/licenses/:listingId/buy/:tierId`)
Stripe Checkout flow (same pattern as token purchases). Shows summary of what
they're buying. Checkbox: "I agree to the N.O.R.A. license agreement terms."
Terms displayed inline (from `generated_contract_html`).

**MyLicensesScreen** (`/my-licenses`)
All active licenses the user holds. Each card: licensor name, license_id (copyable),
status, expiration countdown, "View Public Record" link, "Sync to Arena App" button
(deep links to Arena app with the license token — see doc6).

**CreateListingScreen** (`/create-listing`)
Multi-step form for licensors:
- Step 1: Basic info (title, description, what's covered: name/image/voice/etc.)
- Step 2: License tiers (create 1–3 tiers with names and prices)
- Step 3: Parameters for each tier (the toggle UI — see below)
- Step 4: Custom addendum upload (optional PDF)
- Step 5: Preview generated contract
- Step 6: Submit for N.O.R.A. review

**LicenseToggleUI** (widget, embedded in Step 3)
Section-based form: Duration, Territory, Permitted Uses, Content Restrictions,
AI Controls, Approval Rights, Revenue Share, Revocation. Each toggle is a
labeled switch with a one-sentence plain-English description of what it means.
Dangerous toggles (adult content, at-will revocation) have a confirmation step.

**PartnersPortalScreen** (`/partners`)
Public-facing. "Are you management, a label, or legal representation?"
Form: company, rep name, email, talent list, document upload. Submit → confirmation
page with expected review timeline (5 business days).

**LicensePublicRecordScreen** (`/license/:licenseId`)
Public page for any license. No PII. Shows: licensor display name, status badge
(Active / Expired / Revoked), effective date, territory, permitted uses list,
content restrictions list. "Verify this license via API" code snippet.
This page is the human-readable equivalent of the API response.

### New Routes

```dart
GoRoute(path: '/licenses',             builder: (_, __) => const LicensingMarketplaceHomeScreen()),
GoRoute(path: '/licenses/:listingId',  builder: (_, s) => ListingDetailScreen(listingId: s.pathParameters['listingId']!)),
GoRoute(path: '/licenses/:listingId/buy/:tierId',
                                       builder: (_, s) => LicenseCheckoutScreen(
                                         listingId: s.pathParameters['listingId']!,
                                         tierId: s.pathParameters['tierId']!)),
GoRoute(path: '/my-licenses',          builder: (_, __) => const MyLicensesScreen()),
GoRoute(path: '/create-listing',       builder: (_, __) => const CreateListingScreen()),
GoRoute(path: '/partners',             builder: (_, __) => const PartnersPortalScreen()),
GoRoute(path: '/license/:licenseId',   builder: (_, s) => LicensePublicRecordScreen(licenseId: s.pathParameters['licenseId']!)),
```

All public except `/my-licenses` and `/create-listing` (auth required).

---

## CLAUDE.md Updates Required

Add new section after Games:

```
## Licensing Marketplace
Right of Publicity licensing. Tables prefixed lkn_. Verification via REST API
at api.noraplatforms.com/v1/verify. License IDs format: LKN-[year]-[8 chars].
Templates auto-generate contracts from pre-approved clause library (never novel
legal language from AI). All agreements are append-only — never UPDATE lkn_agreements.
```

Add Hard Rules (numbered 29–32 — Rules 26–28 are the existing Battle Chit /
one-role-per-match / identity_hash invariants and MUST NOT be overwritten):
```
29. lkn_agreements rows are never updated after INSERT except status changes
    (revoked, expired, suspended). Terms snapshot is immutable.
30. lkn_license_templates generated_contract_text is populated only by lkn-generate-contract
    using the pre-approved clause library. Never generate novel legal language.
31. API key validation happens in lkn-verify before any license data is returned.
    Rate limits enforced before any query runs. Never expose license data without
    a valid API key.
32. The N.O.R.A. signing private key lives only in Supabase Vault as NORA_SIGNING_PRIVATE_KEY.
    Never log it, never return it, never include it in responses.
```

---

## Milestone Checklist

### Milestone 1 — Schema
- [ ] Migrations 108–113 applied with zero errors
- [ ] `lkn_listings` full-text search working (test query returns results)
- [ ] `lkn_agreements` insert triggers `sync_lkn_public_registry`
- [ ] Private Supabase Storage bucket `lkn-partner-docs` created
- [ ] `generate_license_id()` returns unique LKN-YYYY-XXXXXXXX format

### Milestone 2 — Licensor Verification
- [ ] Self-tier verification: KYC + social link count written to `lkn_licensor_verifications`
- [ ] Partners Portal submission form saves to `lkn_partners`
- [ ] Celeb licensors auto-verified from existing `celebs` table (is_integrated = TRUE)
- [ ] `profiles.lkn_licensor_status` updates on verification approval

### Milestone 3 — API
- [ ] `lkn-register-api-key` generates `lkn_live_` prefixed key
- [ ] `lkn-verify` returns correct signed JSON for a valid license
- [ ] Rate limiting enforced: >1000 calls/day from same key returns 429
- [ ] `lkn_api_call_log` written for every request
- [ ] Daily reset cron zeroes `calls_today`

### Milestone 4 — Contract Generation
- [ ] Template toggles correctly populate `lkn_license_templates`
- [ ] `lkn-generate-contract` returns contract text from clause library (NOT novel AI legal language)
- [ ] Generated contract displays correctly in `LicenseCheckoutScreen`
- [ ] License purchase creates `lkn_agreements` row with correct `terms_snapshot`
- [ ] `record_hash` populated on agreement INSERT

### Milestone 5 — Flutter UI
- [ ] `/licenses` search returns results filtered by category and purpose
- [ ] Toggle UI renders all parameter sections with correct defaults
- [ ] License checkout flow completes in sim mode
- [ ] `MyLicensesScreen` shows active licenses with sync button
- [ ] `/license/:licenseId` public page renders without auth
- [ ] `flutter analyze` zero issues
