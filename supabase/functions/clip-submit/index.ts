// clip-submit — the moderation-first submission path for Clip Campaigns
// (Collections spec N7, §1.6).
//
// Body: { campaign_id, submission_id?, frame_count?, note?, trim_start_ms?,
//         trim_end_ms?, sim_text? }   (sim_text honored in sim moderation only)
//
// Flow:
//   1. the caller uploaded clip.mp4 + f0..fN.jpg under {uid}/{campaign_id}/ in the
//      PRIVATE clip-staging bucket (owner-prefix storage RLS, mig 176);
//   2. this function creates the submission row (service role) — it lands in
//      'in_moderation', which is structurally invisible to the Market Maker;
//   3. pre-gen moderation runs on the sampled frames of the ACTUAL upload, using
//      the SAME shared module as the mint path (minor-safety absolute and first);
//   4. the verdict is recorded through clip_submission_moderate, which is
//      service-only — a client that could call it could self-approve its clip.
//
// A rejected clip is never visible to the Market Maker (RLS, mig 176), and the
// response never says WHICH category fired — same opacity rule as moment-ingest
// and moment-clip-attach.
//
// Hard Rules 37–39 are not weakened for campaign clips: the moderation stack is
// the mint stack, and an accepted clip only ever feeds a mint through the existing
// pipeline (moment_attach_clip), never from here.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { moderationConfigFromEnv, preGenModerate } from '../_shared/moderation.ts';

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

const DEFAULT_FRAME_COUNT = 4;

interface Body {
  campaign_id?: string;
  frame_count?: number;
  note?: string;
  trim_start_ms?: number;
  trim_end_ms?: number;
  sim_text?: string;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { status: 200, headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) return json({ error: 'Unauthorized' }, 401);
  const anon = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!);
  const { data: { user }, error: authError } =
    await anon.auth.getUser(authHeader.replace('Bearer ', ''));
  if (authError || !user) return json({ error: 'Unauthorized' }, 401);

  let body: Body;
  try { body = await req.json(); } catch { return json({ error: 'Invalid JSON body' }, 400); }
  const campaignId = body.campaign_id?.trim();
  if (!campaignId) return json({ error: 'Missing required field: campaign_id' }, 400);

  const frameCount = Math.min(Math.max(Math.floor(body.frame_count ?? DEFAULT_FRAME_COUNT), 1), 8);

  const db = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  // ── 1. the campaign must be open (the RPC re-checks, this is the early exit) ──
  const { data: campaign } = await db.from('clip_campaigns')
    .select('id, status, deadline, market_maker_user_id')
    .eq('id', campaignId).maybeSingle();
  if (!campaign) return json({ error: 'campaign_not_found' }, 404);
  if (campaign.status !== 'open') return json({ error: 'campaign_not_open' }, 409);
  if (new Date(campaign.deadline).getTime() <= Date.now()) {
    return json({ error: 'campaign_closed', detail: 'The deadline has passed' }, 409);
  }
  if (campaign.market_maker_user_id === user.id) {
    return json({ error: 'self_submission', detail: 'You cannot submit to your own campaign' }, 403);
  }

  // ── 2. the upload exists under the caller's own prefix ───────────────────────
  const prefix = `${user.id}/${campaignId}`;
  const clipPath = `${prefix}/clip.mp4`;
  const framePaths = Array.from({ length: frameCount }, (_, i) => `${prefix}/f${i}.jpg`);
  const { data: objects, error: listErr } = await db.storage.from('clip-staging').list(prefix);
  if (listErr) return json({ error: 'staging_list_failed', detail: listErr.message }, 500);
  const names = new Set((objects ?? []).map((o) => o.name));
  if (!names.has('clip.mp4')) {
    return json({
      error: 'upload_incomplete',
      detail: `Expected clip.mp4 under ${prefix}/`,
    }, 400);
  }
  const presentFrames = framePaths.filter((p) => names.has(p.split('/').pop()!));
  if (presentFrames.length === 0) {
    return json({
      error: 'upload_incomplete',
      detail: 'At least one sample frame (f0.jpg) is required for moderation',
    }, 400);
  }

  // ── 3. create the submission — lands in 'in_moderation', invisible to the MM ──
  const { data: submissionId, error: createErr } = await db.rpc(
    'clip_submission_create_internal',
    {
      p_user: user.id,
      p_campaign: campaignId,
      p_clip_path: clipPath,
      p_frame_paths: framePaths,
      p_trim_start_ms: body.trim_start_ms ?? null,
      p_trim_end_ms: body.trim_end_ms ?? null,
      p_note: body.note ?? null,
    },
  );
  if (createErr || !submissionId) {
    return json({ error: 'submission_failed', detail: createErr?.message }, 400);
  }

  // ── 4. moderation on the sampled frames of the actual upload ─────────────────
  const { data: signed, error: signErr } = await db.storage.from('clip-staging')
    .createSignedUrls(presentFrames, 600);
  if (signErr || !signed || signed.some((s) => !s.signedUrl)) {
    // Leave the submission in moderation rather than approving blind — fail closed.
    return json({ error: 'staging_sign_failed', detail: signErr?.message }, 500);
  }

  const modConfig = moderationConfigFromEnv();
  const verdict = await preGenModerate(modConfig, {
    imageUrls: signed.map((s) => s.signedUrl as string),
    textContext: modConfig.mode === 'sim' ? (body.sim_text ?? '') : '',
  });

  if (verdict.reason === 'rate_limited') {
    // Hard Rule 8: log and skip, never throw. The row stays in moderation
    // (invisible to the Market Maker) and can be re-run.
    console.warn('clip-submit: moderation rate-limited, leaving submission pending');
    return json({
      submission_id: submissionId,
      status: 'in_moderation',
      detail: 'Moderation is busy — your clip stays queued and will be reviewed shortly',
    }, 202);
  }

  const { error: modErr } = await db.rpc('clip_submission_moderate', {
    p_submission: submissionId,
    p_verdict: verdict.verdict,
    p_labels: verdict.labels,
    p_third_party: verdict.thirdPartyLikeness,
    p_model: verdict.model,
  });
  if (modErr) {
    console.error('clip-submit: recording the verdict failed', modErr.message);
    return json({ error: 'moderation_record_failed', detail: modErr.message }, 500);
  }

  if (verdict.verdict !== 'approved') {
    // Never expose which category fired.
    return json({
      submission_id: submissionId,
      status: 'rejected',
      detail: 'This clip did not pass content moderation and was not submitted',
    });
  }

  return json({
    submission_id: submissionId,
    status: 'approved',
    detail: 'Your clip passed moderation and is now with the Market Maker',
  });
});
