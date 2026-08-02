// supabase/functions/moment-clip-attach/index.ts
// Minting v2 (Minting_Workflow.md §1) — registers the device-uploaded, browser-trimmed
// clip against an ALREADY-APPROVED moment (moment-ingest ran first: ownership + source
// moderation). Hard Rule 37 as amended: the upload is tethered to the OAuth-verified
// post; this function is the tether's enforcement point.
//
// POST { moment_id, clip_path, frame_paths[4], trim_start_ms, trim_end_ms,
//        keep_audio, sim_text? }            (sim_text honored in sim moderation only)
//
// Gates, in order:
//   1. caller owns the moment and it is moderation-approved + not yet minted;
//   2. clip/frame objects exist in mint-staging under {uid}/{moment_id}/ (paths are
//      recomputed server-side from the ids — client-supplied paths are never trusted);
//   3. pre-gen moderation re-runs on the sampled frames of the ACTUAL upload
//      (minor-safety absolute: block the whole moment + escalate);
//   4. thumbnail-vs-frame similarity check (post-swap defense): the user picked an
//      owned post but could upload unrelated footage — a mismatch flags for human
//      review (moderation_escalations), it does not silently mint.
//
// MINT_CLIP_MODE=sim (default) skips the similarity check (no thumbnail in sim
// ingest); moderation is governed separately by MODERATION_MODE (shared module).
// Deployed --no-verify-jwt (ES256 project); auth via supabase.auth.getUser().

import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { moderationConfigFromEnv, preGenModerate } from '../_shared/moderation.ts';
import { clipDescribeConfigFromEnv, describeClipFrames } from '../_shared/cinematic_directives.ts';

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

const FRAME_COUNT = 4;
// dHash hamming distance (of 64 bits) above which the clip no longer plausibly
// matches the post thumbnail. Generous on purpose: thumbnails are often a styled
// cover frame, not a raw frame — this catches "different footage entirely".
const SIMILARITY_FLAG_DISTANCE = 28;

interface Body {
  moment_id?: string;
  trim_start_ms?: number;
  trim_end_ms?: number;
  keep_audio?: boolean;
  sim_text?: string;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { status: 200, headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) return json({ error: 'Unauthorized' }, 401);
  const anon = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!);
  const { data: { user }, error: authError } = await anon.auth.getUser(authHeader.replace('Bearer ', ''));
  if (authError || !user) return json({ error: 'Unauthorized' }, 401);

  let body: Body;
  try { body = await req.json(); } catch { return json({ error: 'Invalid JSON body' }, 400); }
  const momentId = body.moment_id?.trim();
  if (!momentId) return json({ error: 'Missing required field: moment_id' }, 400);
  const startMs = Math.floor(body.trim_start_ms ?? -1);
  const endMs = Math.floor(body.trim_end_ms ?? -1);
  if (startMs < 0 || endMs <= startMs) return json({ error: 'Invalid trim window' }, 400);
  if (endMs - startMs < 1000 || endMs - startMs > 15000) {
    return json({ error: 'trim_window_out_of_bounds', detail: 'Clip selection must be 1–15 seconds' }, 400);
  }

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  // ── 1. ownership + approval + not-yet-minted ──────────────────────────────────
  const { data: moment } = await db.from('moments')
    .select('id, owner_user_id, moderation_status, mint_status, thumbnail_url')
    .eq('id', momentId).eq('owner_user_id', user.id)
    .maybeSingle();
  if (!moment) return json({ error: 'moment_not_found' }, 404);
  if (moment.moderation_status !== 'approved') {
    return json({ error: 'moment_not_approved', detail: 'Run moment-ingest first' }, 409);
  }
  if (moment.mint_status === 'minted') {
    return json({ error: 'already_minted' }, 409);
  }

  // ── 2. storage objects exist under the owner's prefix (paths recomputed) ──────
  const prefix = `${user.id}/${momentId}`;
  const clipPath = `${prefix}/clip.mp4`;
  const framePaths = Array.from({ length: FRAME_COUNT }, (_, i) => `${prefix}/f${i}.jpg`);
  const { data: objects, error: listErr } = await db.storage.from('mint-staging').list(prefix);
  if (listErr) return json({ error: 'staging_list_failed', detail: listErr.message }, 500);
  const names = new Set((objects ?? []).map((o) => o.name));
  if (!names.has('clip.mp4') || framePaths.some((_, i) => !names.has(`f${i}.jpg`))) {
    return json({
      error: 'upload_incomplete',
      detail: `Expected clip.mp4 + f0..f${FRAME_COUNT - 1}.jpg under ${prefix}/`,
    }, 400);
  }

  // Short-lived signed URLs for the moderation/similarity readers (bucket is private).
  const { data: signed, error: signErr } = await db.storage.from('mint-staging')
    .createSignedUrls(framePaths, 600);
  if (signErr || !signed || signed.some((s) => !s.signedUrl)) {
    return json({ error: 'staging_sign_failed', detail: signErr?.message }, 500);
  }
  const frameUrls = signed.map((s) => s.signedUrl as string);

  // ── 3. pre-gen moderation on the actual upload (minor-safety absolute) ────────
  const modConfig = moderationConfigFromEnv();
  const verdict = await preGenModerate(modConfig, {
    imageUrls: frameUrls,
    textContext: modConfig.mode === 'sim' ? (body.sim_text ?? '') : '',
  });
  if (verdict.reason === 'rate_limited') {
    // Hard Rule 8: log and skip — nothing persisted, the user retries.
    console.warn('moment-clip-attach: moderation rate-limited, skipping');
    return json({ error: 'moderation_rate_limited', detail: 'Try again shortly' }, 429);
  }
  if (verdict.verdict !== 'approved') {
    // Record the rejected clip, and on a minor-safety escalation block the whole
    // moment through the mig-141 path (escalation row + rejected status).
    await db.rpc('moment_attach_clip', {
      p_moment_id: momentId, p_owner: user.id, p_clip_path: clipPath,
      p_frame_paths: framePaths, p_trim_start_ms: startMs, p_trim_end_ms: endMs,
      p_keep_audio: body.keep_audio ?? true, p_verdict: 'rejected', p_labels: verdict.labels,
    });
    if (verdict.verdict === 'escalated') {
      await db.rpc('moment_pre_gen_moderate', {
        p_moment_id: momentId, p_verdict: 'escalated', p_labels: verdict.labels,
        p_third_party: verdict.thirdPartyLikeness, p_model: verdict.model,
      });
    }
    // Same opacity rule as moment-ingest: never expose which categories fired.
    return json({
      moment_id: momentId, clip_status: 'rejected',
      detail: 'This clip did not pass content moderation and cannot be minted',
    });
  }

  // ── 4. thumbnail-vs-frame similarity (post-swap defense) ──────────────────────
  const clipMode = Deno.env.get('MINT_CLIP_MODE') === 'live' ? 'live' : 'sim';
  let similarity: { checked: boolean; distance: number | null } = { checked: false, distance: null };
  let attachVerdict: 'attached' | 'similarity_flagged' = 'attached';
  let labels: Record<string, unknown> | null = null;
  if (clipMode === 'live' && moment.thumbnail_url) {
    try {
      const distance = await bestFrameDistance(moment.thumbnail_url, frameUrls);
      similarity = { checked: true, distance };
      if (distance > SIMILARITY_FLAG_DISTANCE) {
        attachVerdict = 'similarity_flagged';
        labels = { clip_similarity_mismatch: true, distance };
      }
    } catch (err) {
      // Fail toward review, not toward silent acceptance.
      console.warn('moment-clip-attach: similarity check failed:', err);
      attachVerdict = 'similarity_flagged';
      labels = { clip_similarity_mismatch: true, check_error: true };
    }
  }

  const { error: attachErr } = await db.rpc('moment_attach_clip', {
    p_moment_id: momentId, p_owner: user.id, p_clip_path: clipPath,
    p_frame_paths: framePaths, p_trim_start_ms: startMs, p_trim_end_ms: endMs,
    p_keep_audio: body.keep_audio ?? true, p_verdict: attachVerdict, p_labels: labels,
  });
  if (attachErr) return json({ error: 'attach_failed', detail: attachErr.message }, 500);

  // ── 5. {VIDEO_DESC}: describe the clip for the V2V core (attached clips only) ──
  // Runs only AFTER moderation approved + attach succeeded (another CSAM checkpoint —
  // never described otherwise). Best-effort: a failure never blocks the mint. Reuses
  // the moderation mode/key/model. sim_text seeds the deterministic sim description.
  let videoDesc: string | null = null;
  if (attachVerdict === 'attached') {
    videoDesc = await describeClipFrames(clipDescribeConfigFromEnv(), frameUrls, body.sim_text);
    if (videoDesc) {
      const { error: descErr } = await db.rpc('moment_set_clip_video_desc', {
        p_moment_id: momentId, p_owner: user.id, p_desc: videoDesc,
      });
      if (descErr) { console.warn('moment-clip-attach: video_desc persist failed:', descErr.message); videoDesc = null; }
    }
  }

  return json({
    moment_id: momentId,
    clip_status: attachVerdict,
    clip_path: clipPath,
    video_desc: videoDesc,
    similarity,
    next: attachVerdict === 'attached'
      ? 'Clip staged — the generation pipeline (v2) picks it up from here'
      : 'Clip staged pending human review of the thumbnail mismatch',
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// dHash similarity — 9x8 luminance difference hash, hamming distance of 64 bits.
// ImageScript is dynamically imported so sim-mode cold starts never pay for it.
// ─────────────────────────────────────────────────────────────────────────────

async function bestFrameDistance(thumbnailUrl: string, frameUrls: string[]): Promise<number> {
  const thumbHash = await dHash(thumbnailUrl);
  let best = 64;
  for (const url of frameUrls) {
    const d = hamming(thumbHash, await dHash(url));
    if (d < best) best = d;
  }
  return best;
}

async function dHash(url: string): Promise<bigint> {
  const { Image } = await import('https://deno.land/x/imagescript@1.3.0/mod.ts');
  const res = await fetch(url);
  if (!res.ok) throw new Error(`image fetch ${res.status}`);
  const img = (await Image.decode(new Uint8Array(await res.arrayBuffer()))).resize(9, 8);
  const lum = (x: number, y: number): number => {
    const px = img.getPixelAt(x + 1, y + 1); // ImageScript is 1-indexed
    return 0.299 * ((px >> 24) & 0xff) + 0.587 * ((px >> 16) & 0xff) + 0.114 * ((px >> 8) & 0xff);
  };
  let hash = 0n;
  for (let y = 0; y < 8; y++) {
    for (let x = 0; x < 8; x++) {
      hash = (hash << 1n) | (lum(x, y) > lum(x + 1, y) ? 1n : 0n);
    }
  }
  return hash;
}

function hamming(a: bigint, b: bigint): number {
  let x = a ^ b;
  let count = 0;
  while (x > 0n) { count += Number(x & 1n); x >>= 1n; }
  return count;
}
