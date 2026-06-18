# NORA Redesign — Doc 3: Marketplace & Polls
# For Claude Code — Read in full before touching any file.
# Prerequisite: Apply migrations 079–089 from doc1_schema.md first.
# Companion docs: doc1_schema.md | doc2_game_logic.md

---

## Overview

This document covers:
1. Likeness Card Marketplace (UI + edge functions)
2. Battle Chit Marketplace (UI + edge functions)
3. Weekly Polls (schema, anti-abuse, shareable widget, stat application)
4. Celebrity Integration Steps
5. Open Graph / social share support

---

## 1. Likeness Card Marketplace

### Marketplace Screen Layout

File: `lib/features/marketplace/screens/marketplace_screen.dart`

Two tabs at the top of the screen:
- **Tab 1 — Characters**: Likeness card offerings + secondary listings
- **Tab 2 — Battle Chits**: Chit inventory + chit marketplace

The screen is accessible to all logged-in users at `/marketplace`.
The tab state persists in the URL query param: `/marketplace?tab=chits`.

### Tab 1 — Characters

Three sections stacked vertically:

**Section A — Featured Offerings** (cards being minted for the first time)
- Source: `likeness_offerings` WHERE `status = 'active'` ORDER BY `listed_at DESC`
- Card grid: character image, name, archetype, print run progress bar
  (`cards_minted / card_print_run`), price per card, rarity breakdown
- Tap → `OfferingDetailScreen`

**Section B — Secondary Market** (cards being resold by owners)
- Source: `card_marketplace_listings` WHERE `status = 'active'`
  JOIN `likeness_cards`, `likeness_offerings`
- Sort options: lowest price / highest rarity / recently listed
- Card tile: character image, card number, rarity badge, asking price
- Tap → `CardDetailScreen`

**Section C — My Cards** (the user's owned cards)
- Source: `likeness_cards` WHERE `current_owner_id = auth.uid()`
- Shows card number, character, rarity, button to list for sale
- Empty state: "You don't own any cards yet. Browse offerings above."

### OfferingDetailScreen

Route: `/marketplace/offering/:offeringId`

Contents:
- Character header: image, name, archetype chip, stat sheet mini-bar chart
- Offering details: total % offered, cards remaining, price per card
- Rarity breakdown table: Legendary (#1) / Rare (#2–10) / Standard (#11+)
- "Get a Card" button: triggers `likeness-purchase-card` edge function
- Card number distribution: list of which cards are available vs. minted
- Creator bio section: links to their public profile `/u/:username`
- Platform disclaimer (shown prominently):
  > "Character cards are collectible game items. Owning a card grants
  > Battle eligibility and a share of in-game match rewards for that
  > character. Cards have no guaranteed monetary value and are not
  > financial instruments."

### CardDetailScreen

Route: `/marketplace/card/:cardId`

Contents:
- Large card artwork (if available), card number badge, rarity indicator
- Stat sheet display (read from `creator_stat_sheets` for this card's `creator_id`)
- Match history: recent battles this character appeared in
- Ownership history: transfer log (from `likeness_card_transfers`, show
  from_user → to_user + date, mask usernames except current owner)
- Match reward history: token_transactions WHERE type IN
  ('match_passive_reward') AND reference_id IN (market_ids for this creator)
- Owner actions (only shown if `current_owner_id = auth.uid()`):
  - "List for Sale" → opens bottom sheet with price input
  - "Use in Battle" → navigates to `/battle` with character pre-selected
- Non-owner: "Make Offer" button (future — not in this phase)

### Edge Functions

**likeness-create-offering**
File: `supabase/functions/likeness-create-offering/index.ts`

Request body:
```typescript
{
  character_name: string;
  character_image_url?: string;
  archetype: string;
  total_pct_offered: number;    // e.g. 30 (= 30%)
  card_print_run: number;       // e.g. 100
  price_per_card_usd_cents: number;  // e.g. 999 ($9.99)
  mode: 'simulated' | 'live';
}
```

Logic:
1. Verify `auth.uid()` is a market maker (`is_market_maker = TRUE AND pending_opt_out = FALSE`)
2. Verify no other `active` offering exists for this creator (one active offering at a time)
3. Calculate `pct_per_card = total_pct_offered / card_print_run`
4. INSERT into `likeness_offerings` with `status = 'active'`, `listed_at = NOW()`
5. Return `{ offering_id }`

**likeness-purchase-card**
File: `supabase/functions/likeness-purchase-card/index.ts`

Request body: `{ offering_id: string }`

Logic:
1. In live mode: confirm Stripe PaymentIntent has already been created and confirmed.
   The Flutter client should call `create-checkout-session` first with `product_type: 'card'`,
   then call this function only after payment confirmation webhook fires.
2. In sim mode: call `likeness_mint_card(offering_id, auth.uid())` directly.
3. Return `{ card_id, card_number, rarity }`
4. Fire a notification to the buyer: "You minted Card #N — [Character Name]!"
5. Fire a notification to the creator: "Card #N of your [Character Name] offering was purchased."

**likeness-list-card**
File: `supabase/functions/likeness-list-card/index.ts`

Request body: `{ card_id: string, asking_price_usd_cents: number }`

Logic:
1. Verify caller owns the card (`current_owner_id = auth.uid()`)
2. Verify no existing active listing for this card
3. INSERT into `card_marketplace_listings`
4. Return `{ listing_id }`

**likeness-buy-listed-card**
File: `supabase/functions/likeness-buy-listed-card/index.ts`

Request body: `{ listing_id: string }`

Logic:
1. In sim mode: call `card_marketplace_purchase(listing_id, auth.uid())`
2. In live mode: confirm Stripe payment first (same pattern as `likeness-purchase-card`)
3. Return `{ sale_id, card_id }`
4. Fire notifications to buyer and seller

---

## 2. Battle Chit Marketplace

### Tab 2 — Battle Chits (within MarketplaceScreen)

Three sub-tabs within the Chits tab:
- **Earn**: Shows challenge rewards + match win probabilities for each chit tier
- **Browse**: Marketplace listings from other users
- **My Chits**: User's inventory with "Use" and "List" actions

### Earn Sub-tab

Static display (from `battle_chit_definitions`, read-only):

Table format:
| Chit | Rarity | How to Get | RNG Rate |
|---|---|---|---|
| Bronze Shield | Common | Challenges | — |
| Counter Stance | Rare | Match wins | 10% |
| Wild Card | Legendary | Match wins | 0.5% |
| NORA Aura | Mythic | Events/Gift | — |

Add a prominent banner at top:
> "The rarest chits can only be earned by grinding matches. Win more battles
> to increase your chances of a legendary drop."

### Browse Sub-tab

Source: `chit_marketplace_listings` WHERE `status = 'active'`
JOIN `battle_chit_definitions`

Filter by rarity. Sort by price. Each tile shows:
- Chit name, rarity badge (colored by tier), effect description, price in tokens

"Buy" action:
- Calls `chit-marketplace-buy` edge function
- Deducts tokens from `token_balances`

### My Chits Sub-tab

Source: `user_battle_chits` WHERE `user_id = auth.uid()` AND `quantity > 0`
JOIN `battle_chit_definitions`

Each tile: name, quantity owned, rarity badge, effect, two buttons:
- "Use in Battle" → navigates to `/battle` with the chit pre-selected in inventory
- "List for Sale" → opens price input bottom sheet

### Edge Functions

**chit-marketplace-list**
File: `supabase/functions/chit-marketplace-list/index.ts`

Request body: `{ chit_definition_id: string, quantity: number, price_per_unit_tokens: number }`

Logic:
1. Verify user has `quantity` of this chit available in `user_battle_chits`
2. Verify chit `can_buy_in_marketplace = TRUE` (only uncommon+ can be listed)
3. Reserve quantity (decrement from inventory; reverse if listing is cancelled)
4. INSERT into `chit_marketplace_listings`

**chit-marketplace-buy**
File: `supabase/functions/chit-marketplace-buy/index.ts`

Request body: `{ listing_id: string, quantity: number }`

Logic:
1. Verify listing is active and has sufficient quantity
2. Deduct `quantity × price_per_unit_tokens` from buyer's `token_balances`
3. Credit tokens to seller via `increment_token_balance`
4. INSERT into `user_battle_chits` (buyer) ON CONFLICT DO UPDATE quantity + N
5. Decrement `chit_marketplace_listings.quantity_listed`; if 0, set `status = 'sold'`
6. Log `token_transactions` for both buyer (chit_purchase) and seller (chit_sale)

---

## 3. Weekly Polls

### Migration 084 — Full SQL

File: `supabase/migrations/084_weekly_polls.sql`

```sql
-- Weekly polls: public voting on market makers.
-- Votes are weighted (registered users = 1.0, anonymous = 0.3).
-- Results drive stat sheet weekly_poll_multiplier on Monday rollover.

CREATE TABLE weekly_polls (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  week_start                  DATE NOT NULL UNIQUE,   -- Monday of poll week
  title                       TEXT NOT NULL,          -- e.g. "Who ruled this week?"
  description                 TEXT,
  status                      TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'open', 'closed', 'processed')),
  opens_at                    TIMESTAMPTZ NOT NULL,
  closes_at                   TIMESTAMPTZ NOT NULL,   -- Sunday 23:59 UTC
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE poll_options (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id                     UUID NOT NULL REFERENCES weekly_polls(id) ON DELETE CASCADE,
  creator_id                  UUID REFERENCES auth.users(id),  -- NULL for celebs with platform-managed profiles
  display_name                TEXT NOT NULL,
  image_url                   TEXT,
  archetype                   TEXT,
  -- Denormalized vote tallies (updated in real-time as votes come in)
  weighted_vote_total         DECIMAL(10,3) NOT NULL DEFAULT 0,
  raw_vote_count              INTEGER NOT NULL DEFAULT 0,  -- unweighted, for display
  current_rank                INTEGER,  -- recalculated after each batch of votes
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX poll_options_poll_idx ON poll_options (poll_id, weighted_vote_total DESC);

CREATE TABLE poll_votes (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id                     UUID NOT NULL REFERENCES weekly_polls(id),
  poll_option_id              UUID NOT NULL REFERENCES poll_options(id),

  -- Voter identity (one or both may be present)
  voter_user_id               UUID REFERENCES auth.users(id),  -- NULL if anonymous

  -- Anti-abuse fingerprinting fields
  ip_hash                     TEXT NOT NULL,          -- SHA-256 of IP address (never store raw IP)
  device_fingerprint          TEXT,                   -- client-side fingerprint hash
  user_agent_hash             TEXT,                   -- SHA-256 of User-Agent string

  -- Vote weight
  vote_weight                 DECIMAL(4,3) NOT NULL DEFAULT 0.300,
  -- 1.000 = registered user
  -- 0.300 = anonymous (reduces spam incentive while still counting for reach)

  -- Abuse detection
  is_flagged                  BOOLEAN NOT NULL DEFAULT FALSE,   -- quarantined votes
  flag_reason                 TEXT,

  voted_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Uniqueness constraints (prevent double-voting)
  UNIQUE (poll_id, voter_user_id)          -- one vote per registered user per poll
  -- ip_hash uniqueness is enforced at the edge function level with a rate limit,
  -- not as a DB constraint (IPs can be shared by households).
);

CREATE INDEX poll_votes_poll_idx        ON poll_votes (poll_id, is_flagged);
CREATE INDEX poll_votes_ip_idx          ON poll_votes (poll_id, ip_hash);
CREATE INDEX poll_votes_fingerprint_idx ON poll_votes (poll_id, device_fingerprint);

-- Poll results snapshot (written at poll close, before stat application)
CREATE TABLE poll_results (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id                     UUID NOT NULL REFERENCES weekly_polls(id),
  poll_option_id              UUID NOT NULL REFERENCES poll_options(id),
  creator_id                  UUID REFERENCES auth.users(id),
  final_rank                  INTEGER NOT NULL,           -- 1 = winner
  weighted_vote_total         DECIMAL(10,3) NOT NULL,
  raw_vote_count              INTEGER NOT NULL,
  stat_multiplier_applied     DECIMAL(4,3),               -- what multiplier was given
  processed_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (poll_id, poll_option_id)
);
```

### Poll Population Logic

Polls are created automatically every Monday via a pg_cron job.
The poll options are populated from all active market makers
(is_market_maker=TRUE, pending_opt_out=FALSE, is_test_account=FALSE/NULL).
Celebrities with platform-managed profiles are included automatically.

```sql
CREATE OR REPLACE FUNCTION create_weekly_poll()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_poll_id UUID;
  v_week_start DATE := DATE_TRUNC('week', NOW())::DATE;
BEGIN
  -- Idempotent: skip if this week's poll already exists
  IF EXISTS (SELECT 1 FROM weekly_polls WHERE week_start = v_week_start) THEN
    RETURN;
  END IF;

  INSERT INTO weekly_polls (week_start, title, description, status, opens_at, closes_at)
  VALUES (
    v_week_start,
    'Who ruled this week?',
    'Vote for the creator who made the biggest impact. Votes are public and open to everyone.',
    'open',
    NOW(),
    DATE_TRUNC('week', NOW()) + INTERVAL '6 days 23 hours 59 minutes'
  ) RETURNING id INTO v_poll_id;

  -- Add all active market makers as options
  INSERT INTO poll_options (poll_id, creator_id, display_name, image_url, archetype)
  SELECT
    v_poll_id,
    p.id,
    p.username,
    p.avatar_url,
    p.category
  FROM profiles p
  WHERE p.is_market_maker = TRUE
    AND p.pending_opt_out = FALSE
    AND (p.is_test_account IS NULL OR p.is_test_account = FALSE)
    AND p.is_approved = TRUE;

END;
$$;

-- Schedule: runs Monday 00:05 UTC (5 min after arena_monday_rollover)
SELECT cron.schedule(
  'create-weekly-poll',
  '5 0 * * 1',
  $$SELECT create_weekly_poll();$$
);

-- Schedule: close poll and snapshot results Sunday 23:59 UTC
SELECT cron.schedule(
  'close-weekly-poll',
  '59 23 * * 0',
  $$SELECT close_and_snapshot_poll();$$
);
```

```sql
CREATE OR REPLACE FUNCTION close_and_snapshot_poll()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_poll  weekly_polls%ROWTYPE;
  v_option RECORD;
  v_rank  INTEGER := 0;
BEGIN
  -- Find the currently open poll
  SELECT * INTO v_poll FROM weekly_polls WHERE status = 'open' ORDER BY closes_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN; END IF;

  UPDATE weekly_polls SET status = 'closed' WHERE id = v_poll.id;

  -- Rank options by weighted_vote_total and snapshot results
  FOR v_option IN
    SELECT po.*, ROW_NUMBER() OVER (ORDER BY po.weighted_vote_total DESC) AS rn
    FROM poll_options po
    WHERE po.poll_id = v_poll.id
  LOOP
    INSERT INTO poll_results (
      poll_id, poll_option_id, creator_id,
      final_rank, weighted_vote_total, raw_vote_count
    ) VALUES (
      v_poll.id, v_option.id, v_option.creator_id,
      v_option.rn, v_option.weighted_vote_total, v_option.raw_vote_count
    );

    -- Update poll_options.current_rank for display
    UPDATE poll_options SET current_rank = v_option.rn WHERE id = v_option.id;
  END LOOP;

  UPDATE weekly_polls SET status = 'processed' WHERE id = v_poll.id;
END;
$$;
```

### process_poll_results() — Stat Modifier Application

Called from `arena_monday_rollover()` (see doc2). Applies the multiplier to
`creator_stat_sheets` based on the poll results from the prior week.

```sql
CREATE OR REPLACE FUNCTION process_poll_results()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_result RECORD;
  v_multiplier DECIMAL(4,3);
BEGIN
  -- Get the most recently processed poll's results
  FOR v_result IN
    SELECT pr.*
    FROM poll_results pr
    JOIN weekly_polls wp ON wp.id = pr.poll_id
    WHERE wp.status = 'processed'
      AND wp.closes_at < NOW()
    ORDER BY wp.closes_at DESC, pr.final_rank ASC
    -- Only the most recent poll
    FETCH FIRST (SELECT COUNT(*) FROM poll_results WHERE poll_id = (
      SELECT id FROM weekly_polls WHERE status = 'processed' ORDER BY closes_at DESC LIMIT 1
    )) ROWS ONLY
  LOOP
    -- Determine multiplier based on rank
    v_multiplier := CASE
      WHEN v_result.final_rank = 1 THEN 1.150   -- +15% (1st place)
      WHEN v_result.final_rank = 2 THEN 1.100   -- +10%
      WHEN v_result.final_rank = 3 THEN 1.060   -- +6%
      WHEN v_result.final_rank <= 5 THEN 1.030  -- +3%
      WHEN v_result.final_rank <= 10 THEN 1.010 -- +1%
      ELSE 1.000                                 -- no change
    END;

    -- Skip if creator_id is null (platform-managed celeb without a stat sheet)
    CONTINUE WHEN v_result.creator_id IS NULL;

    -- Apply multiplier to creator_stat_sheets
    UPDATE creator_stat_sheets
    SET
      weekly_poll_rank       = v_result.final_rank,
      weekly_poll_multiplier = v_multiplier,
      effective_power        = ROUND(stat_power      * v_multiplier)::INTEGER,
      effective_charisma     = ROUND(stat_charisma   * v_multiplier)::INTEGER,
      effective_resilience   = ROUND(stat_resilience * v_multiplier)::INTEGER,
      effective_agility      = ROUND(stat_agility    * v_multiplier)::INTEGER,
      effective_wit          = ROUND(stat_wit        * v_multiplier)::INTEGER,
      effective_influence    = ROUND(stat_influence  * v_multiplier)::INTEGER,
      last_poll_applied_at   = NOW()
    WHERE user_id = v_result.creator_id;

    -- Update poll_results with the multiplier applied
    UPDATE poll_results
    SET stat_multiplier_applied = v_multiplier
    WHERE id = v_result.id;

    -- Log a zero-amount token transaction for the ledger trail
    INSERT INTO token_transactions (user_id, type, amount, reference_id, description)
    VALUES (
      v_result.creator_id,
      'poll_boost_applied',
      0,
      v_result.poll_id,
      'Weekly poll rank ' || v_result.final_rank || ' — stat multiplier ' || v_multiplier || 'x'
    );

  END LOOP;
END;
$$;
```

---

## 4. Poll Voting — Anti-Abuse System

### Edge Function: poll-vote

File: `supabase/functions/poll-vote/index.ts`

This is a **public endpoint** (no JWT required). Deploy with `--no-verify-jwt`.

```typescript
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { crypto } from 'https://deno.land/std@0.168.0/crypto/mod.ts';

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'authorization, content-type, x-fingerprint',
      },
    });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  );

  const body = await req.json();
  const { poll_id, poll_option_id, fingerprint } = body;

  if (!poll_id || !poll_option_id) {
    return new Response(JSON.stringify({ error: 'Missing required fields' }), { status: 400 });
  }

  // ── Verify poll is open ──
  const { data: poll } = await supabase
    .from('weekly_polls')
    .select('id, status, closes_at')
    .eq('id', poll_id)
    .single();

  if (!poll || poll.status !== 'open' || new Date(poll.closes_at) < new Date()) {
    return new Response(JSON.stringify({ error: 'Poll is not open' }), { status: 400 });
  }

  // ── Identity detection ──
  // Attempt to get auth user (optional — votes work without login)
  const authHeader = req.headers.get('Authorization');
  let voterUserId: string | null = null;
  let voteWeight = 0.3;  // anonymous default

  if (authHeader) {
    const token = authHeader.replace('Bearer ', '');
    const { data: { user } } = await supabase.auth.getUser(token);
    if (user) {
      voterUserId = user.id;
      voteWeight = 1.0;
    }
  }

  // ── Fingerprinting ──
  const rawIp = req.headers.get('x-forwarded-for')?.split(',')[0]?.trim()
    || req.headers.get('cf-connecting-ip')
    || 'unknown';

  const encoder = new TextEncoder();
  const ipHash = Array.from(new Uint8Array(
    await crypto.subtle.digest('SHA-256', encoder.encode(rawIp))
  )).map(b => b.toString(16).padStart(2, '0')).join('');

  const userAgent = req.headers.get('user-agent') || '';
  const userAgentHash = Array.from(new Uint8Array(
    await crypto.subtle.digest('SHA-256', encoder.encode(userAgent))
  )).map(b => b.toString(16).padStart(2, '0')).join('');

  const deviceFingerprint = fingerprint || null;  // client-provided, optional

  // ── Registered user: enforce one vote per poll ──
  if (voterUserId) {
    const { data: existing } = await supabase
      .from('poll_votes')
      .select('id')
      .eq('poll_id', poll_id)
      .eq('voter_user_id', voterUserId)
      .maybeSingle();

    if (existing) {
      return new Response(JSON.stringify({ error: 'Already voted in this poll' }), { status: 409 });
    }
  }

  // ── Anonymous: check IP rate limit (max 3 votes per IP per poll) ──
  if (!voterUserId) {
    const { count } = await supabase
      .from('poll_votes')
      .select('id', { count: 'exact', head: true })
      .eq('poll_id', poll_id)
      .eq('ip_hash', ipHash)
      .eq('is_flagged', false);

    if ((count ?? 0) >= 3) {
      // Silently accept but flag — don't reveal the limit to potential abusers
      await supabase.from('poll_votes').insert({
        poll_id, poll_option_id,
        voter_user_id: null,
        ip_hash: ipHash, device_fingerprint: deviceFingerprint, user_agent_hash: userAgentHash,
        vote_weight: 0.0,  // flagged votes carry zero weight
        is_flagged: true,
        flag_reason: 'ip_rate_limit',
      });
      // Return success to not reveal detection
      return new Response(JSON.stringify({ success: true, weight: 0 }), { status: 200 });
    }
  }

  // ── Fingerprint spike detection (device voting more than 5 times in poll) ──
  let isFlagged = false;
  let flagReason: string | null = null;

  if (deviceFingerprint) {
    const { count: fpCount } = await supabase
      .from('poll_votes')
      .select('id', { count: 'exact', head: true })
      .eq('poll_id', poll_id)
      .eq('device_fingerprint', deviceFingerprint)
      .eq('is_flagged', false);

    if ((fpCount ?? 0) >= 5) {
      isFlagged = true;
      flagReason = 'device_fingerprint_rate_limit';
      voteWeight = 0.0;
    }
  }

  // ── Insert vote ──
  const { error: insertError } = await supabase.from('poll_votes').insert({
    poll_id,
    poll_option_id,
    voter_user_id: voterUserId,
    ip_hash: ipHash,
    device_fingerprint: deviceFingerprint,
    user_agent_hash: userAgentHash,
    vote_weight: voteWeight,
    is_flagged: isFlagged,
    flag_reason: flagReason,
  });

  if (insertError) {
    // Unique constraint violation = duplicate registered user vote
    if (insertError.code === '23505') {
      return new Response(JSON.stringify({ error: 'Already voted' }), { status: 409 });
    }
    console.error('[poll-vote] insert error:', insertError);
    return new Response(JSON.stringify({ error: 'Vote failed' }), { status: 500 });
  }

  // ── Update poll_options running totals ──
  if (!isFlagged && voteWeight > 0) {
    await supabase.rpc('increment_poll_option_votes', {
      p_option_id: poll_option_id,
      p_weight: voteWeight,
    });
  }

  return new Response(JSON.stringify({ success: true, weight: voteWeight }), { status: 200 });
});
```

### DB Helper: increment_poll_option_votes

```sql
CREATE OR REPLACE FUNCTION increment_poll_option_votes(
  p_option_id UUID,
  p_weight DECIMAL(4,3)
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE poll_options
  SET
    weighted_vote_total = weighted_vote_total + p_weight,
    raw_vote_count      = raw_vote_count + 1
  WHERE id = p_option_id;
END;
$$;
```

---

## 5. Poll Flutter UI

### PollScreen

Route: `/poll/:pollId` — public (no auth required)

Contents:
- Poll title + time remaining countdown
- Ranked list of creators:
  - Character card thumbnail, username, archetype chip
  - Vote count bar (weighted total as percentage of total weighted votes)
  - Raw vote number displayed below bar (e.g., "2,847 votes")
  - Current rank badge (#1, #2, etc.)
- "Vote" button (one per creator row):
  - Registered users: tap once, UI locks that row (already voted)
  - Anonymous users: tap once, UI thanks them and shows share prompt
- Share strip below vote list:
  - Platform-style shareable image card (Flutter Screenshot widget)
  - Pre-filled share text: "I voted for [Name] this week on NORA! noraplatforms.com/poll/[id]"
  - Share to: X, Instagram Stories, WhatsApp, copy link

### PollEmbedScreen

Route: `/poll/:pollId/embed` — public, minimal chrome

A stripped-down version of PollScreen designed for embedding via `<iframe>` or
linking from social media. Contains only the voting widget (no header nav,
no footer, no sidebar). Width: 400px fixed. Height: auto.

### Client-Side Fingerprinting

In `lib/utils/device_fingerprint.dart`:
```dart
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'dart:html' as html;

Future<String> getDeviceFingerprint() async {
  // Combine browser signals into a fingerprint string
  final signals = [
    html.window.navigator.userAgent,
    html.window.navigator.language,
    html.window.screen?.width?.toString() ?? '',
    html.window.screen?.height?.toString() ?? '',
    DateTime.now().timeZoneOffset.inMinutes.toString(),
    html.window.screen?.colorDepth?.toString() ?? '',
  ].join('|');

  // Hash the signals — never send raw browser data to server
  final bytes = utf8.encode(signals);
  final digest = sha256.convert(bytes);
  return digest.toString();
}
```

Include the fingerprint hash in the poll-vote request body.
The server stores it but never logs it in plain text.

### Realtime Poll Updates

Subscribe to `poll_options` table via Supabase Realtime in `PollScreen`:
```dart
final _subscription = Supabase.instance.client
  .from('poll_options:poll_id=eq.$pollId')
  .stream(primaryKey: ['id'])
  .listen((data) {
    ref.invalidate(pollOptionsProvider(pollId));
  });
```

This gives live vote count updates as people vote — compelling for social sharing.

---

## 6. Poll Shareable Widget (Social Media)

### Design

The shareable widget is a Flutter `RepaintBoundary` captured as a PNG using
the `screenshot` package.

Widget contents:
- NORA logo (top left), "Who's Winning This Week?" headline
- Top 3 creators in ranked order with vote percentages
- QR code to `/poll/:pollId`
- Background: app theme gradient (#0A0A0F → #1A1A2E)
- Primary color accents (#6C63FF)

User flow:
1. User taps "Share Poll" on `PollScreen`
2. Widget renders offscreen via `ScreenshotController`
3. User selects target platform (X, Instagram, WhatsApp, copy)
4. For X: `twitter.com/intent/tweet?text=...&url=noraplatforms.com/poll/$pollId`
5. For Instagram: image copied to clipboard with prompt to paste in Stories
6. For WhatsApp: `wa.me/?text=...`

### Vercel OG Tags for /poll/:pollId

Add to the Vercel edge middleware (same pattern as the `compute-spotlight`
function, which already serves OG tags for the home page):

```typescript
// In vercel/middleware.ts, add a case for /poll paths:
if (pathname.startsWith('/poll/')) {
  const pollId = pathname.split('/')[2];
  const poll = await fetchPollData(pollId);  // Supabase REST call
  const leader = poll?.options?.[0];

  return new Response(
    `<!DOCTYPE html><html><head>
      <meta property="og:title" content="NORA Weekly Poll — ${poll?.title ?? 'Who ruled this week?'}" />
      <meta property="og:description" content="Current leader: ${leader?.display_name ?? '?'} with ${leader?.raw_vote_count ?? 0} votes. Vote now!" />
      <meta property="og:image" content="https://noraplatforms.com/og/poll/${pollId}" />
      <meta property="og:url" content="https://noraplatforms.com/poll/${pollId}" />
      <meta name="twitter:card" content="summary_large_image" />
    </head><body></body></html>`,
    { headers: { 'Content-Type': 'text/html' } }
  );
}
```

---

## 7. Celebrity Integration Steps

### One-Time Migration Setup

The 25 Hot Topic celebs need system `auth.users` entries and linked `profiles` rows.
This cannot be done in a plain SQL migration because Supabase's `auth.users` table
is managed by GoTrue and requires the service role API.

**Edge Function: celebrity-integration-seed**
File: `supabase/functions/celebrity-integration-seed/index.ts`
Deploy with `--no-verify-jwt` but gate behind a secret admin header.

```typescript
// Admin-only endpoint. Gate with:
const adminKey = req.headers.get('x-admin-key');
if (adminKey !== Deno.env.get('ADMIN_SEED_KEY')) {
  return new Response('Unauthorized', { status: 401 });
}

// For each celeb in the celebs table without is_integrated = TRUE:
// 1. Create a Supabase auth user with a fake email (celeb-{celeb_id}@managed.noraplatforms.com)
//    and a random password (never used — no login path for managed accounts).
// 2. The migration 086 DO block already handles the profiles INSERT using profile_id.
//    Update: in the edge function, create the auth user first, then trigger migration 086's
//    INSERT using the new user ID.
// 3. Mark celebs.is_integrated = TRUE.
```

Run this function **once** after deploying migration 086. Verify via:
```sql
SELECT COUNT(*) FROM celebs WHERE is_integrated = TRUE;
-- Should return 25
SELECT COUNT(*) FROM profiles WHERE is_celeb = TRUE;
-- Should return 25
```

### Celeb Stat Sheet Generation

After `celebrity-integration-seed` runs and all 25 celebs have `profiles` rows,
`calculate_stat_sheets()` will automatically include them on its next run
(the `celeb_raw` CTE in migration 079 handles this).

Verify:
```sql
SELECT p.username, css.stat_power, css.stat_charisma, css.stat_influence
FROM creator_stat_sheets css
JOIN profiles p ON p.id = css.user_id
WHERE p.is_celeb = TRUE
ORDER BY css.stat_influence DESC;
```

### Celeb Likeness Offerings (Platform-Managed)

The platform creates likeness offerings on behalf of celebs via a backend admin
interface (not a Flutter screen — use the Supabase dashboard or a simple admin edge function).

For each celeb offering:
- `creator_id` = the celeb's `profiles.id` (the system user)
- `mode = 'simulated'` until live mode is ready
- `managed_by_platform = TRUE` on the profile means no Stripe account is needed
- Revenue credited to `celebs.managed_wallet_usd_cents` instead of `token_balances`

---

## 8. Home Screen — Poll Winners Strip

In `lib/features/home/screens/home_screen.dart`, adjacent to the existing
Spotlight strips (Arena Champions + Top Movers), add a third strip:

**This Week's Poll Leaders**
- Source: `poll_options` WHERE `poll_id = [current open poll]`
  ORDER BY `weighted_vote_total DESC` LIMIT 5
- Display: horizontal scrollable strip, same style as Arena Champions
- Shows current rank (#1–#5), creator thumbnail, vote bar
- Tapping any creator card → `/poll/:pollId` (the full poll screen)
- If no open poll: hide the strip entirely

In `dualSpotlightProvider` (or create a new `pollLeadersProvider`):
```dart
final pollLeadersProvider = FutureProvider.autoDispose<List<PollOption>>((ref) async {
  // Get current open poll
  final poll = await Supabase.instance.client
    .from('weekly_polls')
    .select('id')
    .eq('status', 'open')
    .maybeSingle();

  if (poll == null) return [];

  final options = await Supabase.instance.client
    .from('poll_options')
    .select('*, profiles!creator_id(username, avatar_url)')
    .eq('poll_id', poll['id'])
    .order('weighted_vote_total', ascending: false)
    .limit(5);

  return (options as List).map((e) => PollOption.fromJson(e)).toList();
});
```

---

## 9. Stat Sheet Display on Public Profile

In `lib/features/profile/screens/public_profile_screen.dart`, below the existing
Heat Score badge and Display Score, add:

**Stat Sheet card**:
- Six hexagonal or bar-chart stats (Power, Charisma, Resilience, Agility, Wit, Influence)
- Each shows: icon, label, effective value (0–150), colored bar
- If `weekly_poll_rank` is set: show a banner "🏆 Ranked #N this week — #{multiplier}x stat boost"
- Card background: `surface` (#1A1A2E), primary accent (#6C63FF) for bars
- Below the stat card: "View Likeness Cards" button → `/marketplace?creator=$userId`

---

## 10. Updates to docs/infra.md

After completing this build, add the following to `docs/infra.md`:

### New Edge Functions
```
### Likeness & Marketplace
likeness-create-offering     — creator submits offering (auth required)
likeness-purchase-card       — mint card from offering (auth required)
likeness-list-card           — list owned card for sale (auth required)
likeness-buy-listed-card     — buy secondary listing (auth required)
celebrity-integration-seed   — one-time celeb seeder (admin only, secret key gated)
chit-marketplace-list        — list chit for sale (auth required)
chit-marketplace-buy         — buy chit from listing (auth required)

### Polls
poll-vote                    — cast a poll vote (no auth required — public endpoint)
```

### New pg_cron Jobs
```
create-weekly-poll     Monday 00:05 UTC   — creates the week's poll with all market makers
close-weekly-poll      Sunday 23:59 UTC   — closes poll, snapshots results
```

### New Routes
```
/marketplace              MarketplaceScreen (auth)
/marketplace/card/:cardId CardDetailScreen (auth)
/marketplace/offering/:id OfferingDetailScreen (auth)
/poll/:pollId             PollScreen (public)
/poll/:pollId/embed       PollEmbedScreen (public)
```

---

## 11. Milestone Checklist for Claude Code

Work through these in order. Do not skip a milestone.

### Milestone 1 — Schema
- [ ] Apply migrations 079–089 in sequence
- [ ] Verify zero migration errors in Supabase dashboard
- [ ] Run migration 086 DO block (or confirm edge function will handle it)
- [ ] `flutter analyze` — zero issues

### Milestone 2 — Stat Engine
- [ ] `calculate_stat_sheets()` runs without error
- [ ] All market maker profiles have a `creator_stat_sheets` row
- [ ] Integration at end of `sync-platform-metrics` edge function confirmed
- [ ] `creator_stat_history` receives snapshot rows
- [ ] Celeb stat sheets: verify 25 rows after `celebrity-integration-seed`

### Milestone 3 — Likeness System
- [ ] `likeness-create-offering` creates an offering row
- [ ] `likeness_mint_card` mints a card and writes transfer log
- [ ] Card marketplace listing and purchase work in sim mode
- [ ] `likeness_card_transfers` append-only (no UPDATEs on existing rows)
- [ ] `likeness_cards.current_owner_id` updates correctly via trigger

### Milestone 4 — Battle Format & Ownership
- [ ] `check_battle_eligibility` returns correct results for owner and self
- [ ] `get_eligible_characters` returns all owned cards + self
- [ ] `battle_create_lobby` accepts format param and character selections
- [ ] Stat snapshot applied to `battle_participants` at match start
- [ ] Modified damage formula active in `process_battle_turn`

### Milestone 5 — Arena↔Battle Link
- [ ] Arena market auto-created when `battle_start_match` fires
- [ ] `arena_matches.battle_match_id` is populated
- [ ] `resolve-markets` correctly branches on `resolution_type = 'battle_outcome'`
- [ ] `distribute_match_revenue` distributes all 5 pools without error
- [ ] Token transactions logged for all recipients

### Milestone 6 — Battle Chits
- [ ] `battle_chit_definitions` seeded with initial catalog
- [ ] `battle_use_chit` RPC applies effect to `arena_state.active_effects`
- [ ] RNG drop fires after winning match and credits `user_battle_chits`
- [ ] Chit marketplace listing and purchase work

### Milestone 7 — Polls
- [ ] `create_weekly_poll` creates poll + options (one per market maker)
- [ ] `poll-vote` edge function accepts anonymous votes
- [ ] IP rate limit (3 per poll) enforced silently
- [ ] Fingerprint rate limit (5 per poll) enforced
- [ ] Registered user 1.0 weight confirmed
- [ ] Anonymous user 0.3 weight confirmed
- [ ] `poll_options.weighted_vote_total` increments correctly
- [ ] `close_and_snapshot_poll` produces `poll_results` rows
- [ ] `process_poll_results` applies multipliers to `creator_stat_sheets`
- [ ] Monday rollover resets multipliers before applying new ones

### Milestone 8 — Flutter UI
- [ ] `MarketplaceScreen` renders two tabs with correct data
- [ ] `PollScreen` accessible without login at `/poll/:pollId`
- [ ] Share widget captures screenshot and generates share text
- [ ] `public_profile_screen.dart` shows stat sheet card
- [ ] Home screen shows poll leaders strip
- [ ] All new routes registered in GoRouter
- [ ] `flutter analyze` — zero issues
- [ ] `flutter build web` — no compile errors
