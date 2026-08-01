// supabase/functions/mint-reveal-compose/index.ts
// The mint-reveal share asset (Standard Playset spec S4.1 — the viral atom).
//
// "My post became a playable card" is the single shareable unit of this product, and the
// person sharing it brings their own audience. So the platform MANUFACTURES that unit at
// the end of every mint instead of hoping one appears: a 9:16 vertical MP4 composed from
// artifacts the mint pipeline already produced —
//
//     card art (slow push-in)  →  the cutscene  →  card art again (pull back)
//     … under a persistent NORA watermark + join link
//
// — stored in battle-media and attached to the chit as reveal_asset_url (mig 184).
//
// Costs nothing per card: no generation happens here. It is one stitch-worker pass over
// assets that already exist (REPO-CHECK S4.1 — no second compose service; the worker
// gained an optional `watermark` overlay instead).
//
// POST { chit_id }           — the caller must hold the card
//   → { ok, asset_url, share: { caption, join_url } }        (idempotent: an existing
//                                                             reveal is returned as-is
//                                                             unless force: true)
//
// Sim/degraded modes are honest, never fake: with no stitch worker configured the
// function returns ok:false with reason 'composer_unavailable' and the UI falls back to
// sharing the join link + card art. A reveal is a bonus on top of a finished mint — it
// must never be able to fail a mint.
//
// Deployed --no-verify-jwt (ES256 project); auth via supabase.auth.getUser().

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': 'https://noraplatforms.com',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

// 9:16 vertical — the primary format for TikTok / Reels / Shorts (spec §S3 channel plan).
const REVEAL_W = 1080;
const REVEAL_H = 1920;
const OPEN_S = 1.6;   // card art pushes in
const CLOSE_S = 2.2;  // card art holds while the watermark/join link reads
const FADE_S = 0.3;

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { status: 200, headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) return json({ error: 'Unauthorized' }, 401);
  const anon = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!);
  const { data: { user }, error: authError } = await anon.auth.getUser(authHeader.replace('Bearer ', ''));
  if (authError || !user) return json({ error: 'Unauthorized' }, 401);

  let body: { chit_id?: string; force?: boolean };
  try { body = await req.json(); } catch { return json({ error: 'Invalid JSON body' }, 400); }
  const chitId = body.chit_id?.trim();
  if (!chitId) return json({ error: 'Missing required field: chit_id' }, 400);

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  // ── the card + the holder check (the RPC owns both) ─────────────────────────────
  // Called on a request-scoped client so auth.uid() inside the RPC is the caller.
  const scoped = createClient(
    Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data: share, error: shareErr } = await scoped.rpc('mint_reveal_share_payload', {
    p_chit_id: chitId,
  });
  if (shareErr) return json({ error: 'not_your_card', detail: shareErr.message }, 403);
  const payload = share as Record<string, unknown> | null;

  if (payload?.ready === true && body.force !== true) {
    return json({
      ok: true,
      asset_url: payload.asset_url,
      reused: true,
      share: { caption: payload.caption, join_url: payload.join_url },
    });
  }

  const { data: chit, error: chitErr } = await db.from('moment_chits')
    .select('id, name, tier, card_art_url, mp4_cutscene_url')
    .eq('id', chitId).single();
  if (chitErr || !chit) return json({ error: 'chit_not_found' }, 404);
  if (!chit.card_art_url) {
    return json({ ok: false, reason: 'no_card_art', detail: 'The card has no art to compose from yet' }, 409);
  }

  const workerUrl = Deno.env.get('STITCH_WORKER_URL');
  const secret = Deno.env.get('STITCH_SECRET');
  if (!workerUrl || !secret) {
    // Honest degradation: the share sheet still works, it just shares the card + link.
    return json({
      ok: false,
      reason: 'composer_unavailable',
      share: { caption: payload?.caption, join_url: payload?.join_url, card_art: chit.card_art_url },
    }, 200);
  }

  // The watermark plate is a house asset (NORA mark + join QR), authored once and
  // reviewed like every other published artifact (anti-slop gate, spec §0.5).
  const { data: wm } = db.storage.from('battle-media').getPublicUrl('reveal/nora_reveal_watermark_v1.png');

  // card art → cutscene (when it exists) → card art. A mint with placeholder media
  // still composes: the reveal is then art-only, which is honest, not broken.
  const segments: Record<string, unknown>[] = [
    { image_url: chit.card_art_url, duration: OPEN_S, motion: 'push_in' },
    ...(chit.mp4_cutscene_url ? [{ url: chit.mp4_cutscene_url }] : []),
    { image_url: chit.card_art_url, duration: CLOSE_S, motion: 'pull_back' },
  ];

  const destPath = `reveals/${chitId}/reveal-${Date.now()}.mp4`;
  let res: Response;
  try {
    res = await fetch(`${workerUrl.replace(/\/$/, '')}/stitch`, {
      method: 'POST',
      headers: { 'X-Stitch-Secret': secret, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        segments,
        transition: { type: 'fadewhite', duration: FADE_S },
        // keep the cutscene's own soundtrack when there is one
        ...(chit.mp4_cutscene_url ? { audio_from_segment: 1 } : {}),
        watermark: {
          image_url: wm.publicUrl,
          position: 'bottom_center',
          scale: 0.34,
          opacity: 0.92,
        },
        width: REVEAL_W,
        height: REVEAL_H,
        upload: { bucket: 'battle-media', path: destPath },
      }),
    });
  } catch (e) {
    console.warn(`mint-reveal-compose: stitch call failed: ${(e as Error).message}`);
    return json({ ok: false, reason: 'composer_unavailable' }, 200);
  }
  if (!res.ok) {
    let detail = '';
    try { detail = (await res.text()).slice(0, 300); } catch { /* status only */ }
    console.warn(`mint-reveal-compose: stitch HTTP ${res.status}: ${detail}`);
    return json({ ok: false, reason: 'compose_failed', detail }, 200);
  }
  const out = await res.json().catch(() => ({}));
  if (out?.ok !== true) return json({ ok: false, reason: 'compose_failed' }, 200);

  const { data: pub } = db.storage.from('battle-media').getPublicUrl(destPath);
  const { error: attachErr } = await db.rpc('chit_set_reveal_asset', {
    p_chit_id: chitId, p_url: pub.publicUrl,
  });
  if (attachErr) {
    return json({ ok: false, reason: 'attach_failed', detail: attachErr.message }, 200);
  }

  return json({
    ok: true,
    asset_url: pub.publicUrl,
    reused: false,
    share: { caption: payload?.caption, join_url: payload?.join_url },
  });
});
