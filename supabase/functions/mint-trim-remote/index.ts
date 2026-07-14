// supabase/functions/mint-trim-remote/index.ts
// Cloud fallback for the in-browser clip trimmer (Minting_Workflow.md §1B).
//
// ffmpeg.wasm OOMs on some device/file combos ("memory access out of bounds") —
// when that happens the wizard uploads the RAW picked file to the caller's
// mint-staging prefix and calls this instead. The stitch worker (real ffmpeg,
// no wasm memory wall) cuts + normalizes it and writes the SAME artifacts the
// browser path produces ({uid}/{momentId}/clip.mp4 + f0..f3.jpg), so
// moment-clip-attach — with all its re-moderation and similarity checks —
// runs unchanged afterwards. The raw source is deleted on success.
//
// POST { moment_id, trim_start_ms, trim_end_ms, keep_audio }
//   -> { ok, clip_path, frame_paths }   (paths relative to mint-staging)
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

const RAW_NAME = 'raw_source.mp4';   // the wizard's raw-upload object name

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { status: 200, headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) return json({ error: 'Unauthorized' }, 401);
  const anon = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!);
  const { data: { user }, error: authError } = await anon.auth.getUser(authHeader.replace('Bearer ', ''));
  if (authError || !user) return json({ error: 'Unauthorized' }, 401);

  let body: { moment_id?: string; trim_start_ms?: number; trim_end_ms?: number; keep_audio?: boolean };
  try { body = await req.json(); } catch { return json({ error: 'Invalid JSON body' }, 400); }
  const momentId = body.moment_id?.trim();
  const startMs = Math.floor(body.trim_start_ms ?? -1);
  const endMs = Math.floor(body.trim_end_ms ?? -1);
  if (!momentId) return json({ error: 'Missing required field: moment_id' }, 400);
  if (startMs < 0 || endMs - startMs < 1000 || endMs - startMs > 15000) {
    return json({ error: 'trim_window_out_of_bounds', detail: 'Clip selection must be 1–15 seconds' }, 400);
  }

  const workerUrl = Deno.env.get('STITCH_WORKER_URL');
  const secret = Deno.env.get('STITCH_SECRET');
  if (!workerUrl || !secret) return json({ error: 'trim_worker_unavailable' }, 503);

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  // Same ownership/state guards as the attach path (Hard Rule 37): the raw upload
  // is only ever processed tethered to the caller's own approved, unminted moment.
  const { data: moment } = await db.from('moments')
    .select('id, owner_user_id, moderation_status, mint_status')
    .eq('id', momentId).eq('owner_user_id', user.id).maybeSingle();
  if (!moment) return json({ error: 'moment_not_found' }, 404);
  if (moment.moderation_status !== 'approved') {
    return json({ error: 'moment_not_approved', detail: 'Run moment-ingest first' }, 409);
  }
  if (moment.mint_status === 'minted') return json({ error: 'already_minted' }, 409);

  // The raw object must exist under the CALLER's prefix (never an arbitrary path).
  const prefix = `${user.id}/${momentId}`;
  const { data: listing } = await db.storage.from('mint-staging').list(prefix, { limit: 100 });
  if (!listing?.some((e) => e.name === RAW_NAME)) {
    return json({ error: 'raw_upload_missing', detail: `Upload ${RAW_NAME} to your staging prefix first` }, 409);
  }

  // ── worker does the actual cut (writes clip.mp4 + f0..f3.jpg at the prefix) ──────
  let res: Response;
  try {
    res = await fetch(`${workerUrl.replace(/\/$/, '')}/trim`, {
      method: 'POST',
      headers: { 'X-Stitch-Secret': secret, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        source: { bucket: 'mint-staging', path: `${prefix}/${RAW_NAME}` },
        start_ms: startMs,
        end_ms: endMs,
        keep_audio: body.keep_audio !== false,
        upload: { bucket: 'mint-staging', prefix },
      }),
    });
  } catch (e) {
    return json({ error: 'trim_worker_unreachable', detail: (e as Error).message }, 502);
  }
  if (!res.ok) {
    const detail = (await res.text()).slice(0, 400);
    console.warn(`mint-trim-remote: worker trim failed HTTP ${res.status}: ${detail}`);
    return json({ error: 'trim_failed', detail }, 502);
  }
  const out = await res.json();

  // Raw source served its purpose — free the storage (best-effort).
  try { await db.storage.from('mint-staging').remove([`${prefix}/${RAW_NAME}`]); }
  catch { /* cleanup only */ }

  return json({
    ok: true,
    clip_path: out.clip_path,
    frame_paths: out.frame_paths,
  });
});
