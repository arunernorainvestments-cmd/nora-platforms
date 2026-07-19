// supabase/functions/lkn-verify/index.ts
//
// Public Right-of-Publicity license verification API.
// Endpoint (via gateway rewrite): GET https://api.noraplatforms.com/v1/verify
// Deploy with --no-verify-jwt. Auth is the X-NORA-API-Key header, NOT a Supabase JWT.
//
// Query params (one of license_id OR licensee_nora_id required):
//   license_id         — verify a single agreement (returns one record)
//   licensee_nora_id   — list a user's active licenses (doc6 License Sync uses this)
//   licensor_nora_id   — optional filter (with licensee_nora_id)
//   use_category       — intended use; sets use_category_permitted against the terms
//
// Hard Rules honored:
//  - API key validated + rate-limited BEFORE any license data is read (Rule 31).
//  - Verification reads terms_snapshot on the agreement, never the live template.
//  - Signing key lives only in Vault as NORA_SIGNING_PRIVATE_KEY (Rule 32);
//    never logged, never returned.
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-nora-api-key, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

// use_category (API string) → terms_snapshot purpose_* field
const USE_CATEGORY_TO_PURPOSE: Record<string, string> = {
  ai_generated_content: 'purpose_ai_generated_content',
  ai_voice_cloning: 'purpose_ai_voice_cloning',
  ai_image_generation: 'purpose_ai_image_generation',
  ai_model_training: 'purpose_ai_model_training',
  commercial_advertising: 'purpose_commercial_advertising',
  entertainment_film: 'purpose_entertainment_film',
  entertainment_tv: 'purpose_entertainment_tv',
  entertainment_game: 'purpose_entertainment_game',
  music: 'purpose_music',
  social_media: 'purpose_social_media',
  merchandise: 'purpose_merchandise',
  nft_digital_asset: 'purpose_nft_digital_asset',
  editorial_news: 'purpose_editorial_news',
};

// deno-lint-ignore no-explicit-any
function restrictionsFromTerms(t: any) {
  return {
    profanity_allowed: !t.restrict_profanity,
    adult_content_allowed: !t.restrict_adult_content,
    political_content_allowed: !t.restrict_political_content,
    ai_voice_allowed: !!t.purpose_ai_voice_cloning,
    ai_image_allowed: !!t.purpose_ai_image_generation,
    ai_model_training_allowed: !!t.purpose_ai_model_training,
    ai_generated_must_be_labeled: !!t.ai_generated_must_be_labeled,
    sublicensing_allowed: !!t.sublicensing_allowed,
    restricted_topics: t.restricted_topics ?? [],
  };
}

// deno-lint-ignore no-explicit-any
function usePermitted(t: any, status: string, useCategory: string | null): boolean {
  if (status !== 'active') return false;
  if (!useCategory) return true;
  const field = USE_CATEGORY_TO_PURPOSE[useCategory];
  if (!field) return false; // unknown category → conservatively not permitted
  return !!t[field];
}

// ── ECDSA P-256 signing (graceful if key absent) ─────────────────────────────
let cachedKey: CryptoKey | null = null;
function pemToDer(pem: string): Uint8Array<ArrayBuffer> {
  const b64 = pem.replace(/-----BEGIN [^-]+-----/, '')
    .replace(/-----END [^-]+-----/, '')
    .replace(/\s+/g, '');
  const bin = atob(b64);
  const der = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) der[i] = bin.charCodeAt(i);
  return der;
}
async function getSigningKey(): Promise<CryptoKey | null> {
  if (cachedKey) return cachedKey;
  const pem = Deno.env.get('NORA_SIGNING_PRIVATE_KEY');
  if (!pem) return null;
  try {
    cachedKey = await crypto.subtle.importKey(
      'pkcs8', pemToDer(pem),
      { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'],
    );
    return cachedKey;
  } catch (e) {
    console.error('lkn-verify: failed to import signing key:', e);
    return null;
  }
}
async function signPayload(payload: object): Promise<{ hash: string; signature: string | null }> {
  const bytes = new TextEncoder().encode(JSON.stringify(payload));
  const hashBuf = await crypto.subtle.digest('SHA-256', bytes);
  const hash = 'sha256:' + Array.from(new Uint8Array(hashBuf))
    .map((b) => b.toString(16).padStart(2, '0')).join('');
  const key = await getSigningKey();
  if (!key) return { hash, signature: null };
  const sigBuf = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, bytes);
  const sig = btoa(String.fromCharCode(...new Uint8Array(sigBuf)));
  return { hash, signature: sig };
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'GET') return json({ error: 'Method not allowed' }, 405);

  const startedAt = Date.now();
  const service = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  // ── 1. API key validation (before any license read) ──
  const apiKey = req.headers.get('X-NORA-API-Key');
  if (!apiKey) return json({ error: 'missing_api_key' }, 401);

  const { data: keyRow } = await service
    .from('lkn_api_keys')
    .select('id, daily_call_limit, calls_today, calls_total, last_reset_date, is_active')
    .eq('api_key', apiKey)
    .eq('is_active', true)
    .maybeSingle();
  if (!keyRow) return json({ error: 'invalid_api_key' }, 401);

  // ── 2. Rate limit (inline daily roll-over; cron also resets) ──
  const today = new Date().toISOString().slice(0, 10);
  const rolledOver = (keyRow.last_reset_date as string) < today;
  const usedToday = rolledOver ? 0 : (keyRow.calls_today as number);
  if (usedToday >= (keyRow.daily_call_limit as number)) {
    await service.from('lkn_api_call_log').insert({
      api_key_id: keyRow.id, response_status: 'rate_limited',
      response_time_ms: Date.now() - startedAt,
    });
    return json({
      error: 'rate_limit_exceeded',
      daily_limit: keyRow.daily_call_limit,
      resets_at: today + 'T00:00:00Z',
    }, 429);
  }
  // NOTE: read-check-increment is non-atomic; minor overage possible under
  // heavy concurrency. Acceptable for the free tier; revisit with an RPC if billed.
  await service.from('lkn_api_keys').update({
    calls_today: usedToday + 1,
    calls_total: (keyRow.calls_total as number) + 1,
    last_reset_date: today,
  }).eq('id', keyRow.id);

  const url = new URL(req.url);
  const licenseId = url.searchParams.get('license_id');
  const licenseeId = url.searchParams.get('licensee_nora_id');
  const licensorId = url.searchParams.get('licensor_nora_id');
  const useCategory = url.searchParams.get('use_category');

  async function logCall(status: string, lid: string | null) {
    await service.from('lkn_api_call_log').insert({
      api_key_id: keyRow!.id,
      license_id: lid,
      licensor_nora_id: licensorId,
      licensee_nora_id: licenseeId,
      use_category: useCategory,
      response_status: status,
      response_time_ms: Date.now() - startedAt,
    });
  }

  try {
    // ── Mode A: list a user's active licenses (doc6 License Sync) ──
    if (!licenseId && licenseeId) {
      let q = service.from('lkn_agreements')
        .select('license_id, status, listing_id, licensor_user_id, licensee_user_id, effective_date, expiration_date, terms_snapshot')
        .eq('licensee_user_id', licenseeId)
        .eq('status', 'active');
      if (licensorId) q = q.eq('licensor_user_id', licensorId);
      const { data: rows, error } = await q;
      if (error) { console.error('lkn-verify list error:', JSON.stringify(error)); await logCall('error', null); return json({ error: 'lookup_failed' }, 500); }

      const list = (rows ?? []).map((r) => {
        const t = r.terms_snapshot ?? {};
        return {
          license_id: r.license_id,
          license_status: r.status,
          listing_id: r.listing_id,
          licensor: { nora_id: r.licensor_user_id },
          licensee: { nora_id: r.licensee_user_id },
          effective_date: r.effective_date,
          expiration_date: r.expiration_date,
          territory: t.territory ?? 'worldwide',
          use_category_permitted: usePermitted(t, r.status, useCategory),
          restrictions: restrictionsFromTerms(t),
          nora_source_url: `https://noraplatforms.com/license/${r.license_id}`,
        };
      });
      await logCall(list.length ? 'valid' : 'not_found', null);
      return json(list, 200);
    }

    // ── Mode B: verify a single license ──
    if (!licenseId) {
      await logCall('error', null);
      return json({ error: 'license_id or licensee_nora_id required' }, 400);
    }

    const { data: ag } = await service
      .from('lkn_agreements')
      .select('license_id, status, listing_id, licensor_user_id, licensee_user_id, effective_date, expiration_date, terms_snapshot, record_hash')
      .eq('license_id', licenseId)
      .maybeSingle();

    if (!ag) {
      await logCall('not_found', licenseId);
      return json({
        license_status: 'not_found',
        use_category_permitted: false,
        verified_at: new Date().toISOString(),
      }, 200);
    }

    // Expiry check (status may still say 'active' before the expiry cron runs)
    let status = ag.status as string;
    if (status === 'active' && ag.expiration_date && new Date(ag.expiration_date as string) < new Date()) {
      status = 'expired';
    }

    const t = ag.terms_snapshot ?? {};
    const { data: licensorProfile } = await service
      .from('profiles')
      .select('lkn_licensor_status, lkn_licensor_tier')
      .eq('id', ag.licensor_user_id)
      .maybeSingle();
    const { data: listing } = await service
      .from('lkn_listings')
      .select('licensor_display_name')
      .eq('id', ag.listing_id)
      .maybeSingle();

    const corePayload = {
      license_id: ag.license_id,
      license_status: status,
      licensor: {
        nora_id: ag.licensor_user_id,
        display_name: listing?.licensor_display_name ?? null,
        verified: licensorProfile?.lkn_licensor_status === 'verified',
        verification_tier: licensorProfile?.lkn_licensor_tier ?? null,
      },
      licensee: { nora_id: ag.licensee_user_id },
      effective_date: ag.effective_date,
      expiration_date: ag.expiration_date,
      territory: t.territory ?? 'worldwide',
      use_category_permitted: usePermitted(t, status, useCategory),
      restrictions: restrictionsFromTerms(t),
      nora_source_url: `https://noraplatforms.com/license/${ag.license_id}`,
    };

    const { hash, signature } = await signPayload(corePayload);
    await logCall(status === 'active' ? 'valid' : (status === 'expired' ? 'expired' : 'invalid'), licenseId);

    return json({
      ...corePayload,
      record_hash: hash,
      signature,
      public_key_url: 'https://noraplatforms.com/.well-known/nora-public-key.pem',
      verified_at: new Date().toISOString(),
    }, 200);
  } catch (err) {
    console.error('lkn-verify error:', err);
    await logCall('error', licenseId);
    return json({ error: 'Internal server error' }, 500);
  }
});
