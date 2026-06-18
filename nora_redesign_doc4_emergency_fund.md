# NORA Redesign — Doc 4: N.O.R.A. Emergency Fund
# For Claude Code — Read in full before touching any file.
# Apply after docs 1–3. Migrations begin at 090.
# Companion docs: doc1_schema.md | doc2_game_logic.md | doc3_marketplace_polls.md

---

## Feature Overview

The N.O.R.A. Emergency Fund is a community-governed mutual aid pool.
Anyone can contribute. Anyone can request funds for a genuine emergency.
An AI evaluates requests and facilitates community voting.
The community decides. The platform never manages the money.

**Who holds the money**: Stripe Treasury (FDIC-insured accounts held by
Stripe's banking partners). The platform holds zero funds directly.
Contributions arrive via Stripe Checkout into a dedicated Treasury account.
Approved disbursements are triggered via Stripe Treasury payout API.
The platform's only role is to orchestrate the AI evaluation and voting process
and then call the Stripe API when the community approves a request.

**Name**: N.O.R.A. Emergency Fund (user-facing). Internal prefix: `ubi_`.

**Attorney review required** before going live, same as Campaigns.
Frame as: community mutual aid pool, not insurance, not a financial product.
Contributions are voluntary donations. Disbursements are community-approved grants.
The platform is a facilitator, not a fund manager.

---

## Platform Role (Critical — Never Deviate From This)

The platform:
- Provides the contribution checkout (Stripe)
- Receives and routes requests to the AI evaluator (Claude Sonnet 4.6)
- Assembles random voting panels from eligible contributors
- Tallies votes and triggers disbursement when threshold is met
- Calls Stripe API to disburse approved funds

The platform does NOT:
- Hold funds (Stripe Treasury does)
- Make disbursement decisions (the voting panel does)
- Recommend vote directions (the AI does not either)
- Have access to personal documents (they are uploaded to Supabase Storage,
  read only by the AI via the Anthropic API, never exposed to voters or staff)

---

## Core Rules

| Rule | Value |
|---|---|
| Request cap | Lesser of 10% of pool balance or $1,000 |
| Minimum contribution to vote | $1 lifetime total (any time) |
| Voting panel size | $0–$100 request = 11 voters; $101–$500 = 21 voters; $501+ = 51 voters |
| Vote threshold | Simple majority (>50% of votes cast) |
| Voting window | 72 hours from panel assembly |
| Inactive voter threshold | 24 hours without opening the assigned vote |
| Inactive replacement | One replacement per inactive voter, from contributor pool (no panel overlap) |
| Deadline extension | One 24-hour extension if <50% of panel has voted at the 72-hour mark |
| Revote | One per request, to a completely fresh panel with zero overlap |
| Cooldown after approval | 90 days before the same user can submit a new request |
| Anonymous contributions | Allowed — no account required to contribute |
| Requester KYC | Required before disbursement (Stripe Identity, same as kyc_verifications) |
| Document visibility | AI only — never shown to voters, staff, or other users |
| Voter summary | AI-generated neutral summary — no identifying details, no recommendation |
| Vote tally visibility | Hidden until voting closes (prevents bandwagon effect) |

---

## Migration 090 — Pool & Contributions

File: `supabase/migrations/090_ubi_pool.sql`

```sql
-- Pool configuration (single-row table — one global pool)
CREATE TABLE ubi_pool_config (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stripe_treasury_account_id  TEXT,              -- Set after Stripe Treasury is provisioned
  stripe_treasury_financial_account TEXT,        -- The Treasury financial account ID
  mode                        TEXT NOT NULL DEFAULT 'simulated'
    CHECK (mode IN ('simulated', 'live')),
  is_open_for_contributions   BOOLEAN NOT NULL DEFAULT TRUE,
  is_open_for_requests        BOOLEAN NOT NULL DEFAULT TRUE,
  max_request_pct_of_pool     DECIMAL(5,4) NOT NULL DEFAULT 0.1000,  -- 10%
  max_request_usd_cents       BIGINT NOT NULL DEFAULT 100000,          -- $1,000
  min_contribution_to_vote_cents BIGINT NOT NULL DEFAULT 100,          -- $1
  vote_window_hours           INTEGER NOT NULL DEFAULT 72,
  inactive_voter_hours        INTEGER NOT NULL DEFAULT 24,
  post_approval_cooldown_days INTEGER NOT NULL DEFAULT 90,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed default config
INSERT INTO ubi_pool_config DEFAULT VALUES;

-- Pool balance cache (updated after each contribution or disbursement)
-- The authoritative balance lives in Stripe Treasury; this is a cached display value.
CREATE TABLE ubi_pool_balance_cache (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  balance_usd_cents           BIGINT NOT NULL DEFAULT 0,
  sim_balance_usd_cents       BIGINT NOT NULL DEFAULT 0,  -- sim mode balance
  last_synced_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO ubi_pool_balance_cache DEFAULT VALUES;

-- Contributions: anyone can contribute, with or without an account
CREATE TABLE ubi_pool_contributions (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Contributor identity (at least one must be present)
  user_id                     UUID REFERENCES auth.users(id),   -- NULL if anonymous
  contributor_email           TEXT,                              -- for anonymous tracking

  amount_usd_cents            BIGINT NOT NULL CHECK (amount_usd_cents >= 100),  -- $1 minimum
  is_recurring                BOOLEAN NOT NULL DEFAULT FALSE,
  stripe_payment_intent_id    TEXT,
  stripe_subscription_id      TEXT,  -- for recurring contributions
  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,
  is_anonymous_display        BOOLEAN NOT NULL DEFAULT FALSE,  -- hide from public contribution list

  status                      TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'confirmed', 'failed', 'refunded')),
  confirmed_at                TIMESTAMPTZ,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX contributions_user_idx    ON ubi_pool_contributions (user_id, status);
CREATE INDEX contributions_status_idx  ON ubi_pool_contributions (status, confirmed_at DESC);

-- Voter eligibility view: users who have contributed at least the minimum
CREATE VIEW ubi_eligible_voters AS
  SELECT
    c.user_id,
    SUM(c.amount_usd_cents) AS total_contributed_cents,
    COUNT(*) AS contribution_count,
    MAX(c.confirmed_at) AS last_contributed_at
  FROM ubi_pool_contributions c
  WHERE c.status = 'confirmed'
    AND c.user_id IS NOT NULL
  GROUP BY c.user_id
  HAVING SUM(c.amount_usd_cents) >= (
    SELECT min_contribution_to_vote_cents FROM ubi_pool_config LIMIT 1
  );
```

---

## Migration 091 — Withdrawal Requests & Documents

File: `supabase/migrations/091_ubi_requests.sql`

```sql
-- Emergency fund withdrawal requests
CREATE TABLE ubi_withdrawal_requests (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  requester_user_id           UUID NOT NULL REFERENCES auth.users(id),

  -- Amount
  amount_requested_usd_cents  BIGINT NOT NULL CHECK (amount_requested_usd_cents > 0),

  -- Requester-supplied narrative (PRIVATE — never shown to voters)
  request_narrative           TEXT NOT NULL,     -- the person's explanation in their own words

  -- Emergency category (requester selects)
  emergency_category          TEXT NOT NULL CHECK (emergency_category IN (
    'medical',       -- medical bills, prescriptions, procedures
    'housing',       -- rent, eviction, emergency repairs
    'utilities',     -- shutoff notices, heating/cooling
    'food',          -- food insecurity, childcare costs
    'transportation',-- vehicle repair needed for employment
    'funeral',       -- burial/funeral costs
    'disaster',      -- fire, flood, natural disaster
    'other'          -- anything not covered above
  )),

  -- Lifecycle state
  status                      TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN (
      'draft',              -- requester filling out form
      'pending_ai_review',  -- submitted, AI evaluating
      'pending_documents',  -- AI requested documents, awaiting upload
      'pending_vote',       -- documents verified, vote panel being assembled
      'voting',             -- active vote in progress
      'approved',           -- majority voted yes, pending disbursement
      'disbursed',          -- funds sent
      'denied',             -- vote failed (first round)
      'revote_requested',   -- user requested revote after denial
      'revote_voting',      -- second vote in progress
      'revote_denied',      -- second vote also failed — permanently closed
      'withdrawn',          -- requester withdrew their own request
      'voided'              -- admin void (fraud, terms violation)
    )),

  -- Vote tracking
  current_vote_round          INTEGER NOT NULL DEFAULT 1,  -- 1 = first, 2 = revote
  revote_eligible             BOOLEAN NOT NULL DEFAULT TRUE,  -- becomes FALSE after revote used

  -- Cooldown enforcement
  cooldown_until              TIMESTAMPTZ,  -- populated on disbursement

  -- Stripe disbursement
  stripe_payout_id            TEXT,
  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,

  submitted_at                TIMESTAMPTZ,
  approved_at                 TIMESTAMPTZ,
  disbursed_at                TIMESTAMPTZ,
  denied_at                   TIMESTAMPTZ,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX requests_user_idx    ON ubi_withdrawal_requests (requester_user_id, status);
CREATE INDEX requests_status_idx  ON ubi_withdrawal_requests (status, submitted_at DESC);

-- Supporting documents (uploaded by requester at AI's request)
-- Never exposed to voters or platform staff. AI reads via Anthropic API.
CREATE TABLE ubi_request_documents (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id                  UUID NOT NULL REFERENCES ubi_withdrawal_requests(id) ON DELETE CASCADE,
  requester_user_id           UUID NOT NULL REFERENCES auth.users(id),

  document_type               TEXT NOT NULL,     -- e.g. 'medical_bill', 'eviction_notice'
  document_label              TEXT NOT NULL,     -- human-readable, set by AI's ask
  storage_path                TEXT NOT NULL,     -- Supabase Storage path (private bucket)
  file_name                   TEXT NOT NULL,
  file_size_bytes             INTEGER NOT NULL,
  mime_type                   TEXT NOT NULL CHECK (mime_type IN (
    'application/pdf', 'image/jpeg', 'image/png', 'image/webp'
  )),

  -- AI review status
  ai_reviewed                 BOOLEAN NOT NULL DEFAULT FALSE,
  ai_reviewed_at              TIMESTAMPTZ,

  uploaded_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX documents_request_idx ON ubi_request_documents (request_id);
```

---

## Migration 092 — AI Evaluations

File: `supabase/migrations/092_ubi_ai_evaluations.sql`

```sql
-- AI evaluation records for each request.
-- One row per evaluation pass (initial + document verification + any re-evaluations).
-- The AI never makes a funding recommendation. It facilitates the process only.

CREATE TABLE ubi_ai_evaluations (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id                  UUID NOT NULL REFERENCES ubi_withdrawal_requests(id) ON DELETE CASCADE,
  evaluation_pass             INTEGER NOT NULL DEFAULT 1,  -- 1=initial, 2=after docs, 3=re-eval

  -- AI output
  -- Documents the AI asked the requester to provide
  documents_requested         JSONB NOT NULL DEFAULT '[]'::JSONB,
  -- [{type: 'medical_bill', label: 'Medical bill or Explanation of Benefits', rationale: '...'}]

  -- The neutral summary shown to voters (no PII, no recommendation)
  voter_summary               TEXT,

  -- Internal AI notes (never shown to anyone — for audit only)
  internal_assessment         TEXT,

  -- Document review result (populated on pass >= 2)
  documents_consistent        BOOLEAN,
  requires_additional_docs    JSONB DEFAULT '[]'::JSONB,

  -- Whether request appears to be within fund scope
  within_fund_scope           BOOLEAN,

  -- Anthropic API metadata
  model_used                  TEXT NOT NULL DEFAULT 'claude-sonnet-4-6',
  input_tokens                INTEGER,
  output_tokens               INTEGER,

  evaluated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (request_id, evaluation_pass)
);

CREATE INDEX evaluations_request_idx ON ubi_ai_evaluations (request_id);
```

---

## Migration 093 — Voting Panels

File: `supabase/migrations/093_ubi_voting.sql`

```sql
-- A voting panel is assembled for each vote round (initial + revote if needed).
-- Voters are randomly selected from ubi_eligible_voters.
-- Panels have zero overlap between first vote and revote.

CREATE TABLE ubi_voting_panels (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id                  UUID NOT NULL REFERENCES ubi_withdrawal_requests(id),
  vote_round                  INTEGER NOT NULL DEFAULT 1,  -- 1 = initial, 2 = revote
  panel_size                  INTEGER NOT NULL,             -- 11, 21, or 51

  status                      TEXT NOT NULL DEFAULT 'assembling'
    CHECK (status IN ('assembling', 'open', 'closed', 'timed_out')),

  -- Running totals (updated as votes come in — hidden from voters until closed)
  votes_yes                   INTEGER NOT NULL DEFAULT 0,
  votes_no                    INTEGER NOT NULL DEFAULT 0,
  votes_received              INTEGER NOT NULL DEFAULT 0,

  -- Outcome
  outcome                     TEXT CHECK (outcome IN ('approved', 'denied', 'inconclusive')),

  -- Timing
  opened_at                   TIMESTAMPTZ,
  closes_at                   TIMESTAMPTZ,   -- opened_at + 72 hours
  extended_until              TIMESTAMPTZ,   -- set if 24-hour extension triggered
  closed_at                   TIMESTAMPTZ,

  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (request_id, vote_round)
);

-- Individual voter assignments within a panel
CREATE TABLE ubi_panel_assignments (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  panel_id                    UUID NOT NULL REFERENCES ubi_voting_panels(id) ON DELETE CASCADE,
  request_id                  UUID NOT NULL REFERENCES ubi_withdrawal_requests(id),
  voter_user_id               UUID NOT NULL REFERENCES auth.users(id),

  -- Assignment state
  assignment_status           TEXT NOT NULL DEFAULT 'pending'
    CHECK (assignment_status IN (
      'pending',     -- notification sent, not yet opened
      'opened',      -- voter opened the request summary
      'voted',       -- voter submitted their vote
      'inactive',    -- voter did not respond within inactive_voter_hours
      'replaced'     -- voter was replaced (inactive); a replacement was assigned
    )),

  replaced_by_assignment_id   UUID REFERENCES ubi_panel_assignments(id),
  is_replacement              BOOLEAN NOT NULL DEFAULT FALSE,
  replaced_inactive_assignment_id UUID REFERENCES ubi_panel_assignments(id),  -- who this replaced

  -- Timing
  notified_at                 TIMESTAMPTZ,
  opened_at                   TIMESTAMPTZ,
  voted_at                    TIMESTAMPTZ,
  personal_deadline           TIMESTAMPTZ,   -- notified_at + 24h (for inactive check)

  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- A user can only appear once per panel (no duplicates, no revote panel overlap enforced at query level)
  UNIQUE (panel_id, voter_user_id)
);

CREATE INDEX assignments_panel_idx   ON ubi_panel_assignments (panel_id, assignment_status);
CREATE INDEX assignments_voter_idx   ON ubi_panel_assignments (voter_user_id, assignment_status);
CREATE INDEX assignments_inactive_idx ON ubi_panel_assignments (personal_deadline, assignment_status)
  WHERE assignment_status = 'pending' OR assignment_status = 'opened';

-- Individual votes (separate from assignments for clean separation of concerns)
CREATE TABLE ubi_panel_votes (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  assignment_id               UUID NOT NULL UNIQUE REFERENCES ubi_panel_assignments(id),
  panel_id                    UUID NOT NULL REFERENCES ubi_voting_panels(id),
  voter_user_id               UUID NOT NULL REFERENCES auth.users(id),

  vote                        TEXT NOT NULL CHECK (vote IN ('yes', 'no')),
  -- Individual votes are permanently private.
  -- Only aggregate totals on ubi_voting_panels are ever surfaced.

  voted_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Note: No index on vote column — individual vote values must never be queryable
-- by anyone other than internal audit functions running as SECURITY DEFINER.
CREATE INDEX votes_panel_idx ON ubi_panel_votes (panel_id);
```

---

## Migration 094 — Disbursements & Revotes

File: `supabase/migrations/094_ubi_disbursements.sql`

```sql
-- Disbursement records (one per approved request)
CREATE TABLE ubi_disbursements (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id                  UUID NOT NULL UNIQUE REFERENCES ubi_withdrawal_requests(id),
  recipient_user_id           UUID NOT NULL REFERENCES auth.users(id),

  amount_usd_cents            BIGINT NOT NULL,

  -- Stripe payout details (populated in live mode)
  stripe_payout_id            TEXT,
  stripe_destination_account  TEXT,   -- recipient's Stripe Connect or bank account

  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,

  -- Simulated: credited to sim_usd_balances
  status                      TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
  failed_reason               TEXT,

  initiated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at                TIMESTAMPTZ
);

-- Public-facing anonymized disbursement log (shown on fund landing page to build trust)
-- No PII. Populated after each successful disbursement.
CREATE TABLE ubi_public_disbursement_log (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  disbursement_id             UUID NOT NULL REFERENCES ubi_disbursements(id),
  amount_usd_cents            BIGINT NOT NULL,
  emergency_category          TEXT NOT NULL,   -- from ubi_withdrawal_requests.emergency_category
  month_year                  TEXT NOT NULL,   -- e.g. 'June 2026' (no specific date)
  votes_yes                   INTEGER NOT NULL,
  votes_total                 INTEGER NOT NULL,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
  -- No user_id, no name, no identifying details
);

CREATE INDEX public_log_category_idx ON ubi_public_disbursement_log (emergency_category);
CREATE INDEX public_log_date_idx     ON ubi_public_disbursement_log (month_year);
```

---

## AI Evaluation Edge Function

File: `supabase/functions/ubi-ai-evaluate/index.ts`

This function is called internally — not directly by Flutter. It is triggered by:
1. `ubi-submit-request` (initial evaluation, pass 1)
2. `ubi-process-documents` (document verification, pass 2)

```typescript
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const ANTHROPIC_API = 'https://api.anthropic.com/v1/messages';

// System prompt: defines the AI's role and hard constraints.
// The AI is a facilitator — never a decision-maker.
const AI_SYSTEM_PROMPT = `You are an intake coordinator for the N.O.R.A. Emergency Fund,
a community mutual aid pool. Your job is to help structure withdrawal requests so that
a community voting panel can make an informed decision.

Your responsibilities:
1. Evaluate whether the request falls within the fund's scope (genuine emergency needs).
2. Determine what supporting documents, if any, are appropriate to request.
3. Write a neutral, factual summary of the request for the voting panel.

Hard rules you must never violate:
- NEVER recommend that the voting panel approve or deny the request.
- NEVER include the applicant's name, location, employer, specific medical facility,
  or any other personally identifying information in the voter summary.
- Describe situations in general terms: "unexpected medical procedure" not
  "appendectomy at [Hospital Name] on [Date]".
- Be compassionate but objective. Assume good faith unless documents are inconsistent.
- If the request is outside the fund's scope (e.g., luxury purchases, business investments,
  gambling debts), set within_fund_scope to false. The request will not proceed to a vote.

Fund scope covers: medical expenses, housing emergencies (rent, eviction, repairs),
utility shutoffs, food insecurity, childcare emergencies, transportation needed for
employment, funeral/burial costs, natural disaster recovery.

Document request guidelines by category:
- medical: Explanation of Benefits, medical bill, or hospital statement
- housing: Eviction notice, rent ledger, or lease + landlord communication
- utilities: Utility shutoff notice or past-due bill
- food/childcare: No documents required — narrative is sufficient for small amounts
- transportation: Repair estimate or mechanic invoice
- funeral: Death certificate and/or funeral home invoice
- disaster: Insurance claim, official disaster declaration, or news reference
- other: Use judgment — request only what is genuinely needed to understand the situation

Respond ONLY in valid JSON. No preamble, no markdown.`;

interface EvaluationResult {
  within_fund_scope: boolean;
  documents_requested: Array<{
    type: string;
    label: string;
    rationale: string;
  }>;
  voter_summary: string;
  internal_assessment: string;
  documents_consistent?: boolean;
  requires_additional_docs?: Array<{ type: string; label: string; rationale: string }>;
}

serve(async (req) => {
  // Admin-only internal call — gate with service role key check
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  );

  const { request_id, evaluation_pass } = await req.json();

  // Fetch the withdrawal request
  const { data: request } = await supabase
    .from('ubi_withdrawal_requests')
    .select('*, ubi_request_documents(*)')
    .eq('id', request_id)
    .single();

  if (!request) {
    return new Response(JSON.stringify({ error: 'Request not found' }), { status: 404 });
  }

  // Build message content
  const userMessageContent: unknown[] = [];

  // Pass 1: Initial evaluation (no documents yet)
  if (evaluation_pass === 1) {
    userMessageContent.push({
      type: 'text',
      text: JSON.stringify({
        task: 'initial_evaluation',
        emergency_category: request.emergency_category,
        amount_requested_usd: (request.amount_requested_usd_cents / 100).toFixed(2),
        applicant_narrative: request.request_narrative,
        instructions: `Evaluate this request. Determine if it is within scope, what documents
          to request (if any), and write a neutral voter summary. Respond in JSON matching
          this schema: { within_fund_scope: boolean, documents_requested: [{type, label, rationale}],
          voter_summary: string, internal_assessment: string }`,
      }),
    });
  }

  // Pass 2: Document verification
  if (evaluation_pass === 2) {
    const docs = request.ubi_request_documents ?? [];

    userMessageContent.push({
      type: 'text',
      text: `You previously requested supporting documents for this ${request.emergency_category} emergency request of $${(request.amount_requested_usd_cents / 100).toFixed(2)}. The following documents have been uploaded. Review each one and determine if they are consistent with the stated need. Write an updated neutral voter summary reflecting what the documents confirm. Respond in JSON: { documents_consistent: boolean, voter_summary: string, internal_assessment: string, requires_additional_docs: [{type, label, rationale}] }`,
    });

    // Attach each uploaded document (PDF or image)
    for (const doc of docs) {
      if (doc.ai_reviewed) continue;  // skip already-reviewed docs

      // Download from Supabase Storage (private bucket)
      const { data: fileData } = await supabase.storage
        .from('ubi-documents')
        .download(doc.storage_path);

      if (!fileData) continue;

      const arrayBuffer = await fileData.arrayBuffer();
      const base64 = btoa(String.fromCharCode(...new Uint8Array(arrayBuffer)));

      if (doc.mime_type === 'application/pdf') {
        userMessageContent.push({
          type: 'document',
          source: { type: 'base64', media_type: 'application/pdf', data: base64 },
        });
      } else {
        userMessageContent.push({
          type: 'image',
          source: { type: 'base64', media_type: doc.mime_type, data: base64 },
        });
      }
    }
  }

  // Call Anthropic API
  const response = await fetch(ANTHROPIC_API, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: 'claude-sonnet-4-6',
      max_tokens: 1000,
      system: AI_SYSTEM_PROMPT,
      messages: [{ role: 'user', content: userMessageContent }],
    }),
  });

  if (!response.ok) {
    // Hard Rule 8: log and skip, never throw on API errors
    console.error('[ubi-ai-evaluate] Anthropic API error:', response.status);
    return new Response(JSON.stringify({ error: 'AI evaluation temporarily unavailable' }), { status: 503 });
  }

  const apiData = await response.json();
  const rawText = apiData.content?.find((b: { type: string }) => b.type === 'text')?.text ?? '{}';

  let result: EvaluationResult;
  try {
    const clean = rawText.replace(/```json|```/g, '').trim();
    result = JSON.parse(clean);
  } catch {
    console.error('[ubi-ai-evaluate] Failed to parse AI response:', rawText);
    return new Response(JSON.stringify({ error: 'AI response parse error' }), { status: 500 });
  }

  // Store evaluation
  await supabase.from('ubi_ai_evaluations').upsert({
    request_id,
    evaluation_pass,
    documents_requested: result.documents_requested ?? [],
    voter_summary: result.voter_summary ?? null,
    internal_assessment: result.internal_assessment ?? null,
    documents_consistent: result.documents_consistent ?? null,
    requires_additional_docs: result.requires_additional_docs ?? [],
    within_fund_scope: result.within_fund_scope ?? true,
    model_used: 'claude-sonnet-4-6',
    input_tokens: apiData.usage?.input_tokens ?? null,
    output_tokens: apiData.usage?.output_tokens ?? null,
  }, { onConflict: 'request_id,evaluation_pass' });

  // Mark documents as reviewed (pass 2)
  if (evaluation_pass === 2) {
    await supabase.from('ubi_request_documents')
      .update({ ai_reviewed: true, ai_reviewed_at: new Date().toISOString() })
      .eq('request_id', request_id);
  }

  // If out of scope, close the request immediately
  if (!result.within_fund_scope) {
    await supabase.from('ubi_withdrawal_requests')
      .update({ status: 'voided' })
      .eq('id', request_id);
    // Notify requester: request was outside fund scope
    return new Response(JSON.stringify({ outcome: 'out_of_scope' }), { status: 200 });
  }

  // Determine next step: request docs, or move to vote
  const docsNeeded = result.documents_requested?.length > 0 && evaluation_pass === 1;
  const additionalDocsNeeded = (result.requires_additional_docs?.length ?? 0) > 0 && evaluation_pass === 2;

  const nextStatus = docsNeeded || additionalDocsNeeded
    ? 'pending_documents'
    : 'pending_vote';

  await supabase.from('ubi_withdrawal_requests')
    .update({ status: nextStatus })
    .eq('id', request_id);

  return new Response(JSON.stringify({
    outcome: nextStatus,
    documents_requested: result.documents_requested ?? [],
  }), { status: 200 });
});
```

---

## Voting Panel Assembly

File: `supabase/functions/ubi-assemble-voting-panel/index.ts`

Called when a request moves to `pending_vote` status. Internal only.

```typescript
// Logic:
// 1. Determine panel size based on amount_requested_usd_cents:
//    <= 10000 ($100) → 11 voters
//    <= 50000 ($500) → 21 voters
//    > 50000         → 51 voters
//
// 2. Query ubi_eligible_voters for all eligible voters.
//    Exclude: the requester themselves.
//    For revote (vote_round = 2): also exclude all voters from round 1.
//
// 3. Randomly select panel_size voters from the eligible pool.
//    If eligible pool < panel_size, use all eligible voters (no minimum enforced —
//    the fund is new and the pool may be small at launch).
//
// 4. Insert ubi_voting_panels row.
// 5. Insert one ubi_panel_assignments row per selected voter.
// 6. Update ubi_withdrawal_requests.status = 'voting' (or 'revote_voting').
// 7. Send in-app notification to each assigned voter.

async function assemblePanelForRequest(requestId: string, voteRound: number, supabase: SupabaseClient) {
  const { data: request } = await supabase
    .from('ubi_withdrawal_requests')
    .select('requester_user_id, amount_requested_usd_cents')
    .eq('id', requestId)
    .single();

  const panelSize = request.amount_requested_usd_cents <= 10000 ? 11
    : request.amount_requested_usd_cents <= 50000 ? 21
    : 51;

  // Voters already used in round 1 (exclude from round 2)
  let excludedUserIds = [request.requester_user_id];
  if (voteRound === 2) {
    const { data: round1Assignments } = await supabase
      .from('ubi_panel_assignments')
      .select('voter_user_id')
      .eq('request_id', requestId);
    excludedUserIds = [
      ...excludedUserIds,
      ...(round1Assignments?.map(a => a.voter_user_id) ?? []),
    ];
  }

  // Eligible voter pool
  const { data: voters } = await supabase
    .from('ubi_eligible_voters')
    .select('user_id')
    .not('user_id', 'in', `(${excludedUserIds.join(',')})`);

  if (!voters || voters.length === 0) {
    console.warn('[ubi-assemble-panel] No eligible voters for request', requestId);
    return;
  }

  // Fisher-Yates shuffle for truly random selection
  const shuffled = [...voters].sort(() => Math.random() - 0.5);
  const selected = shuffled.slice(0, Math.min(panelSize, shuffled.length));

  const closesAt = new Date(Date.now() + 72 * 60 * 60 * 1000).toISOString();

  const { data: panel } = await supabase.from('ubi_voting_panels').insert({
    request_id: requestId,
    vote_round: voteRound,
    panel_size: selected.length,
    status: 'open',
    opened_at: new Date().toISOString(),
    closes_at: closesAt,
  }).select().single();

  // Assign voters
  const personalDeadline = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
  await supabase.from('ubi_panel_assignments').insert(
    selected.map(v => ({
      panel_id: panel.id,
      request_id: requestId,
      voter_user_id: v.user_id,
      assignment_status: 'pending',
      notified_at: new Date().toISOString(),
      personal_deadline: personalDeadline,
    }))
  );

  // Update request status
  const newStatus = voteRound === 1 ? 'voting' : 'revote_voting';
  await supabase.from('ubi_withdrawal_requests')
    .update({ status: newStatus })
    .eq('id', requestId);

  // Fire notifications (integrate with existing notification system)
  // Each voter gets: "You have been selected to vote on an Emergency Fund request."
  // Link: /emergency-fund/vote/{assignmentId}
}
```

---

## Vote Casting

### RPC: ubi_cast_vote(assignment_id, vote)

```sql
CREATE OR REPLACE FUNCTION ubi_cast_vote(
  p_assignment_id UUID,
  p_vote          TEXT  -- 'yes' | 'no'
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_assignment  ubi_panel_assignments%ROWTYPE;
  v_panel       ubi_voting_panels%ROWTYPE;
BEGIN
  IF p_vote NOT IN ('yes', 'no') THEN
    RAISE EXCEPTION 'Invalid vote value: %', p_vote;
  END IF;

  -- Fetch and lock assignment
  SELECT * INTO v_assignment
  FROM ubi_panel_assignments
  WHERE id = p_assignment_id AND voter_user_id = auth.uid()
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Assignment not found or not yours'; END IF;
  IF v_assignment.assignment_status NOT IN ('pending', 'opened') THEN
    RAISE EXCEPTION 'Assignment is not in a voteable state: %', v_assignment.assignment_status;
  END IF;

  -- Fetch panel
  SELECT * INTO v_panel
  FROM ubi_voting_panels
  WHERE id = v_assignment.panel_id AND status = 'open';

  IF NOT FOUND THEN RAISE EXCEPTION 'Panel is not open for voting'; END IF;
  IF v_panel.closes_at < NOW() AND (v_panel.extended_until IS NULL OR v_panel.extended_until < NOW()) THEN
    RAISE EXCEPTION 'Voting window has closed';
  END IF;

  -- Record vote
  INSERT INTO ubi_panel_votes (
    assignment_id, panel_id, voter_user_id, vote
  ) VALUES (
    p_assignment_id, v_assignment.panel_id, auth.uid(), p_vote
  );

  -- Update assignment
  UPDATE ubi_panel_assignments
  SET assignment_status = 'voted', voted_at = NOW()
  WHERE id = p_assignment_id;

  -- Update running totals on panel (hidden from voters until poll closes)
  UPDATE ubi_voting_panels
  SET
    votes_yes      = votes_yes + CASE p_vote WHEN 'yes' THEN 1 ELSE 0 END,
    votes_no       = votes_no  + CASE p_vote WHEN 'no'  THEN 1 ELSE 0 END,
    votes_received = votes_received + 1
  WHERE id = v_assignment.panel_id;

END;
$$;
```

---

## pg_cron Jobs

### ubi-vote-deadline-check (every 30 minutes)

```sql
SELECT cron.schedule(
  'ubi-vote-deadline-check',
  '*/30 * * * *',
  $$SELECT process_ubi_vote_deadlines();$$
);
```

```sql
CREATE OR REPLACE FUNCTION process_ubi_vote_deadlines()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_panel   ubi_voting_panels%ROWTYPE;
  v_request ubi_withdrawal_requests%ROWTYPE;
  v_outcome TEXT;
  v_approval_threshold DECIMAL;
BEGIN
  -- Find panels that have reached their close time
  FOR v_panel IN
    SELECT * FROM ubi_voting_panels
    WHERE status = 'open'
      AND (
        closes_at <= NOW()
        OR (extended_until IS NOT NULL AND extended_until <= NOW())
      )
    FOR UPDATE SKIP LOCKED
  LOOP
    -- Check if extension is needed (less than 50% voted at original deadline)
    IF v_panel.extended_until IS NULL
      AND v_panel.closes_at <= NOW()
      AND v_panel.votes_received < (v_panel.panel_size / 2)
    THEN
      -- One-time 24-hour extension
      UPDATE ubi_voting_panels
      SET extended_until = NOW() + INTERVAL '24 hours'
      WHERE id = v_panel.id;
      CONTINUE;
    END IF;

    -- Close the panel
    UPDATE ubi_voting_panels SET status = 'closed', closed_at = NOW() WHERE id = v_panel.id;

    -- Determine outcome
    IF v_panel.votes_received = 0 THEN
      v_outcome := 'inconclusive';
    ELSIF (v_panel.votes_yes::float / v_panel.votes_received::float) > 0.5 THEN
      v_outcome := 'approved';
    ELSE
      v_outcome := 'denied';
    END IF;

    UPDATE ubi_voting_panels SET outcome = v_outcome WHERE id = v_panel.id;

    -- Update the withdrawal request
    SELECT * INTO v_request FROM ubi_withdrawal_requests WHERE id = v_panel.request_id;

    IF v_outcome = 'approved' THEN
      UPDATE ubi_withdrawal_requests
      SET status = 'approved', approved_at = NOW()
      WHERE id = v_panel.request_id;
      -- Trigger disbursement (see ubi-disburse edge function)

    ELSIF v_outcome = 'denied' THEN
      IF v_panel.vote_round = 1 THEN
        UPDATE ubi_withdrawal_requests
        SET status = 'denied', denied_at = NOW()
        WHERE id = v_panel.request_id;
      ELSE
        -- Second vote also denied — permanently closed
        UPDATE ubi_withdrawal_requests
        SET status = 'revote_denied', denied_at = NOW(), revote_eligible = FALSE
        WHERE id = v_panel.request_id;
      END IF;

    ELSIF v_outcome = 'inconclusive' THEN
      -- Reassign to fresh panel (treat as if timed out)
      UPDATE ubi_voting_panels SET status = 'timed_out' WHERE id = v_panel.id;
      -- Assemble new panel for the same round via edge function call
      PERFORM net.http_post(
        url := current_setting('app.supabase_url') || '/functions/v1/ubi-assemble-voting-panel',
        body := json_build_object('request_id', v_panel.request_id, 'vote_round', v_panel.vote_round)::text,
        headers := json_build_object('Authorization', 'Bearer ' || current_setting('app.service_role_key'))::text
      );
    END IF;

  END LOOP;
END;
$$;
```

### ubi-inactive-voter-check (every hour)

```sql
SELECT cron.schedule(
  'ubi-inactive-voter-check',
  '0 * * * *',
  $$SELECT process_ubi_inactive_voters();$$
);
```

```sql
CREATE OR REPLACE FUNCTION process_ubi_inactive_voters()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_assignment ubi_panel_assignments%ROWTYPE;
  v_replacement_user_id UUID;
BEGIN
  -- Find assignments past their personal_deadline that haven't voted
  FOR v_assignment IN
    SELECT * FROM ubi_panel_assignments
    WHERE assignment_status IN ('pending', 'opened')
      AND personal_deadline < NOW()
    FOR UPDATE SKIP LOCKED
  LOOP
    -- Mark as inactive
    UPDATE ubi_panel_assignments
    SET assignment_status = 'inactive'
    WHERE id = v_assignment.id;

    -- Find a replacement: eligible voter not already on this panel
    SELECT ev.user_id INTO v_replacement_user_id
    FROM ubi_eligible_voters ev
    WHERE ev.user_id NOT IN (
      SELECT voter_user_id FROM ubi_panel_assignments
      WHERE request_id = v_assignment.request_id
    )
    ORDER BY RANDOM()
    LIMIT 1;

    IF v_replacement_user_id IS NULL THEN
      CONTINUE;  -- No replacement available; panel proceeds with current votes
    END IF;

    -- Assign replacement
    INSERT INTO ubi_panel_assignments (
      panel_id, request_id, voter_user_id,
      assignment_status, is_replacement,
      replaced_inactive_assignment_id,
      notified_at, personal_deadline
    ) VALUES (
      v_assignment.panel_id,
      v_assignment.request_id,
      v_replacement_user_id,
      'pending',
      TRUE,
      v_assignment.id,
      NOW(),
      NOW() + INTERVAL '24 hours'
    );

    -- Update original assignment to show it was replaced
    UPDATE ubi_panel_assignments
    SET replaced = TRUE  -- add this column in migration 093 if needed
    WHERE id = v_assignment.id;

  END LOOP;
END;
$$;
```

---

## Disbursement Edge Function

File: `supabase/functions/ubi-disburse/index.ts`

Internal — called by `process_ubi_vote_deadlines` when a vote approves.

```typescript
// Logic:
// 1. Verify request.status = 'approved'.
// 2. Verify KYC is complete for requester (kyc_verifications.status = 'approved').
//    If KYC missing: send notification asking requester to complete KYC, hold disbursement.
// 3. In simulated mode:
//    - Credit sim_usd_balances for the requester.
//    - Update ubi_pool_balance_cache (decrement sim_balance_usd_cents).
// 4. In live mode:
//    - Call Stripe Treasury API to initiate outbound transfer to requester's bank.
//    - Requester must have a linked bank account via Stripe Connect / Stripe Identity.
//    - Update ubi_pool_balance_cache after transfer confirmed.
// 5. Write ubi_disbursements row.
// 6. Write ubi_public_disbursement_log row (anonymized).
// 7. Update ubi_withdrawal_requests:
//    - status = 'disbursed'
//    - disbursed_at = NOW()
//    - cooldown_until = NOW() + 90 days
// 8. Notify requester: "Your Emergency Fund request has been approved. Funds are on their way."
```

---

## Contribution Edge Function

File: `supabase/functions/ubi-contribute/index.ts`
Deploy `--no-verify-jwt` (public, no account required to contribute).

```typescript
// Accepts anonymous or authenticated contributions.
// In sim mode: increments ubi_pool_balance_cache.sim_balance_usd_cents
//              and ubi_pool_contributions row.
// In live mode: creates Stripe Checkout session pointed at the Treasury account.
//               Stripe webhook confirms payment and writes contribution row.
//
// Request body:
// {
//   amount_usd_cents: number,  // min 100 ($1)
//   is_recurring: boolean,
//   contributor_email?: string,  // optional for anonymous contributors
//   is_anonymous_display: boolean
// }
```

---

## Flutter UI

### Route Structure

Add to GoRouter (all public except `/request` and `/my-requests`):

```dart
GoRoute(path: '/emergency-fund',
  builder: (_, __) => const EmergencyFundScreen()),           // public
GoRoute(path: '/emergency-fund/contribute',
  builder: (_, __) => const ContributeScreen()),              // public (Stripe opens)
GoRoute(path: '/emergency-fund/request',
  builder: (_, __) => const RequestFundsScreen()),            // auth required
GoRoute(path: '/emergency-fund/my-requests',
  builder: (_, __) => const MyRequestsScreen()),              // auth required
GoRoute(path: '/emergency-fund/vote/:assignmentId',
  builder: (_, state) => VoteScreen(
    assignmentId: state.pathParameters['assignmentId']!)),    // auth required
```

### EmergencyFundScreen — Landing Page

Public. The design should feel warm, human, and trustworthy — not clinical.

**Sections (top to bottom):**

1. **Hero panel**: NORA Emergency Fund logo/wordmark. Tagline:
   > "A community-powered emergency fund. Anyone can give. Anyone can ask."

2. **Pool balance card**: Current pool balance (from `ubi_pool_balance_cache`).
   Large number, formatted as dollars. Sub-line: "held securely by Stripe."
   Two buttons: "Contribute" (→ `/emergency-fund/contribute`) and
   "Request Funds" (→ `/emergency-fund/request`, auth gate).

3. **How it works** (3-step visual):
   - Step 1: "Tell us your need. Our AI reviews your request privately."
   - Step 2: "A random panel of fund contributors votes anonymously."
   - Step 3: "If approved, funds are sent directly to you via Stripe."

4. **Recent impact strip** (from `ubi_public_disbursement_log`):
   Anonymized tiles: "Medical · June 2026 · $840 · 17 of 21 voted yes"
   No names. No identifying details. Just category, month, amount, vote tally.

5. **FAQ accordion** (static, no data fetch):
   - "Who can contribute?" Anyone. No account required.
   - "Who can request funds?" Anyone with a NORA account.
   - "Who decides if I get funds?" A randomly selected group of contributors votes.
   - "Does the platform keep any of the money?" No. Stripe holds the pool.
   - "Are my documents private?" Yes. Only the AI reads them. Voters never see them.
   - "What counts as an emergency?" Medical, housing, utilities, food, transportation,
     funeral costs, and disaster recovery.

### RequestFundsScreen

Step-by-step flow (multi-step form, one step per screen):

**Step 1 — Amount**
- Input: how much do you need? (enforces pool cap dynamically)
- "The fund currently holds $X. Maximum request: $Y."

**Step 2 — Category**
- Dropdown or chip selection for emergency_category

**Step 3 — Your story**
- Large text field: "In your own words, tell us what happened and why you need help."
- Character minimum: 100 chars.
- Privacy note: "What you write here is private. Our AI will read it to understand your
  situation, but your words will never be shown to voters."

**Step 4 — AI Review (async)**
- Spinner: "Reviewing your request…"
- Calls `ubi-ai-evaluate` (pass 1) behind the scenes
- On complete: shows what documents are needed (if any) with clear explanations
- If no documents needed: "Your request is ready for a community vote."

**Step 5 — Document Upload (if required)**
- For each document the AI requested: file picker (PDF, JPG, PNG)
- Privacy note: "Documents are read only by the AI. Voters never see them."
- "Upload All Documents" → triggers pass 2 evaluation

**Step 6 — Submitted**
- "Your request is now with a community panel."
- "You'll be notified within 72 hours."
- Link → `/emergency-fund/my-requests`

### VoteScreen

Auth required. Accessible at `/emergency-fund/vote/:assignmentId`.

```
┌──────────────────────────────────────────────┐
│  N.O.R.A. Emergency Fund — Community Vote     │
│  Request #XXXX · $[amount] · [category]       │
│                                               │
│  ┌──────────────────────────────────────────┐ │
│  │  ABOUT THIS REQUEST                      │ │
│  │  [AI-generated neutral voter summary]    │ │
│  │                                          │ │
│  │  This is a privacy-protected summary.    │ │
│  │  The applicant's identity is not         │ │
│  │  disclosed to voters.                    │ │
│  └──────────────────────────────────────────┘ │
│                                               │
│  Pool balance: $X · Your vote is anonymous.  │
│  Voting closes in: [countdown timer]          │
│                                               │
│  [ ✓ Approve ] [ ✗ Deny ]                    │
│                                               │
│  Results are hidden until voting closes.      │
└──────────────────────────────────────────────┘
```

- On vote cast: buttons lock, confirmation message shown.
- After panel closes: voter sees the final result and tally.
- Voters receive a push/in-app notification for each assignment.

---

## New Edge Functions for docs/infra.md

```
### N.O.R.A. Emergency Fund
ubi-contribute              — anonymous or authenticated contribution (public, no-verify-jwt)
ubi-submit-request          — submit a withdrawal request (auth required)
ubi-upload-document         — upload supporting document to private Storage bucket (auth)
ubi-ai-evaluate             — internal AI evaluation (service role only)
ubi-assemble-voting-panel   — internal panel assembly (service role only)
ubi-cast-vote               — (RPC, not edge fn) voter submits yes/no
ubi-disburse                — internal disbursement trigger (service role only)
```

## New pg_cron Jobs for docs/infra.md

```
ubi-vote-deadline-check     every 30 min  — closes expired panels, triggers disbursement
ubi-inactive-voter-check    every hour    — replaces voters past their personal deadline
```

## New Routes for docs/infra.md

```
/emergency-fund             EmergencyFundScreen (public)
/emergency-fund/contribute  ContributeScreen (public)
/emergency-fund/request     RequestFundsScreen (auth)
/emergency-fund/my-requests MyRequestsScreen (auth)
/emergency-fund/vote/:id    VoteScreen (auth)
```

---

## CLAUDE.md Updates Required

Add to **Games** section (it is not a game, so add a new top-level section):

```
## Community Features
- **N.O.R.A. Emergency Fund**: Community mutual aid pool. Contributions via Stripe
  (anonymous allowed). Withdrawal requests evaluated by AI (Claude Sonnet 4.6),
  voted on by a random sample of contributors. Funds held by Stripe Treasury.
  Platform holds zero funds. Tables prefixed ubi_.
```

Add to **Hard Rules**:
```
23. ubi_ edge functions never hold, move, or credit funds directly — all money
    movement is via Stripe API or sim_usd_balances in simulated mode.
24. ubi_request_documents are stored in private Supabase Storage bucket 'ubi-documents'.
    They are downloaded only within ubi-ai-evaluate (service role). Never expose paths
    or signed URLs to any client or voter.
25. ubi_panel_votes individual vote values are never queryable outside SECURITY DEFINER
    audit functions. Voter privacy is permanent.
```

---

## Milestone Checklist

### Milestone 1 — Schema
- [ ] Migrations 090–094 applied with zero errors
- [ ] `ubi_eligible_voters` view returns correct results (test with a seeded contribution)
- [ ] Supabase Storage bucket `ubi-documents` created as **private** (no public access)

### Milestone 2 — AI Evaluation
- [ ] `ubi-ai-evaluate` returns valid JSON for a test request (pass 1)
- [ ] `ubi-ai-evaluate` with a document attachment returns consistent/inconsistent result (pass 2)
- [ ] Out-of-scope request (e.g., "buy a car") returns `within_fund_scope: false`
- [ ] Voter summary contains no PII (verified manually for several test cases)
- [ ] AI evaluation logged to `ubi_ai_evaluations` with token counts

### Milestone 3 — Voting
- [ ] `ubi-assemble-voting-panel` creates correct panel size for each amount tier
- [ ] Panel assignments created for selected voters
- [ ] Revote panel has zero overlap with round 1 panel
- [ ] `ubi_cast_vote` RPC rejects duplicate votes and closed-panel votes
- [ ] Running totals on `ubi_voting_panels` update correctly (hidden from public until closed)
- [ ] `process_ubi_vote_deadlines` closes panels and sets correct outcome
- [ ] 24-hour extension triggers correctly when <50% voted
- [ ] Inactive voter replacement fires and assigns a fresh voter

### Milestone 4 — Disbursement
- [ ] Approved request in sim mode credits requester's `sim_usd_balances`
- [ ] `ubi_pool_balance_cache` decrements after disbursement
- [ ] `cooldown_until` set to +90 days on `ubi_withdrawal_requests`
- [ ] `ubi_public_disbursement_log` populated with anonymized data (no PII)
- [ ] KYC gate holds disbursement if `kyc_verifications.status != 'approved'`

### Milestone 5 — Flutter UI
- [ ] `EmergencyFundScreen` renders pool balance from live data
- [ ] `RequestFundsScreen` multi-step flow completes without error
- [ ] Document upload reaches Supabase Storage `ubi-documents` (private bucket)
- [ ] `VoteScreen` shows AI summary and locks after vote cast
- [ ] Vote tally is hidden until panel closes (verified in dev)
- [ ] All new routes registered in GoRouter
- [ ] `flutter analyze` zero issues
- [ ] `flutter build web` no compile errors
