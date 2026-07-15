// dev-segmind-probe — TEMPORARY dev tooling (delete before launch, ARCHIVE §A8).
// Mode 1 (?id=): echo the raw Segmind v2 status/result payload for an async request.
//   With &store=1: on COMPLETED, download the output BYTES into the private
//   mint-staging bucket (v2v-trials/<request_id>.mp4) and return a short-lived
//   signed URL — the provider URL never escapes (Hard Rule 38 spirit).
// Mode 2 (?screen=<mp4 public url>&gen=<id>): replay the post-gen screening chain
// (stitch /frames → sign → live classifier) and echo each step's outcome.
// Mode 3 (POST JSON {v2v, moment_id, …}): the V2V provider MICRO-TRIAL (PLAN
// 2026-07-14 item 1c) — sign the moment's pre-gen-moderated mint-staging clip,
// assemble the house restyle prompt, submit to kling-o3 / runway-aleph via the v2
// queue, and return the request id for Mode-1 polling. Driven by
// tools/cinematic/trial_v2v.ts. PAID per submit.
// Auth: X-Probe-Secret must match the DEV_PROBE_SECRET edge secret.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { moderationConfigFromEnv, preGenModerate } from '../_shared/moderation.ts';
import {
  cinematicConfigFromEnv, pollCutscene, submitCutscene, submitV2VRestyle, v2vModelFor,
  type V2VProvider,
} from '../_shared/segmind.ts';
import { TIER_INTENSITY, v2vRestylePrompt } from '../_shared/cinematic_directives.ts';

Deno.serve(async (req: Request): Promise<Response> => {
  const probe = req.headers.get('X-Probe-Secret') ?? '';
  const expected = Deno.env.get('DEV_PROBE_SECRET') ?? '';
  if (!expected || probe !== expected) {
    return new Response('forbidden', { status: 403 });
  }
  const url = new URL(req.url);
  const id = url.searchParams.get('id');
  const screen = url.searchParams.get('screen');
  const gen = url.searchParams.get('gen') ?? 'probe';
  const store = url.searchParams.get('store') === '1';
  const json = (b: unknown, status = 200) =>
    new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });

  // ── Mode 3: V2V micro-trial submit ────────────────────────────────────────────
  if (req.method === 'POST') {
    let body: {
      v2v?: string; moment_id?: string; prompt_override?: string; subject_desc?: string;
      duration_s?: number; keep_audio?: boolean; aspect_ratio?: string;
      card_art_url?: string; tier?: 'fast' | 'standard';
      plate_motion?: string; first_frame_url?: string; last_frame_url?: string; seed?: number;
    };
    try { body = await req.json(); } catch { return json({ error: 'invalid JSON body' }, 400); }

    // ── Mode 4: ONE-TIME universal plate-motion generation (founder 2026-07-15) ──
    // Animates the house anchor plates into reusable intro/outro transition clips
    // (first/last-frame conditioned; only house-owned imagery reaches the provider,
    // so no clip-moderation gate applies). Result via Mode-1 ?id=&store=1. PAID.
    if (body.plate_motion) {
      if (!body.prompt_override?.trim() || !body.first_frame_url || !body.last_frame_url) {
        return json({ error: 'plate_motion needs prompt_override, first_frame_url, last_frame_url' }, 400);
      }
      const cfg = cinematicConfigFromEnv();
      const sub = await submitCutscene(cfg, {
        prompt: body.prompt_override.trim(),
        firstFrameUrl: body.first_frame_url,
        lastFrameUrl: body.last_frame_url,
        durationS: body.duration_s ?? 4,
        seed: body.seed ?? Math.floor(Math.random() * 2 ** 31),
        tierOverride: body.tier,
      });
      if (!sub.ok) return json({ error: sub.reason, detail: sub.detail }, 502);
      return json({
        ok: true, request_id: sub.requestId, model: sub.model,
        next: `GET ?id=${sub.requestId}&store=1 until done`,
      });
    }

    const provider = body.v2v as V2VProvider | undefined;
    if (provider !== 'kling-o3' && provider !== 'runway-aleph') {
      return json({ error: 'v2v must be kling-o3 or runway-aleph' }, 400);
    }
    if (!body.moment_id) return json({ error: 'moment_id required' }, 400);

    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: moment } = await db.from('moments').select('*').eq('id', body.moment_id).single();
    if (!moment) return json({ error: 'moment not found' }, 404);
    // Trials obey the same gate as minting: only a pre-gen-moderated attached clip
    // ever reaches a provider (Hard Rule 37 — the minor-safety screen is absolute).
    if (moment.clip_status !== 'attached' || !moment.raw_clip_path) {
      return json({ error: 'moment has no attached clip' }, 409);
    }
    if (moment.moderation_status !== 'approved') {
      return json({ error: 'moment is not moderation-approved' }, 409);
    }
    const { data: signedClip } = await db.storage.from('mint-staging')
      .createSignedUrl(moment.raw_clip_path as string, 3600);
    if (!signedClip?.signedUrl) return json({ error: 'could not sign clip url' }, 500);

    // Card-art reference: explicit override, else the moment's stored illustration.
    let cardArtUrl: string | null = body.card_art_url ?? null;
    if (!cardArtUrl) {
      const { data: entries } = await db.storage.from('battle-media')
        .list(`moments/${body.moment_id}`, { limit: 20 });
      if ((entries ?? []).some((e) => e.name === 'card_art.png')) {
        cardArtUrl = db.storage.from('battle-media')
          .getPublicUrl(`moments/${body.moment_id}/card_art.png`).data.publicUrl;
      }
    }

    const trimMs = Number(moment.clip_trim_end_ms ?? 0) - Number(moment.clip_trim_start_ms ?? 0);
    const prompt = body.prompt_override?.trim() || v2vRestylePrompt({
      subjectDesc: body.subject_desc ?? (moment.post_title as string | null)?.trim() ?? 'the subject of the clip',
      videoDesc: moment.clip_video_desc as string | null,
      tierIntensity: TIER_INTENSITY.C,
      provider,
      withCardArtRef: !!cardArtUrl,
    });

    const cfg = cinematicConfigFromEnv();
    const submit = await submitV2VRestyle(cfg, provider, {
      prompt,
      videoUrl: signedClip.signedUrl,
      referenceImageUrl: cardArtUrl ?? undefined,
      durationS: body.duration_s ?? Math.max(3, Math.round(trimMs / 1000)),
      keepAudio: body.keep_audio ?? (moment.clip_keep_audio as boolean | null) ?? true,
      aspectRatio: body.aspect_ratio,
      tierOverride: body.tier,
    });
    if (!submit.ok) {
      return json({ submitted: false, provider, prompt, ...submit }, 502);
    }
    return json({
      submitted: true, provider, model: submit.model, request_id: submit.requestId,
      seed: submit.seed, prompt, card_art_ref: cardArtUrl,
      keep_audio: provider === 'kling-o3' ? (body.keep_audio ?? moment.clip_keep_audio ?? true) : false,
      next: `poll ?id=${submit.requestId}, then ?id=${submit.requestId}&store=1 to keep the output`,
    });
  }

  if (screen) {
    const out: Record<string, unknown> = {};
    const workerUrl = Deno.env.get('STITCH_WORKER_URL');
    const secret = Deno.env.get('STITCH_SECRET');
    out.worker_configured = !!(workerUrl && secret);
    if (!workerUrl || !secret) return json(out);
    let fr: Response;
    try {
      fr = await fetch(`${workerUrl.replace(/\/$/, '')}/frames`, {
        method: 'POST',
        headers: { 'X-Stitch-Secret': secret, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          video_url: screen,
          // mirror cinematic-mint's screening sample positions (interior coverage)
          times: [0.4, '30%', '50%', '70%', 'last'],
          upload: { bucket: 'mint-staging', prefix: `postgen/${gen}` },
        }),
      });
    } catch (e) {
      out.frames_error = (e as Error).message;
      return json(out);
    }
    out.frames_http = fr.status;
    const frBody = await fr.text();
    out.frames_body = frBody.slice(0, 800);
    if (!fr.ok) return json(out);
    let framePaths: string[] = [];
    try {
      framePaths = ((JSON.parse(frBody).frames ?? []) as { path: string }[])
        .map((f) => String(f.path).replace(/^mint-staging\//, ''));
    } catch { out.frames_parse = 'failed'; return json(out); }
    out.frame_paths = framePaths;
    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const urls: string[] = [];
    for (const p of framePaths) {
      const { data: signed, error } = await db.storage.from('mint-staging').createSignedUrl(p, 600);
      if (signed?.signedUrl) urls.push(signed.signedUrl);
      else out[`sign_error_${p}`] = error?.message;
    }
    out.signed_count = urls.length;
    if (urls.length > 0) {
      const cfg = moderationConfigFromEnv();
      out.moderation_mode = cfg.mode;
      out.moderation_model = cfg.model;
      const verdict = await preGenModerate(cfg, { imageUrls: urls });
      out.verdict = verdict;
    }
    return json(out);
  }

  if (!id) return new Response('missing id or screen', { status: 400 });

  // &store=1 — resolve the async request through the shared client (bytes, never a
  // provider URL) and park the output in the private mint-staging bucket for review.
  if (store) {
    const cfg = cinematicConfigFromEnv();
    const poll = await pollCutscene(cfg, id, url.searchParams.get('model') ?? 'v2v-trial', 0);
    if (!poll.done) return json({ done: false, next: 'still rendering — poll again' });
    if (!poll.result.ok) return json({ done: true, ...poll.result });
    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const path = `v2v-trials/${id}.mp4`;
    const up = await db.storage.from('mint-staging').upload(path, poll.result.bytes, {
      contentType: poll.result.contentType, upsert: true,
    });
    if (up.error) return json({ done: true, ok: false, error: `store failed: ${up.error.message}` }, 500);
    const { data: signed } = await db.storage.from('mint-staging').createSignedUrl(path, 3600);
    return json({
      done: true, ok: true, stored_path: `mint-staging/${path}`,
      bytes: poll.result.bytes.length, content_type: poll.result.contentType,
      review_url: signed?.signedUrl ?? null,
    });
  }

  const key = Deno.env.get('SEGMIND_API_KEY') ?? '';
  const base = (Deno.env.get('SEGMIND_BASE_URL') ?? 'https://api.segmind.com/v1').replace(/\/v1\/?$/, '/v2');
  const st = await fetch(`${base}/requests/${id}/status`, { headers: { 'x-api-key': key } });
  const stBody = (await st.text()).slice(0, 1500);
  const res = await fetch(`${base}/requests/${id}`, { headers: { 'x-api-key': key } });
  const ct = res.headers.get('content-type') ?? '';
  const resBody = ct.includes('json') || ct.includes('text') ? (await res.text()).slice(0, 1500) : `[${ct}]`;
  return json({ status_http: st.status, status_body: stBody, result_http: res.status, result_ct: ct, result_body: resBody });
});
