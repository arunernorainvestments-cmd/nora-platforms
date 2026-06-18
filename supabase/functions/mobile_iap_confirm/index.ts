// supabase/functions/mobile_iap_confirm/index.ts
//
// doc6 mobile IAP confirmation. The nora-arena app sells token packs and Battle
// Chit packs via RevenueCat (App Store + Google Play). After RevenueCat reports a
// successful purchase the app POSTs { product_id, purchase_token } here; this
// function credits the user's account against the SAME token_transactions ledger
// as web purchases (type 'purchased', reference_id = purchase_token).
//
// IDEMPOTENT: purchase_token is the PRIMARY KEY of mobile_iap_receipts. We claim
// that row first (ON CONFLICT DO NOTHING). A first claim credits; any replay/retry
// short-circuits and echoes the original grant — so a purchase can never
// double-credit (CLAUDE.md doc6 / migration 115).
//
// Auth: the caller's Supabase session JWT (same account as web). Deploy WITH jwt
// verification (default). Purchase authenticity:
//   - MOBILE_IAP_MODE=sim (default, pre-launch): trust the client report.
//   - MOBILE_IAP_MODE=live: validate the token against RevenueCat (requires
//     REVENUECAT_API_KEY) before crediting.
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

// ── Product catalog (doc6 §In-App Purchases) ────────────────────────────────
// Token packs grant a fixed number of tokens. Chit packs grant N chits of a
// rarity (random active definitions of that rarity, aggregated per definition).
const TOKEN_PACKS: Record<string, number> = {
  tokens_starter: 100,
  tokens_popular: 500,
  tokens_pro: 1200,
  tokens_elite: 2500,
};
const CHIT_PACKS: Record<string, { common: number; rare: number }> = {
  chit_pack_common: { common: 5, rare: 0 },
  chit_pack_rare: { common: 2, rare: 1 },
};

// Validate the purchase against RevenueCat in live mode. Returns ok:false (never
// throws) so a validation failure or rate-limit is treated as "do not credit".
async function validateWithRevenueCat(
  appUserId: string,
  productId: string,
  purchaseToken: string,
  apiKey: string,
): Promise<{ ok: boolean; reason?: string }> {
  let res: Response;
  try {
    res = await fetch(
      `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(appUserId)}`,
      { headers: { Authorization: `Bearer ${apiKey}` } },
    );
  } catch (e) {
    console.error('revenuecat fetch failed:', e);
    return { ok: false, reason: 'revenuecat_unreachable' };
  }
  // Hard Rule 8: handle 429 gracefully — log and skip, never throw / never credit.
  if (res.status === 429) {
    console.warn('revenuecat 429 — skipping credit for', appUserId, productId);
    return { ok: false, reason: 'rate_limited' };
  }
  if (!res.ok) {
    console.error('revenuecat status', res.status, 'for', appUserId);
    return { ok: false, reason: `revenuecat_${res.status}` };
  }
  const data = await res.json().catch(() => null);
  const ns = data?.subscriber?.non_subscriptions?.[productId];
  if (!Array.isArray(ns) || ns.length === 0) return { ok: false, reason: 'purchase_not_found' };
  const match = ns.some(
    (t: { id?: string; store_transaction_id?: string }) =>
      t?.id === purchaseToken || t?.store_transaction_id === purchaseToken,
  );
  return match ? { ok: true } : { ok: false, reason: 'token_mismatch' };
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return json({ error: 'Missing authorization header' }, 401);

    // ── Parse + validate input ────────────────────────────────────────────
    const body = await req.json().catch(() => null);
    const productId = typeof body?.product_id === 'string' ? body.product_id.trim() : '';
    const purchaseToken =
      typeof body?.purchase_token === 'string' ? body.purchase_token.trim() : '';
    const store = typeof body?.store === 'string' ? body.store.trim() : null;
    if (!productId || !purchaseToken) {
      return json({ error: 'product_id and purchase_token are required' }, 400);
    }
    const isTokenPack = productId in TOKEN_PACKS;
    const isChitPack = productId in CHIT_PACKS;
    if (!isTokenPack && !isChitPack) {
      return json({ error: `Unknown product_id: ${productId}` }, 400);
    }

    // ── Auth (session JWT scopes the caller) ──────────────────────────────
    const sessionClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user }, error: authError } = await sessionClient.auth.getUser();
    if (authError || !user) return json({ error: 'Unauthorized' }, 401);

    // ── Purchase authenticity (live mode validates with RevenueCat) ───────
    const mode = (Deno.env.get('MOBILE_IAP_MODE') ?? 'sim').toLowerCase();
    if (mode === 'live') {
      const rcKey = Deno.env.get('REVENUECAT_API_KEY');
      if (!rcKey) {
        console.error('MOBILE_IAP_MODE=live but REVENUECAT_API_KEY is unset');
        return json({ error: 'iap_validation_unconfigured' }, 500);
      }
      const v = await validateWithRevenueCat(user.id, productId, purchaseToken, rcKey);
      if (!v.ok) {
        const status = v.reason === 'rate_limited' ? 503 : 402;
        return json({ error: 'purchase_validation_failed', reason: v.reason }, status);
      }
    }

    // Service-role client: idempotency claim + balance/chit/ledger writes.
    const serviceClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    // ── Idempotency: claim the receipt FIRST (ON CONFLICT DO NOTHING) ─────
    const { data: claimed, error: claimErr } = await serviceClient
      .from('mobile_iap_receipts')
      .upsert(
        {
          purchase_token: purchaseToken,
          user_id: user.id,
          product_id: productId,
          store: store ?? (mode === 'live' ? null : 'sim'),
        },
        { onConflict: 'purchase_token', ignoreDuplicates: true },
      )
      .select('purchase_token');
    if (claimErr) {
      console.error('mobile_iap_confirm claim error:', JSON.stringify(claimErr));
      return json({ error: 'claim_failed' }, 500);
    }

    // Replay: receipt already existed → echo the recorded grant, do NOT re-credit.
    if (!claimed || claimed.length === 0) {
      const { data: existing } = await serviceClient
        .from('mobile_iap_receipts')
        .select('tokens_credited, chits_credited')
        .eq('purchase_token', purchaseToken)
        .maybeSingle();
      // Guard against cross-user token reuse.
      return json({
        status: 'already_processed',
        product_id: productId,
        tokens_credited: existing?.tokens_credited ?? 0,
        chits_credited: existing?.chits_credited ?? [],
      }, 200);
    }

    // ── First claim: apply the grant ──────────────────────────────────────
    let tokensCredited = 0;
    let chitsCredited: { chit_definition_id: string; name: string; quantity: number }[] = [];

    if (isTokenPack) {
      tokensCredited = TOKEN_PACKS[productId];
      const { error: creditErr } = await serviceClient.rpc('increment_token_balance', {
        p_user_id: user.id,
        p_amount: tokensCredited,
      });
      if (creditErr) {
        console.error('increment_token_balance error:', JSON.stringify(creditErr));
        return json({ error: 'token_credit_failed' }, 500);
      }
      // Same ledger as web purchases (stripe-webhook): type 'purchased'.
      const { error: txErr } = await serviceClient.from('token_transactions').insert({
        user_id: user.id,
        amount: tokensCredited,
        type: 'purchased',
        description: `Mobile IAP — ${productId} (${tokensCredited} tokens)`,
        reference_id: purchaseToken,
      });
      if (txErr) console.error('token_transactions insert error:', JSON.stringify(txErr));
    } else {
      // Chit pack: grant N random active chits per rarity, aggregated by definition.
      const want = CHIT_PACKS[productId];
      const grantByDef = new Map<string, { name: string; quantity: number }>();
      for (const [rarity, count] of [['common', want.common], ['rare', want.rare]] as const) {
        if (count <= 0) continue;
        const { data: defs } = await serviceClient
          .from('battle_chit_definitions')
          .select('id, name')
          .eq('rarity', rarity)
          .eq('is_active', true);
        if (!defs || defs.length === 0) {
          console.warn('no active chit definitions for rarity', rarity);
          continue;
        }
        for (let i = 0; i < count; i++) {
          const pick = defs[Math.floor(Math.random() * defs.length)];
          const cur = grantByDef.get(pick.id);
          if (cur) cur.quantity += 1;
          else grantByDef.set(pick.id, { name: pick.name, quantity: 1 });
        }
      }
      // Upsert each granted definition into the user's inventory (mirrors
      // chit-marketplace-buy: read-then-update/insert on the unique pair).
      for (const [defId, g] of grantByDef) {
        const { data: inv } = await serviceClient
          .from('user_battle_chits')
          .select('id, quantity')
          .eq('user_id', user.id)
          .eq('chit_definition_id', defId)
          .maybeSingle();
        if (inv) {
          await serviceClient
            .from('user_battle_chits')
            .update({ quantity: inv.quantity + g.quantity })
            .eq('id', inv.id);
        } else {
          await serviceClient.from('user_battle_chits').insert({
            user_id: user.id,
            chit_definition_id: defId,
            quantity: g.quantity,
            acquired_via: 'iap_purchase',
          });
        }
        chitsCredited.push({ chit_definition_id: defId, name: g.name, quantity: g.quantity });
      }
    }

    // Record what was credited on the receipt (for idempotent replays).
    await serviceClient
      .from('mobile_iap_receipts')
      .update({ tokens_credited: tokensCredited, chits_credited: chitsCredited })
      .eq('purchase_token', purchaseToken);

    return json({
      status: 'credited',
      product_id: productId,
      tokens_credited: tokensCredited,
      chits_credited: chitsCredited,
    }, 200);
  } catch (err) {
    console.error('mobile_iap_confirm error:', err);
    return json({ error: 'Internal server error' }, 500);
  }
});
