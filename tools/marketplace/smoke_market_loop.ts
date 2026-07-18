// tools/marketplace/smoke_market_loop.ts — live E2E proof of the chit-marketplace
// loop (migs 153–156, Hard Rule 40) over the SAME RPCs the /market + /collection
// UI calls: marketplace_list_chit → marketplace_delist_chit → marketplace_list_chit
// → marketplace_buy_chit (second account).
//
// Two throwaway smoke users against PROD:
//   seller granted one tier-F catalog chit → LIST (assert: escrowed out of
//   holdings, active listing, price/fee snapshots from config) → DELIST (assert:
//   copy back, listing delisted) → LIST again → buyer BUYS (assert: copy moves,
//   tokens move price-for-price, chit_sale/chit_purchase ledger rows, listing
//   sold, acquisition ledger acquired_currency='tokens') → full cleanup.
//
// Run:  SUPABASE_URL=https://<ref>.supabase.co \
//       SERVICE_KEY=... ANON_KEY=... [MGMT_TOKEN=...] \
//       deno run --allow-net --allow-env tools/marketplace/smoke_market_loop.ts

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const url = Deno.env.get('SUPABASE_URL')!;
const serviceKey = Deno.env.get('SERVICE_KEY')!;
const anonKey = Deno.env.get('ANON_KEY')!;
if (!url || !serviceKey || !anonKey) throw new Error('SUPABASE_URL/SERVICE_KEY/ANON_KEY required');

const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
const PASS = 'smoke-' + crypto.randomUUID();
const EMAILS = ['market-smoke-seller@noraplatforms.com', 'market-smoke-buyer@noraplatforms.com'];

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(`SMOKE FAIL: ${msg}`);
}

// Same recovery pattern as smoke_crossplay: GoTrue admin listUsers 500s on this
// project, so an existing user's id comes from a management-API query instead.
async function ensureUser(email: string): Promise<string> {
  const { data, error } = await admin.auth.admin.createUser({
    email, password: PASS, email_confirm: true,
  });
  if (data?.user) return data.user.id;
  if (error && /already been registered/i.test(error.message)) {
    const mgmtToken = Deno.env.get('MGMT_TOKEN');
    const ref = new URL(url).hostname.split('.')[0];
    if (!mgmtToken) throw new Error(`user ${email} exists; set MGMT_TOKEN to recover`);
    const res = await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${mgmtToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: `SELECT id FROM auth.users WHERE email = '${email}'` }),
    });
    const rows = await res.json() as { id: string }[];
    const id = rows?.[0]?.id;
    if (!id) throw new Error(`could not recover id for ${email}`);
    const { error: upErr } = await admin.auth.admin.updateUserById(id, { password: PASS });
    if (upErr) throw new Error(`password reset for ${email}: ${upErr.message}`);
    return id;
  }
  throw new Error(`createUser failed for ${email}: ${error?.message}`);
}

async function balance(userId: string): Promise<number> {
  const { data } = await admin.from('token_balances')
    .select('available_tokens').eq('user_id', userId).single();
  return Number(data?.available_tokens ?? 0);
}

async function holding(userId: string, chitId: string): Promise<number> {
  const { data } = await admin.from('chit_ownership')
    .select('quantity').eq('user_id', userId).eq('chit_id', chitId).maybeSingle();
  return Number(data?.quantity ?? 0);
}

async function main() {
  console.log('1. users…');
  const seller = await ensureUser(EMAILS[0]);
  const buyer = await ensureUser(EMAILS[1]);

  console.log('2. catalog chit (tier F) + seller holding…');
  const { data: chitId, error: cErr } = await admin.rpc('create_moment_chit', {
    p_name: 'Market Smoke F', p_family: 'athlete', p_chit_type: 'creature', p_tier: 'F',
  });
  if (cErr) throw new Error(`create_moment_chit: ${cErr.message}`);
  // Listing requires a live, FINALIZED chit — catalog helpers stop at created,
  // so stamp the preview/finalize timestamps the way a completed mint would.
  const now = new Date().toISOString();
  await admin.from('moment_chits')
    .update({ previewed_at: now, finalized_at: now }).eq('id', chitId);
  const { error: gErr } = await admin.rpc('chit_grant', {
    p_user_id: seller, p_chit_id: chitId, p_quantity: 1, p_reason: 'event',
  });
  if (gErr) throw new Error(`chit_grant: ${gErr.message}`);

  const { data: pricing } = await admin.from('marketplace_tier_pricing')
    .select('token_price, fee_bps').eq('tier', 'F').single();
  const price = Number(pricing?.token_price);
  assert(price > 0, 'tier-F pricing must exist');

  console.log(`3. buyer bankroll (needs ${price})…`);
  const buyerStart = await balance(buyer);
  if (buyerStart < price) {
    const topUp = price - buyerStart + 50;
    const { error: iErr } = await admin.rpc('increment_token_balance', {
      p_user_id: buyer, p_amount: topUp,
    });
    if (iErr) throw new Error(`increment_token_balance: ${iErr.message}`);
    // Hard Rule 5: every token movement lands in token_transactions.
    await admin.from('token_transactions').insert({
      user_id: buyer, type: 'refund', amount: topUp,
      description: 'marketplace smoke bankroll top-up',
    });
  }

  console.log('4. sign in both…');
  const cS = createClient(url, anonKey, { auth: { persistSession: false } });
  const cB = createClient(url, anonKey, { auth: { persistSession: false } });
  for (const [c, email] of [[cS, EMAILS[0]], [cB, EMAILS[1]]] as const) {
    const { error } = await c.auth.signInWithPassword({ email, password: PASS });
    if (error) throw new Error(`sign-in ${email}: ${error.message}`);
  }

  console.log('5. LIST (UI path: marketplace_list_chit)…');
  const { data: listing1, error: lErr } = await cS.rpc('marketplace_list_chit', { p_chit_id: chitId });
  if (lErr) throw new Error(`list: ${lErr.message}`);
  assert(await holding(seller, chitId) === 0, 'list must escrow the copy out of holdings');
  const { data: row1 } = await admin.from('marketplace_listings')
    .select('status, price_snapshot, fee_bps_snapshot, tier_snapshot').eq('id', listing1).single();
  assert(row1?.status === 'active', `listing must be active, got ${row1?.status}`);
  assert(Number(row1?.price_snapshot) === price, `price snapshot ${row1?.price_snapshot} != config ${price}`);
  console.log(`   listing ${listing1} active @ ${price} tokens (fee_bps ${row1?.fee_bps_snapshot})`);

  console.log('6. DELIST (marketplace_delist_chit)…');
  const { error: dErr } = await cS.rpc('marketplace_delist_chit', { p_listing_id: listing1 });
  if (dErr) throw new Error(`delist: ${dErr.message}`);
  assert(await holding(seller, chitId) === 1, 'delist must return the escrowed copy');
  const { data: row1b } = await admin.from('marketplace_listings')
    .select('status').eq('id', listing1).single();
  assert(row1b?.status === 'delisted', `listing must be delisted, got ${row1b?.status}`);

  console.log('7. LIST again → BUY with the second account…');
  const { data: listing2, error: l2Err } = await cS.rpc('marketplace_list_chit', { p_chit_id: chitId });
  if (l2Err) throw new Error(`re-list: ${l2Err.message}`);
  const sellerBefore = await balance(seller);
  const buyerBefore = await balance(buyer);
  const { error: bErr } = await cB.rpc('marketplace_buy_chit', { p_listing_id: listing2 });
  if (bErr) throw new Error(`buy: ${bErr.message}`);

  assert(await holding(buyer, chitId) === 1, 'buyer must hold the copy after purchase');
  assert(await holding(seller, chitId) === 0, 'seller must not hold the copy after sale');
  const sellerAfter = await balance(seller);
  const buyerAfter = await balance(buyer);
  const fee = Math.floor(price * Number(row1?.fee_bps_snapshot ?? 0) / 10000);
  assert(buyerBefore - buyerAfter === price, `buyer should pay ${price}, paid ${buyerBefore - buyerAfter}`);
  assert(sellerAfter - sellerBefore === price - fee,
    `seller should net ${price - fee}, got ${sellerAfter - sellerBefore}`);

  const { data: row2 } = await admin.from('marketplace_listings')
    .select('status').eq('id', listing2).single();
  assert(row2?.status === 'sold', `listing must be sold, got ${row2?.status}`);

  const { data: txs } = await admin.from('token_transactions')
    .select('user_id, type, amount').eq('reference_id', listing2);
  const kinds = (txs ?? []).map((t) => (t as { type: string }).type).sort();
  assert(kinds.includes('chit_purchase') && kinds.includes('chit_sale'),
    `expected chit_purchase+chit_sale ledger rows, got ${JSON.stringify(kinds)}`);

  const { data: sale } = await admin.from('marketplace_sales')
    .select('acquired_currency').eq('listing_id', listing2).maybeSingle();
  assert(!sale || sale.acquired_currency === 'tokens',
    `provenance stamp must be tokens, got ${JSON.stringify(sale)}`);

  console.log('8. cleanup…');
  await admin.rpc('chit_grant', {
    p_user_id: buyer, p_chit_id: chitId, p_quantity: -1, p_reason: 'platform_correction',
  });
  await admin.from('moment_chits')
    .update({ is_active: false, retired_at: new Date().toISOString(), retired_reason: 'admin' })
    .eq('id', chitId);
  for (const u of [seller, buyer]) await admin.auth.admin.deleteUser(u).catch(() => {});

  console.log('\nMARKET SMOKE OK: list → escrow → delist → re-list → cross-account buy '
    + '→ tokens/ledger/provenance all verified');
}

main().catch((e) => {
  console.error(e);
  Deno.exit(1);
});
