# NORA Campaigns — Royalty Crowdfunding Framework
# Status: Design complete. Build not started. Last updated: 2026-05-23

---

## 1. Vision

Creators launch funding campaigns where backers purchase a percentage of future
royalties from a specific work (album, film, podcast, software, etc.). The platform
holds all funds in escrow, automatically disburses royalties to backers as revenue
is verified, and gives backers governance rights over how escrowed capital is spent.
Ownership is transparent, auditable, and eventually on-chain.

This is not a donation. It is an investment. Backers receive real returns tied to
real revenue. The platform does not rely on creator honesty — escrow and verified
revenue events enforce the contract mechanically.

---

## 2. Regulatory Framework

### Governing law: Regulation Crowdfunding (Reg CF), JOBS Act
- NORA will register as a **Funding Portal** with the SEC (Form Funding Portal).
- Campaigns are securities offerings. Each campaign requires a **Form C** filing
  with the SEC before going live.
- **Annual raise limit per creator**: $5,000,000 USD across all Reg CF offerings.
- **Investor limits (US-based, non-accredited)**:
  - If annual income OR net worth < $124,000: max investment = lesser of $2,500 or
    5% of the lesser of annual income/net worth.
  - If both ≥ $124,000: max = 10% of lesser, capped at $124,000 per year across
    ALL Reg CF offerings the investor participates in (not per campaign).
- **Accredited investors**: no per-offering limit under Reg CF.
- **International investors**: subject to their home jurisdiction's rules. NORA
  enforces KYC and AML for all; investment limits are US-specific.
- **Secondary market**: secondary trading of Reg CF securities requires operation
  through a registered ATS (Alternative Trading System) or similar. Schema is
  designed now; regulatory wiring required before secondary market goes live.
- **Campaign funding window**: maximum 12 months per Reg CF; NORA default is 90 days.
- **Attorney review required** before any campaign goes live with real funds.

---

## 3. Architecture Decisions

### 3a. Escrow — MVP

Programmatic escrow via **Stripe Connect** (Express accounts for creators) and
**Stripe Treasury** for fund holding. Disbursement logic lives in NORA edge functions
as SECURITY DEFINER Postgres functions. No manual creator access to escrowed funds
— only governance-approved proposals release capital.

All financial logic is auditable via the immutable `campaign_ownership_ledger` and
`campaign_distributions` tables.

### 3b. On-Chain Migration Path (CRITICAL — build MVP with this in mind)

**NORA has a proprietary cryptocurrency in development (white papers drafted,
coin not yet launched).** When the coin launches:

- The `campaign_ownership_ledger` will migrate to on-chain smart contracts.
- Each campaign's royalty stake will be represented as a token (ERC-20 or equivalent)
  minted on the NORA chain.
- The `campaign_ownership_ledger` is intentionally designed as an **append-only
  immutable ledger** — every ownership change is a new row, never an update.
  This mirrors how a blockchain records state and makes migration straightforward:
  the ledger is the canonical truth, and the chain becomes its settlement layer.
- Secondary market trades, governance votes, and distribution events will eventually
  settle on-chain.
- Fiat USD flows will map to NORA coin at a defined conversion rate at migration time.

**MVP rule**: never mutate ownership records. Always append. Every dollar amount
stored in USD cents (integer). Every percentage stored as `DECIMAL(10,6)` to support
fractional micro-stakes.

### 3c. Simulation Mode

All campaign infrastructure is built with a `mode` flag. Simulated campaigns use
fake USD balances (`sim_usd_balances` table, seeded at $10,000 per user), make no
real Stripe calls, and produce real data flows through every layer of the system.
Toggling a campaign from `simulated` to `live` requires a flag flip and KYC gate.
This allows full end-to-end testing and investor demos before regulatory approval.

---

## 4. Platform Fee Structure — Three Proposals

Pick one before payment logic is built. All options include the secondary market fee.

### Option A — Pure Success Fee
| Event | Fee |
|---|---|
| Campaign reaches goal | 6% of total funds raised (deducted from escrow at funding) |
| Royalty distributions | 0% |
| Secondary market trade | 1% from seller + 1% from buyer = 2% round trip |

**Best for**: creator simplicity. Creators know the exact cost upfront.
**Platform risk**: if campaigns raise large amounts with perpetual terms, platform earns
nothing ongoing. Revenue front-loaded at raise time.

### Option B — Blended (Recommended)
| Event | Fee |
|---|---|
| Campaign reaches goal | 3% of total funds raised |
| Each royalty distribution | 1.5% of net distribution amount |
| Secondary market trade | 0.5% seller + 0.5% buyer |

**Best for**: platform revenue aligned with creator success. Lower upfront cost
encourages more campaigns. Ongoing distributions create recurring revenue. As the
catalog of active campaigns grows, distribution fees compound.

### Option C — Tiered by Campaign Size
| Raise amount | Success fee | Distribution fee |
|---|---|---|
| Under $50,000 | 7% | 0% |
| $50,000 – $500,000 | 5% | 0% |
| Over $500,000 | 3% | 1% |
| Secondary market | 0.5% + 0.5% | — |

**Best for**: attracting large flagship campaigns. Penalizes small campaigns slightly
(they are disproportionately expensive to administer under Reg CF). Not recommended
for launch — complexity without clear benefit over Option B.

> **DECIDED 2026-05-23**: Option B — Blended. Use these exact rates when building
> payment logic: 3% at funding close, 1.5% per distribution, 0.5% per secondary trade side.

---

## 5. Data Model

All table names prefixed `campaign_` to namespace cleanly alongside existing tables.
All monetary values in integer **USD cents** (e.g. $10.00 = 1000).
All percentages as `DECIMAL(10,6)` (e.g. 15.5% = 15.500000).

---

### 5a. KYC

```sql
-- Identity verification. One row per user. Re-verified annually.
-- Stripe Identity handles document scanning; we store results.
CREATE TABLE kyc_verifications (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  -- Verification status
  status                      TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','in_review','approved','rejected','expired')),
  provider                    TEXT NOT NULL DEFAULT 'stripe_identity',
  provider_session_id         TEXT,

  -- Verified identity (populated by provider on approval)
  verified_legal_name         TEXT,
  date_of_birth               DATE,
  identity_document_type      TEXT CHECK (identity_document_type IN
    ('passport','drivers_license','national_id','residence_permit')),
  identity_document_country   TEXT,   -- ISO 3166-1 alpha-2
  verified_address_line1      TEXT,
  verified_address_city       TEXT,
  verified_address_country    TEXT,   -- ISO 3166-1 alpha-2

  -- AML / PEP
  pep_status                  BOOLEAN DEFAULT FALSE, -- Politically Exposed Person
  sanctions_screened_at       TIMESTAMPTZ,
  sanctions_result            TEXT CHECK (sanctions_result IN ('clear','flagged','review')),
  source_of_funds_declaration TEXT,

  -- Reg CF investor limits (US residents only — enforced at investment time)
  annual_income_usd_cents     BIGINT,
  net_worth_usd_cents         BIGINT,
  is_accredited_investor      BOOLEAN DEFAULT FALSE,
  -- Running total invested across ALL Reg CF offerings this calendar year (US only)
  -- Updated on each investment confirmation. Reset January 1.
  reg_cf_invested_ytd_cents   BIGINT NOT NULL DEFAULT 0,
  reg_cf_limit_year           SMALLINT, -- the year reg_cf_invested_ytd applies to

  -- Trusted contact / next of kin (for unclaimed royalty handling)
  trusted_contact_name        TEXT,
  trusted_contact_email       TEXT,
  trusted_contact_phone       TEXT,
  trusted_contact_relationship TEXT,  -- 'spouse','parent','sibling','attorney','other'
  trusted_contact_country     TEXT,

  -- Timestamps
  submitted_at                TIMESTAMPTZ,
  verified_at                 TIMESTAMPTZ,
  expires_at                  TIMESTAMPTZ, -- 1 year from verified_at, then re-verify
  rejected_reason             TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (user_id)
);
```

---

### 5b. Campaigns

```sql
CREATE TABLE campaigns (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id                  UUID NOT NULL REFERENCES auth.users(id),

  -- Identity
  title                       TEXT NOT NULL,
  description                 TEXT,
  category                    TEXT NOT NULL CHECK (category IN (
    'album','ep','single','film','documentary','podcast',
    'software','game','tour','merchandise','other'
  )),
  cover_image_url             TEXT,

  -- The offer
  funding_goal_usd_cents      BIGINT NOT NULL CHECK (funding_goal_usd_cents > 0),
  current_funding_usd_cents   BIGINT NOT NULL DEFAULT 0,
  royalty_pct_offered         DECIMAL(10,6) NOT NULL
    CHECK (royalty_pct_offered > 0 AND royalty_pct_offered <= 100),
  royalty_term_years          SMALLINT DEFAULT NULL, -- NULL = perpetual
  min_investment_usd_cents    BIGINT NOT NULL DEFAULT 1000, -- $10 minimum

  -- Lifecycle
  mode                        TEXT NOT NULL DEFAULT 'simulated'
    CHECK (mode IN ('simulated','live')),
  status                      TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN (
      'draft',      -- creator editing, not visible
      'pending',    -- submitted for platform review / SEC Form C prep
      'open',       -- accepting investments
      'funded',     -- goal reached, in escrow, awaiting work delivery
      'active',     -- royalties flowing
      'failed',     -- goal not reached by closes_at, refunds issued
      'closed'      -- royalty term ended (only if royalty_term_years was set)
    )),
  opens_at                    TIMESTAMPTZ,
  closes_at                   TIMESTAMPTZ, -- max 12 months from opens_at per Reg CF

  -- Revenue source anchors (populated when creator links the work)
  spotify_album_id            TEXT,
  spotify_artist_id           TEXT,
  youtube_channel_id          TEXT,
  youtube_video_id            TEXT,    -- for single-work campaigns
  apple_music_album_id        TEXT,    -- future
  distrokid_release_id        TEXT,    -- future data partnership
  tunecore_release_id         TEXT,    -- future data partnership

  -- Escrow (populated when campaign is approved and funded)
  escrow_stripe_account_id    TEXT,    -- Stripe Connect account for this campaign
  escrow_balance_usd_cents    BIGINT NOT NULL DEFAULT 0,

  -- Reg CF compliance
  sec_form_c_filing_id        TEXT,    -- EDGAR filing reference
  sec_filing_date             DATE,

  -- On-chain migration (future)
  -- When NORA coin launches, this campaign's ownership ledger will be minted
  -- as tokens on the NORA chain. Populate at migration time.
  onchain_contract_address    TEXT DEFAULT NULL,
  onchain_token_symbol        TEXT DEFAULT NULL,

  -- Platform fee (snapshot the rate at campaign creation time so future fee
  -- changes don't retroactively affect existing campaigns)
  platform_success_fee_pct    DECIMAL(5,4) NOT NULL DEFAULT 0.0300, -- 3%
  platform_distribution_fee_pct DECIMAL(5,4) NOT NULL DEFAULT 0.0150, -- 1.5%

  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  funded_at                   TIMESTAMPTZ,
  closed_at                   TIMESTAMPTZ,

  CONSTRAINT closes_after_opens CHECK (closes_at > opens_at),
  CONSTRAINT royalty_term_positive CHECK (royalty_term_years IS NULL OR royalty_term_years > 0)
);

CREATE INDEX campaigns_creator_idx   ON campaigns (creator_id, status);
CREATE INDEX campaigns_status_idx    ON campaigns (status, closes_at);
CREATE INDEX campaigns_mode_idx      ON campaigns (mode, status);
```

---

### 5c. Ownership Ledger (immutable — never UPDATE, only INSERT)

```sql
-- Every ownership change in the system writes a row here.
-- Current ownership for a user = net sum of all to_user_id rows minus from_user_id rows.
-- This is the single source of truth. Designed to mirror blockchain state transitions.
CREATE TABLE campaign_ownership_ledger (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  campaign_id                 UUID NOT NULL REFERENCES campaigns(id),
  -- NULL from_user_id = initial mint (new investment from campaign pool)
  -- NULL to_user_id   = burn (future use — e.g. creator buyback)
  from_user_id                UUID REFERENCES auth.users(id),
  to_user_id                  UUID REFERENCES auth.users(id),

  royalty_pct                 DECIMAL(10,6) NOT NULL CHECK (royalty_pct > 0),
  usd_cents_paid              BIGINT NOT NULL DEFAULT 0,

  event_type                  TEXT NOT NULL CHECK (event_type IN (
    'purchase',           -- initial investment during funding window
    'secondary_sale',     -- secondary market trade
    'inheritance',        -- unclaimed royalties transferred to trusted contact
    'platform_correction' -- admin correction with audit trail
  )),

  -- Payment reference
  stripe_payment_intent_id    TEXT,
  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,

  -- Metadata
  notes                       TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX ownership_ledger_campaign_idx ON campaign_ownership_ledger (campaign_id, created_at);
CREATE INDEX ownership_ledger_to_user_idx  ON campaign_ownership_ledger (to_user_id, campaign_id);
CREATE INDEX ownership_ledger_from_user_idx ON campaign_ownership_ledger (from_user_id, campaign_id);
```

---

### 5d. Simulated USD Balances

```sql
-- Simulated wallets for testing. Seeded at $10,000 per user on first campaign interaction.
-- Only used when campaign.mode = 'simulated'. No real money.
CREATE TABLE sim_usd_balances (
  user_id                     UUID PRIMARY KEY REFERENCES auth.users(id),
  balance_usd_cents           BIGINT NOT NULL DEFAULT 1000000, -- $10,000
  lifetime_invested_cents     BIGINT NOT NULL DEFAULT 0,
  lifetime_returned_cents     BIGINT NOT NULL DEFAULT 0,
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE sim_usd_transactions (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                     UUID NOT NULL REFERENCES auth.users(id),
  type                        TEXT NOT NULL CHECK (type IN (
    'seed','investment','refund','distribution','secondary_purchase',
    'secondary_sale','fee','governance_release'
  )),
  amount_usd_cents            BIGINT NOT NULL, -- negative = debit, positive = credit
  reference_id                UUID,            -- campaign_id, listing_id, etc.
  description                 TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

---

### 5e. Revenue Events

```sql
-- Each verified income event for a campaign. Triggers distribution calculation.
-- Designed for MVP (creator upload) and future API/partnership verification.
CREATE TABLE campaign_revenue_events (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id                 UUID NOT NULL REFERENCES campaigns(id),

  source                      TEXT NOT NULL CHECK (source IN (
    'spotify','youtube','apple_music','amazon_music','tidal',
    'soundcloud','bandcamp','twitch','distrokid','tunecore',
    'manual','other'
  )),

  period_start                DATE NOT NULL,
  period_end                  DATE NOT NULL,

  -- Revenue breakdown
  gross_revenue_usd_cents     BIGINT NOT NULL DEFAULT 0,
  platform_fee_usd_cents      BIGINT NOT NULL DEFAULT 0,  -- Spotify/YouTube's cut
  net_revenue_usd_cents       BIGINT NOT NULL DEFAULT 0,  -- what NORA distributes

  -- Display metrics (proxy for revenue where dollar API not available)
  stream_count                BIGINT DEFAULT 0,
  view_count                  BIGINT DEFAULT 0,
  download_count              BIGINT DEFAULT 0,

  -- Verification
  evidence_type               TEXT NOT NULL CHECK (evidence_type IN (
    'creator_upload',     -- MVP: creator uploads royalty statement PDF
    'csv_export',         -- Phase 2: DistroKid/TuneCore CSV parsed by platform
    'api_pull',           -- Phase 3: direct API with creator OAuth
    'data_partnership',   -- Phase 4: direct data deal with Spotify/YouTube
    'oracle'              -- Future: on-chain oracle verifying off-chain data
  )),
  evidence_url                TEXT,    -- uploaded file or API response reference
  verification_status         TEXT NOT NULL DEFAULT 'pending'
    CHECK (verification_status IN ('pending','verified','disputed','rejected')),
  verified_by_user_id         UUID REFERENCES auth.users(id), -- platform admin or system
  verified_at                 TIMESTAMPTZ,
  dispute_reason              TEXT,
  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,

  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT period_order CHECK (period_end >= period_start)
);

CREATE INDEX revenue_events_campaign_idx ON campaign_revenue_events (campaign_id, period_start);
CREATE INDEX revenue_events_status_idx   ON campaign_revenue_events (verification_status);
```

---

### 5f. Distributions

```sql
-- One row per backer per revenue event. Created when event is verified.
-- Actual transfer triggered when status moves to 'processing'.
CREATE TABLE campaign_distributions (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  revenue_event_id            UUID NOT NULL REFERENCES campaign_revenue_events(id),
  campaign_id                 UUID NOT NULL REFERENCES campaigns(id),
  backer_user_id              UUID NOT NULL REFERENCES auth.users(id),

  -- Ownership snapshot at distribution time (from ledger — never recalculated)
  royalty_pct_at_time         DECIMAL(10,6) NOT NULL,

  gross_usd_cents             BIGINT NOT NULL,
  platform_fee_usd_cents      BIGINT NOT NULL DEFAULT 0,
  net_usd_cents               BIGINT NOT NULL,

  status                      TEXT NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued','processing','completed','failed','unclaimed')),

  stripe_transfer_id          TEXT,
  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,
  distributed_at              TIMESTAMPTZ,
  failed_reason               TEXT,

  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (revenue_event_id, backer_user_id)
);

CREATE INDEX distributions_backer_idx  ON campaign_distributions (backer_user_id, status);
CREATE INDEX distributions_event_idx   ON campaign_distributions (revenue_event_id);
```

---

### 5g. Governance — Fund Proposals and Voting

```sql
-- Creator proposes spending escrowed capital. Backers vote. Approved = funds released.
CREATE TABLE campaign_proposals (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id                 UUID NOT NULL REFERENCES campaigns(id),
  creator_id                  UUID NOT NULL REFERENCES auth.users(id),

  title                       TEXT NOT NULL,
  description                 TEXT NOT NULL,
  amount_requested_usd_cents  BIGINT NOT NULL CHECK (amount_requested_usd_cents > 0),
  purpose_category            TEXT NOT NULL CHECK (purpose_category IN (
    'equipment','software','marketing','travel','production',
    'licensing','legal','distribution','other'
  )),
  -- e.g. "B&H Photo — Sony A7IV body + lens kit, receipt will be uploaded on purchase"
  recipient_description       TEXT NOT NULL,

  status                      TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','approved','rejected','cancelled','executed','expired')),

  -- Voting window
  voting_opens_at             TIMESTAMPTZ NOT NULL,
  voting_closes_at            TIMESTAMPTZ NOT NULL, -- default: opens_at + 72 hours

  -- Tallied continuously as votes come in (denormalized for display speed)
  total_royalty_pct_voted     DECIMAL(10,6) NOT NULL DEFAULT 0,
  royalty_pct_approved        DECIMAL(10,6) NOT NULL DEFAULT 0,
  royalty_pct_rejected        DECIMAL(10,6) NOT NULL DEFAULT 0,
  -- Quorum: 25% of total outstanding royalty_pct must vote for result to be binding
  quorum_pct_required         DECIMAL(10,6) NOT NULL DEFAULT 25.000000,

  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,
  executed_at                 TIMESTAMPTZ,
  stripe_transfer_id          TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT voting_window_order CHECK (voting_closes_at > voting_opens_at)
);

CREATE TABLE campaign_votes (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  proposal_id                 UUID NOT NULL REFERENCES campaign_proposals(id),
  voter_user_id               UUID NOT NULL REFERENCES auth.users(id),

  vote                        TEXT NOT NULL CHECK (vote IN ('yes','no','abstain')),
  -- Snapshot of voter's royalty_pct ownership at time of vote
  -- (prevents gaming by buying stake after proposal is posted)
  royalty_pct_weight          DECIMAL(10,6) NOT NULL,

  voted_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (proposal_id, voter_user_id)
);

CREATE INDEX proposals_campaign_idx ON campaign_proposals (campaign_id, status);
CREATE INDEX votes_proposal_idx     ON campaign_votes (proposal_id);
CREATE INDEX votes_voter_idx        ON campaign_votes (voter_user_id);
```

**Governance rules (proposed — confirm before build):**
- Simple majority: proposal passes if `royalty_pct_approved > royalty_pct_rejected`
- Quorum required: `total_royalty_pct_voted >= 25%` of outstanding stake
- Maximum single proposal: 20% of current `escrow_balance_usd_cents`
- Cooling period: creator cannot re-propose a rejected item for 30 days
- Voting window: 72 hours from `voting_opens_at`

---

### 5h. Secondary Market

```sql
-- Backers can list their stake for sale after campaign is 'active'.
-- Simple buy-now listing model for MVP. Order book is post-MVP.
CREATE TABLE campaign_stake_listings (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id                 UUID NOT NULL REFERENCES campaigns(id),
  seller_user_id              UUID NOT NULL REFERENCES auth.users(id),

  royalty_pct_for_sale        DECIMAL(10,6) NOT NULL CHECK (royalty_pct_for_sale > 0),
  asking_price_usd_cents      BIGINT NOT NULL CHECK (asking_price_usd_cents > 0),

  status                      TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active','sold','cancelled','expired')),

  -- Listing expires after 30 days if not sold (proposed — confirm)
  expires_at                  TIMESTAMPTZ NOT NULL,
  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Completed secondary market transactions.
-- On sale: write two ownership_ledger rows (seller → void [fee portion], void → buyer [net])
-- and update listing status to 'sold'.
CREATE TABLE campaign_stake_sales (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id                  UUID NOT NULL REFERENCES campaign_stake_listings(id),
  campaign_id                 UUID NOT NULL REFERENCES campaigns(id),
  buyer_user_id               UUID NOT NULL REFERENCES auth.users(id),
  seller_user_id              UUID NOT NULL REFERENCES auth.users(id),

  royalty_pct_transferred     DECIMAL(10,6) NOT NULL,
  price_paid_usd_cents        BIGINT NOT NULL,

  -- Fee breakdown
  buyer_fee_usd_cents         BIGINT NOT NULL DEFAULT 0,   -- 0.5% of price
  seller_fee_usd_cents        BIGINT NOT NULL DEFAULT 0,   -- 0.5% of price
  total_fee_usd_cents         BIGINT NOT NULL DEFAULT 0,

  stripe_payment_intent_id    TEXT,
  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,
  completed_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX listings_campaign_idx ON campaign_stake_listings (campaign_id, status);
CREATE INDEX listings_seller_idx   ON campaign_stake_listings (seller_user_id, status);
CREATE INDEX sales_buyer_idx       ON campaign_stake_sales (buyer_user_id);
CREATE INDEX sales_seller_idx      ON campaign_stake_sales (seller_user_id);
```

---

### 5i. Unclaimed Balances

```sql
-- Failed distributions sit here. Trusted contact / next of kin notified.
CREATE TABLE campaign_unclaimed_balances (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                     UUID NOT NULL REFERENCES auth.users(id),
  campaign_id                 UUID NOT NULL REFERENCES campaigns(id),

  usd_cents                   BIGINT NOT NULL DEFAULT 0,
  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,

  last_distribution_attempt_at TIMESTAMPTZ,
  trusted_contact_notified_at  TIMESTAMPTZ,
  status                      TEXT NOT NULL DEFAULT 'holding'
    CHECK (status IN (
      'holding',              -- awaiting valid payment method
      'contact_notified',     -- trusted contact email sent
      'transferred_to_estate',-- next of kin confirmed, funds transferred
      'platform_held'         -- unclaimed past legal holding period
    )),
  notes                       TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (user_id, campaign_id)
);
```

---

### 5j. Campaign Updates (creator communications)

```sql
-- Creator posts updates to all backers. Backed by notification fan-out.
CREATE TABLE campaign_updates (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id                 UUID NOT NULL REFERENCES campaigns(id),
  creator_id                  UUID NOT NULL REFERENCES auth.users(id),

  title                       TEXT NOT NULL,
  body                        TEXT NOT NULL,
  update_type                 TEXT NOT NULL CHECK (update_type IN (
    'milestone',    -- reached a goal (e.g. "album recorded!")
    'progress',     -- general update
    'proposal',     -- linked to a governance proposal
    'revenue',      -- linked to a revenue event
    'urgent'        -- platform or creator flags as time-sensitive
  )),
  linked_proposal_id          UUID REFERENCES campaign_proposals(id),
  linked_revenue_event_id     UUID REFERENCES campaign_revenue_events(id),

  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,
  published_at                TIMESTAMPTZ,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

---

## 6. Campaign Lifecycle State Machine

```
[draft]
  Creator fills out campaign details, links work to platform connections.
  Not visible publicly.
        ↓  Creator submits for review
[pending]
  Platform reviews. SEC Form C filing prepared.
  No investments yet.
        ↓  Platform approves + Form C filed
[open]
  Investment window live. Backers can invest.
  Escrow account created. Countdown clock running.
  KYC gate enforced at investment. Reg CF limits enforced for US investors.
     ↓ (goal reached before closes_at)        ↓ (closes_at passes, goal not met)
[funded]                                    [failed]
  Escrow locked.                              Full refund to all backers.
  Creator delivers work.                      Ownership ledger rows reversed.
  Platform verifies delivery.
        ↓  Creator uploads first revenue event / platform API pulls data
[active]
  Royalties flowing.
  Governance proposals enabled.
  Secondary market enabled.
        ↓  (only if royalty_term_years was set AND term expires)
[closed]
  No further distributions. Final unclaimed balance sweep.
```

---

## 7. Revenue Verification — Layered Roadmap

The same schema accepts each phase. Only `evidence_type` and the ingestion
pipeline change.

### Phase 1 — MVP: Creator Self-Report
- Creator uploads royalty statement PDF via the app
- Platform admin (or automated OCR in future) inputs the numbers
- `evidence_type = 'creator_upload'`
- Revenue event marked `verified` after admin review
- Display stream counts pulled from existing Spotify/YouTube OAuth tokens

### Phase 2 — CSV Import
- Creator exports from DistroKid / TuneCore / CD Baby and uploads CSV
- Platform parses known formats automatically
- `evidence_type = 'csv_export'`

### Phase 3 — Direct API Pull
- Use existing OAuth tokens (Spotify, YouTube) to pull revenue data
- Spotify: Spotify for Artists API (requires partnership or elevated access)
- YouTube: YouTube Analytics API (accessible with existing OAuth scopes + `yt-analytics.readonly`)
- `evidence_type = 'api_pull'`

### Phase 4 — Data Partnerships
- Direct agreements with Spotify, YouTube, DistroKid, TuneCore, Apple Music
- Platform receives revenue data feeds directly
- `evidence_type = 'data_partnership'`
- **This is the target state.** Partners benefit because the platform drives
  creators to maximize output on their platforms.

### Phase 5 — On-Chain Oracle (Post NORA Coin Launch)
- Verified revenue data committed on-chain via oracle
- Smart contract automatically calculates and distributes royalties in NORA coin
- `evidence_type = 'oracle'`
- Full trustless settlement — no platform intervention required for distributions

---

## 8. Platform Plug-In Vision (future)

Each major monetization platform will have a NORA plug-in / integration that
creates a verified data bridge:

| Platform | Data available today | Target via partnership |
|---|---|---|
| Spotify | Stream counts (OAuth) | Per-stream revenue, monthly royalty totals |
| YouTube | View counts, watch time (Analytics API) | AdSense revenue per video |
| Twitch | Subscriber count, viewer count | Subscription revenue, bits |
| TikTok | View counts | Creator Fund payments |
| Apple Music | (no public API) | Royalty statements via MusicKit partnership |
| DistroKid | CSV export | Direct API feed |
| TuneCore | CSV export | Direct API feed |

The plug-in architecture: each platform gets an edge function
(`campaign-pull-[platform]`) that reads the creator's existing OAuth token,
calls the platform's analytics endpoint, and writes a `campaign_revenue_event`
row. All plug-ins write to the same table. Adding a new platform = adding one
edge function.

---

## 9. Share & Discovery Layer

### Unique Campaign URL
Every campaign: `noraplatforms.com/campaign/:id`

### Open Graph (Vercel Edge Function)
A Vercel edge middleware intercepts bot/crawler requests to `/campaign/:id`,
fetches campaign data from Supabase, and injects OG meta tags:
- `og:title` — campaign title + creator name
- `og:description` — short pitch + royalty offer summary
- `og:image` — campaign cover image
- `og:url` — canonical campaign URL

When the URL is pasted on X, Facebook, Discord, WhatsApp, or iMessage, a rich
preview card renders automatically. No platform API permissions required.

### Share Buttons (in-app Flutter widget)
Pre-filled intent URLs — no API permissions needed:

| Platform | URL pattern |
|---|---|
| X | `twitter.com/intent/tweet?text=...&url=...` |
| Facebook | `facebook.com/sharer/sharer.php?u=...` |
| WhatsApp | `wa.me/?text=...` |
| LinkedIn | `linkedin.com/shareArticle?url=...` |
| Copy link | Flutter Clipboard API |

### Attribution (campaign referral)
Share URLs carry `?ref=username&src=platform` to track which creator/user drove
traffic. Plugs into the existing `referral_bonus` token transaction pattern.

---

## 10. KYC Flow (per investor, at first investment attempt)

```
1. User taps "Invest" on any campaign
2. Platform checks kyc_verifications for this user
3. If no KYC or expired → launch KYC flow:
   a. Stripe Identity: government ID scan + selfie
   b. Address confirmation form
   c. Trusted contact / next of kin form
   d. If US resident: income and net worth declaration
      → Platform computes Reg CF annual limit
      → Stores in kyc_verifications.reg_cf_invested_ytd_cents
4. KYC submitted → status = 'in_review' (auto-approved in simulated mode)
5. Approved → user can invest
6. At each investment: check remaining Reg CF limit for US users
7. KYC expires 1 year from verified_at → re-verification required
```

---

## 11. Simulation Mode

### Purpose
Prove the entire system end-to-end — funding, governance, revenue events,
distributions, secondary market — with no real money and no regulatory
friction. Simulated campaigns can be made public to demonstrate the product
to investors and for user testing.

### Rules
- `campaigns.mode = 'simulated'` for all test campaigns
- All backer ledger rows: `is_simulated = TRUE`
- Investments deduct from `sim_usd_balances` (seeded at $10,000 per user)
- No Stripe calls made for simulated investments, distributions, or sales
- Revenue events can be manually inserted by platform admin to trigger distribution flow
- KYC in simulated mode: auto-approved with minimal data collection
- Secondary market listings and sales fully functional in simulation
- Governance proposals and votes fully functional in simulation

### Toggle to Live
When regulatory approval is in place:
1. Admin flips `campaigns.mode = 'live'` for a specific campaign
2. New investments route through Stripe Connect + real KYC gate
3. Existing simulated ownership ledger rows are flagged as `is_simulated = TRUE`
   and a new live investment flow begins from zero for the live version

---

## 12. On-Chain Migration Path

When the NORA coin launches:

1. **Ownership ledger export**: each `campaign_ownership_ledger` row maps to a
   token mint event on the NORA chain. The append-only design means the ledger
   *is* the blockchain history, just stored in Postgres.

2. **Token representation**: each campaign becomes an ERC-20 (or NORA-native)
   token. Holding N tokens = owning N / total_supply × royalty_pct_offered of
   royalties.

3. **Smart contract governance**: the `campaign_proposals` + `campaign_votes`
   tables map to an on-chain DAO-style governance contract. Votes are signed
   transactions.

4. **Distribution settlement**: royalty distributions move from Stripe transfers
   to on-chain token transfers. Fiat USD revenue is converted to NORA coin at
   prevailing rate (or stablecoin equivalent) before distribution.

5. **Escrow migration**: Stripe Treasury escrow replaced by smart contract escrow.
   Proposal execution requires contract-level multisig (governance vote outcome
   written on-chain triggers fund release).

**Design rule enforced today**: all monetary amounts stored as integer cents in
Postgres. Migration maps 1 USD cent = defined NORA coin unit at launch exchange
rate. No floating point anywhere.

---

## 13. Design Decisions (all confirmed 2026-05-23 — ready to build)

| # | Question | Decision |
|---|---|---|
| 1 | Platform fee model | **Option B**: 3% at funding close + 1.5% per distribution + 0.5% per secondary trade side (0.5% seller + 0.5% buyer) |
| 2 | Governance voting threshold | **Confirmed**: simple majority (>50% royalty-weighted), 25% quorum, 72h window, max 20% escrow per proposal |
| 3 | Secondary market listing expiry | **No expiry** — listings stay live until filled or manually cancelled |
| 4 | Creator eligibility gate | **Yes** — must have ≥1 monetization platform connected before launching |

---

## 14. Build Order

### Phase 1 — Foundation (build first)
1. `kyc_verifications` table + Stripe Identity integration
2. `sim_usd_balances` and `sim_usd_transactions` tables
3. `campaigns` table + campaign creation Flutter screen
4. Campaign status state machine edge function
5. `campaign_ownership_ledger` + investment flow (simulated)
6. Campaign page Flutter screen + Vercel OG edge function

### Phase 2 — Revenue & Distributions
7. `campaign_revenue_events` table + creator upload UI
8. Distribution calculation edge function
9. `campaign_distributions` table + simulated payout flow
10. Backer dashboard — earnings view

### Phase 3 — Governance
11. `campaign_proposals` + `campaign_votes` tables
12. Proposal creation + voting Flutter screens
13. Proposal execution edge function (releases escrow)
14. `campaign_updates` + notification fan-out

### Phase 4 — Secondary Market
15. `campaign_stake_listings` + `campaign_stake_sales` tables
16. Listing creation + browse Flutter screens
17. Purchase flow (simulated)
18. Ownership recalculation after transfer

### Phase 5 — Live Mode
19. Stripe Connect escrow integration
20. Real KYC flow (Stripe Identity, full AML)
21. Reg CF investor limit enforcement
22. SEC Form C filing workflow
23. Toggle simulated → live campaigns

### Phase 6 — Revenue API Integrations
24. YouTube Analytics revenue pull (existing OAuth token)
25. DistroKid CSV parser
26. Spotify for Artists (requires elevated access / partnership)
27. Direct data partnership integrations

### Phase 7 — On-Chain (post NORA coin launch)
28. Ownership ledger → token mint migration
29. Smart contract governance
30. On-chain distribution settlement
