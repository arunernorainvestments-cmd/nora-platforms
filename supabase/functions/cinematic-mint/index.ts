// supabase/functions/cinematic-mint/index.ts
// C2 — the cinematic minting pipeline (cinematic spec §3 steps 2–7).
//
// POST { moment_id, family, chit_type, subject_desc, timing_type?, effect_template_id?,
//        name?, keywords?, vibe_gate?, rerun_of_generation_id? }
//
// Orchestrates: pre-gen-moderated moment → template select (role) → illustration →
// Seedance cutscene bracketed by the template's anchor plates (fixed seed) → post-gen
// moderation → store in battle-media → cinematic_complete_mint (chit inactive until
// the user previews + finalizes). All DB invariants re-checked server-side (mig 140).
// Deployed --no-verify-jwt (ES256 project); auth via supabase.auth.getUser().

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { cinematicConfigFromEnv, generateCutscene, generateIllustration } from '../_shared/segmind.ts';
import {
  assembleMotionPrompt, familyAction, illustrationPrompt, sanitizeSubjectDesc,
  selectTemplate, TIER_INTENSITY, type Family, type Tier,
} from '../_shared/cinematic_directives.ts';
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

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { status: 200, headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) return json({ error: 'Unauthorized' }, 401);
  const anon = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!);
  const { data: { user }, error: authError } = await anon.auth.getUser(authHeader.replace('Bearer ', ''));
  if (authError || !user) return json({ error: 'Unauthorized' }, 401);

  let body: {
    moment_id?: string; family?: Family; chit_type?: 'creature' | 'spell_moment';
    subject_desc?: string; timing_type?: string; effect_template_id?: string;
    name?: string; keywords?: string[]; vibe_gate?: number; rerun_of_generation_id?: string;
    swap_of_chit_id?: string; swap_confirm?: boolean;
  };
  try { body = await req.json(); } catch { return json({ error: 'Invalid JSON body' }, 400); }
  const { moment_id, family, chit_type, subject_desc } = body;
  if (!moment_id || !family || !chit_type || !subject_desc?.trim()) {
    return json({ error: 'Missing required fields: moment_id, family, chit_type, subject_desc' }, 400);
  }

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const cfg = cinematicConfigFromEnv();

  // ── the moment must be caller-owned, consented, pre-gen moderated, unminted ──────
  const { data: moment, error: mErr } = await db.from('moments').select('*').eq('id', moment_id).single();
  if (mErr || !moment) return json({ error: 'Moment not found' }, 404);
  if (moment.owner_user_id !== user.id) return json({ error: 'Not your moment' }, 403);
  if (!moment.consent_granted_at) return json({ error: 'No consent on moment' }, 409);
  if (moment.moderation_status !== 'approved') {
    return json({ error: 'Moment has not passed pre-generation moderation' }, 409);
  }
  if (moment.minted_chit_id) return json({ error: 'Moment already minted' }, 409);

  // ── spend guards (BEFORE any generation — each mint is paid provider calls) ───────
  // Guard 1: a generation for this moment already awaits a moderation verdict →
  // RESUME it (re-screen the stored media + complete) instead of generating again.
  // Without this, every re-click while a verdict is pending would burn another paid
  // illustration + cutscene; the resume path costs no provider calls at all.
  // Also resumes 'moderation_approved' rows whose completion failed/never ran (e.g.
  // a manual verdict applied after a screening outage) — straight to complete.
  const { data: pendingGens } = await db.from('cinematic_generations')
    .select('*').eq('moment_id', moment_id)
    .in('status', ['generated', 'moderation_approved'])
    .order('created_at', { ascending: false }).limit(1);
  const resumeGen = !body.rerun_of_generation_id && pendingGens?.[0] ? pendingGens[0] : null;

  // Guard 2: per-user daily generation cap (bug loops, multi-tab spam, abuse).
  // A resume makes no provider calls, so it does not consume the allowance.
  if (!resumeGen) {
    const dailyCap = Math.max(1, Number(Deno.env.get('CINEMATIC_DAILY_CAP') ?? '6'));
    const { count: dayCount } = await db.from('cinematic_generations')
      .select('id, moments!inner(owner_user_id)', { count: 'exact', head: true })
      .eq('moments.owner_user_id', user.id)
      .gte('created_at', new Date(Date.now() - 24 * 3600 * 1000).toISOString());
    if ((dayCount ?? 0) >= dailyCap) {
      console.warn(`cinematic-mint: daily cap hit for user ${user.id} (${dayCount}/${dailyCap})`);
      return json({
        error: 'generation_limit',
        detail: `Daily card-generation limit reached (${dailyCap}). Try again tomorrow.`,
      }, 429);
    }
  }

  // ── one active self-minted chit (minting spec P4) — fail fast, before generation ──
  // Occupied slot: the client must re-call with the explicit swap confirmation. The
  // old chit is retired IN THE SAME TX as the new mint (mig 142) — never before the
  // new mint confirms; its media is deleted below only after that tx succeeds.
  const { data: slotChit } = await db.rpc('self_mint_slot', { p_user: user.id });
  if (slotChit && (!body.swap_confirm || body.swap_of_chit_id !== slotChit)) {
    return json({
      error: 'self_mint_slot_occupied',
      occupied_chit_id: slotChit,
      warning: 'You already have a self-minted card. Minting a new one permanently ' +
        'deletes the current card and its cutscene media. To proceed, re-call with ' +
        'swap_of_chit_id set to the occupied chit and swap_confirm: true.',
    }, 409);
  }
  const swapOf: string | null = slotChit && body.swap_confirm ? slotChit : null;
  let oldMomentId: string | null = null;
  if (swapOf) {
    const { data: oldChit } = await db.from('moment_chits').select('moment_id').eq('id', swapOf).single();
    oldMomentId = oldChit?.moment_id ?? null;
  }

  // ── tier (engagement-derived — Hard Rule 34) + template selection ────────────────
  const { data: tier, error: tErr } = await db.rpc('tier_for_engagement', { p_engagement: moment.engagement_count });
  if (tErr || !tier) return json({ error: 'Tier derivation failed', detail: tErr?.message }, 500);

  // The effect is the one moment-classify selected + persisted on the moment (Hard Rule 34 —
  // never client-supplied). Read it (+ the keywords it stamps) here; the client body's effect
  // fields are ignored.
  const effectTemplateId: string | null = moment.selected_effect_template_id ?? null;
  const effectTiming: string | null = moment.selected_timing ?? null;
  let effectKind: string | null = null, target: string | null = null;
  let grantKeywords: string[] = [];
  if (effectTemplateId) {
    const { data: eff } = await db.from('effect_templates')
      .select('effect_kind,target,grants_keywords').eq('id', effectTemplateId).single();
    effectKind = eff?.effect_kind ?? null;
    target = eff?.target ?? null;
    grantKeywords = (eff?.grants_keywords as string[] | null) ?? [];
  }
  const templateId = selectTemplate({
    chitType: chit_type, tier: tier as Tier, timing: effectTiming ?? undefined, effectKind, target,
  });

  // ── plates + prompt (latest versions; live requires signed-off plates) ───────────
  let plateQuery = db.from('match_cut_anchor_plates').select('*')
    .eq('template_id', templateId).order('version', { ascending: false }).limit(1);
  if (cfg.mode === 'live') plateQuery = plateQuery.eq('status', 'signed_off');
  const { data: plates } = await plateQuery;
  const plate = plates?.[0];
  if (!plate?.start_plate_url || !plate?.end_plate_url) {
    return json({ error: `No usable anchor plates for ${templateId} (mode=${cfg.mode})` }, 409);
  }
  const { data: prompts } = await db.from('match_cut_prompt_templates').select('*')
    .eq('template_id', templateId).order('version', { ascending: false }).limit(1);
  const promptTpl = prompts?.[0];
  if (!promptTpl) return json({ error: `No prompt template for ${templateId}` }, 500);
  const { data: tpl } = await db.from('match_cut_templates')
    .select('duration_min_s,duration_max_s').eq('id', templateId).single();

  // ── seed: re-runs keep the seed and adjust {SUBJECT_DESC} only (Hard Rule 39) ────
  let seed: number | undefined;
  let attempt = 1;
  if (body.rerun_of_generation_id) {
    const { data: prev } = await db.from('cinematic_generations').select('*')
      .eq('id', body.rerun_of_generation_id).eq('moment_id', moment_id).single();
    if (!prev) return json({ error: 'rerun_of_generation_id not found for this moment' }, 404);
    if (prev.status !== 'moderation_rejected') {
      return json({ error: 'Only a rejected generation can be re-run' }, 409);
    }
    seed = Number(prev.generation_seed);
    attempt = prev.attempt + 1;
  }

  // ── generate, or resume the pending generation with no new provider spend ────────
  let genId: string;
  let artUrl: string;
  let mp4Url: string;
  let durationS: number;
  let seedUsed: number;

  if (resumeGen) {
    genId = resumeGen.id as string;
    artUrl = db.storage.from('battle-media')
      .getPublicUrl(resumeGen.illustration_path as string).data.publicUrl;
    mp4Url = db.storage.from('battle-media')
      .getPublicUrl(resumeGen.mp4_path as string).data.publicUrl;
    durationS = Math.round(((tpl?.duration_min_s ?? 4) + (tpl?.duration_max_s ?? 6)) / 2);
    seedUsed = Number(resumeGen.generation_seed);
    console.log(`cinematic-mint: resuming pending generation ${genId} (no provider calls)`);
  } else {
    // ── illustration (card art; also the cutscene subject reference) ───────────────
    const illo = await generateIllustration(cfg, {
      prompt: illustrationPrompt(subject_desc, family),
      referenceImageUrl: moment.thumbnail_url ?? undefined,
      seed,
      width: 1024,   // portrait 4:5 card-art window — the app frames it, not 16:9
      height: 1280,
    });
    if (!illo.ok) {
      console.warn(`cinematic-mint illustration: ${illo.reason} status=${illo.status ?? ''} ${illo.detail ?? ''}`);
      return json({
        error: 'generation_unavailable', stage: 'illustration', reason: illo.reason,
        provider_status: illo.status ?? null, detail: illo.detail ?? null,
      }, illo.reason === 'rate_limited' ? 429 : 502);
    }
    const artPath = `moments/${moment_id}/card_art.png`;
    const artUp = await db.storage.from('battle-media').upload(artPath, illo.bytes, {
      contentType: illo.contentType, upsert: true,
    });
    if (artUp.error) return json({ error: 'card art store failed', detail: artUp.error.message }, 500);
    artUrl = db.storage.from('battle-media').getPublicUrl(artPath).data.publicUrl;

    // ── cutscene: bracketed by the plates, seeded, style-locked ────────────────────
    const fAction = familyAction(family, templateId);
    const intensity = TIER_INTENSITY[tier as Tier];
    // {VIDEO_DESC} is the attached clip's description (moment-clip-attach) — a VARIABLE
    // slot for the V2V core only; the agnostic bridge templates carry no placeholder for
    // it (Hard Rule 39). Absent (e.g. link-only ingest, no clip) → the slot collapses.
    const videoDesc = (moment.clip_video_desc as string | null) ?? null;
    const motionPrompt = assembleMotionPrompt(promptTpl.prompt_body, {
      subjectDesc: subject_desc, familyAction: fAction, tierIntensity: intensity,
      videoDesc,
    });
    durationS = Math.round(((tpl?.duration_min_s ?? 4) + (tpl?.duration_max_s ?? 6)) / 2);
    const cut = await generateCutscene(cfg, {
      prompt: motionPrompt,
      firstFrameUrl: plate.start_plate_url,
      lastFrameUrl: plate.end_plate_url,
      referenceImageUrl: artUrl,
      durationS,
      seed,
    });
    if (!cut.ok) {
      console.warn(`cinematic-mint cutscene: ${cut.reason} status=${cut.status ?? ''} ${cut.detail ?? ''}`);
      return json({
        error: 'generation_unavailable', stage: 'cutscene', reason: cut.reason,
        provider_status: cut.status ?? null, detail: cut.detail ?? null,
      }, cut.reason === 'rate_limited' ? 429 : 502);
    }
    const mp4Path = `moments/${moment_id}/attempt${attempt}/cutscene.mp4`;
    const mp4Up = await db.storage.from('battle-media').upload(mp4Path, cut.bytes, {
      contentType: 'video/mp4', upsert: true,
    });
    if (mp4Up.error) return json({ error: 'cutscene store failed', detail: mp4Up.error.message }, 500);
    mp4Url = db.storage.from('battle-media').getPublicUrl(mp4Path).data.publicUrl;

    // ── generation ledger row ───────────────────────────────────────────────────────
    const { data: gen, error: gErr } = await db.from('cinematic_generations').insert({
      moment_id,
      template_id: templateId,
      anchor_plate_version: plate.version,
      prompt_template_version: promptTpl.version,
      subject_desc: sanitizeSubjectDesc(subject_desc),
      video_desc: videoDesc,
      family_action: fAction,
      tier_intensity: intensity,
      generation_seed: cut.seed,
      render_tier: cfg.renderTier,
      mode: cfg.mode,
      attempt,
      illustration_path: artPath,
      mp4_path: mp4Path,
    }).select('id').single();
    if (gErr || !gen) return json({ error: 'ledger write failed', detail: gErr?.message }, 500);
    genId = gen.id as string;
    seedUsed = cut.seed;
  }

  // ── post-gen moderation (mandatory — Hard Rule 39) ───────────────────────────────
  // Modes (CINEMATIC_MODERATION): 'manual' = hold every generation for a human
  // verdict; 'auto' = approve blind (sim/dev ONLY — sim media is a stub with nothing
  // to screen); default in live = 'screen': sample frames of the ACTUAL generated MP4
  // (stitch worker) and classify them with the same fail-closed classifier as pre-gen.
  // Infra failure never approves — it holds for manual review (fail closed).
  // Provider-side filtering is a bonus, never a substitute.
  const moderation = Deno.env.get('CINEMATIC_MODERATION') ?? (cfg.mode === 'sim' ? 'auto' : 'screen');
  const alreadyApproved = resumeGen?.status === 'moderation_approved';
  if (!alreadyApproved) {
    if (moderation === 'manual') {
      return json({
        status: 'pending_moderation', generation_id: genId,
        detail: 'Post-generation moderation verdict required before the chit is created' +
          (swapOf ? '; the swap is NOT executed yet — pass swap_of_chit_id again at completion' : ''),
      }, 202);
    }
    if (moderation === 'screen') {
      const screen = await screenCutsceneFrames(db, genId, mp4Url, durationS);
      if (!screen.ok) {
        // Fail CLOSED: status stays 'generated' → a human verdict is required.
        console.warn(`cinematic-mint post-gen screen unavailable (${screen.detail}) — holding for manual review`);
        return json({
          status: 'pending_moderation', generation_id: genId,
          detail: 'Automated screening was unavailable, so the cutscene is held for manual review' +
            (swapOf ? '; the swap is NOT executed yet' : ''),
        }, 202);
      }
      if (screen.verdict !== 'approved') {
        const { error: rejErr } = await db.rpc('cinematic_moderation_verdict', {
          p_generation_id: genId, p_approved: false, p_reason: screen.reason ?? screen.verdict,
        });
        if (rejErr) console.warn(`cinematic-mint: reject verdict write failed: ${rejErr.message}`);
        return json({
          error: 'moderation_rejected', generation_id: genId,
          detail: 'The generated cutscene did not pass content moderation, so no card was ' +
            'created. You can adjust the description and generate again.',
        }, 422);
      }
    }
    const { error: modErr } = await db.rpc('cinematic_moderation_verdict', {
      p_generation_id: genId, p_approved: true, p_reason: null,
    });
    if (modErr) return json({ error: 'moderation verdict failed', detail: modErr.message }, 500);
  }

  // ── complete: chit + cinematic fields + ownership; inactive until previewed ──────
  const { data: chitId, error: cErr } = await db.rpc('cinematic_complete_mint', {
    p_generation_id: genId,
    p_family: family,
    p_chit_type: chit_type,
    p_timing: effectTiming,
    p_effect_template_id: effectTemplateId,
    p_name: body.name ?? null,
    p_keywords: grantKeywords,
    p_vibe_gate: body.vibe_gate ?? null,
    p_card_art_url: artUrl,
    p_mp4_url: mp4Url,
    p_swap_of: swapOf,
  });
  if (cErr) return json({ error: 'mint completion failed', detail: cErr.message }, 500);

  // ── swap aftermath: the old chit is retired (same tx as the mint above); its
  // media goes now — only after the new mint is confirmed (minting spec P4).
  let swappedMediaDeleted = 0;
  if (swapOf && oldMomentId) {
    try {
      swappedMediaDeleted = await deleteMomentMedia(db, oldMomentId);
    } catch (err) {
      console.warn(`cinematic-mint: old media cleanup failed (chit already retired):`, err);
    }
  }

  return json({
    status: 'pending_preview',
    chit_id: chitId,
    generation_id: genId,
    template_id: templateId,
    tier,
    seed: seedUsed,
    // sim mode returns placeholder bytes (1x1 png / non-playable mp4 stub) — the client
    // shows an honest "renders when the cinematic engine is live" state instead of a
    // blank card window + dead <video>. Real art/video only when CINEMATIC_MODE=live.
    mode: cfg.mode,
    media_placeholder: cfg.mode === 'sim',
    card_art_url: artUrl,
    mp4_cutscene_url: mp4Url,
    ...(swapOf ? { swapped_out_chit_id: swapOf, swapped_media_deleted: swappedMediaDeleted } : {}),
    next: 'Play the preview battle, then call chit_record_preview + chit_finalize_preview',
  });
});

// Post-gen screening (Hard Rule 39): sample frames of the FINISHED cutscene via the
// stitch worker (start / middle / last), sign them out of the private mint-staging
// bucket, and classify with the shared fail-closed classifier. Infra failures return
// ok:false (caller holds the generation for manual review — never approves); only a
// definite content label (nsfw/violence/hate/minor_safety) returns a non-approved
// verdict. With MODERATION_MODE=sim the classifier is the deterministic sim gate.
const CONTENT_REJECT_REASONS = new Set(['nsfw', 'graphic_violence', 'hate', 'minor_safety']);

async function screenCutsceneFrames(
  db: { storage: ReturnType<typeof createClient>['storage'] },
  genId: string, mp4Url: string, durationS: number,
): Promise<{ ok: true; verdict: string; reason?: string } | { ok: false; detail: string }> {
  const workerUrl = Deno.env.get('STITCH_WORKER_URL');
  const secret = Deno.env.get('STITCH_SECRET');
  if (!workerUrl || !secret) return { ok: false, detail: 'stitch worker not configured' };

  let res: Response;
  try {
    res = await fetch(`${workerUrl.replace(/\/$/, '')}/frames`, {
      method: 'POST',
      headers: { 'X-Stitch-Secret': secret, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        video_url: mp4Url,
        times: [0.4, Math.max(0.8, durationS / 2), 'last'],
        upload: { bucket: 'mint-staging', prefix: `postgen/${genId}` },
      }),
    });
  } catch (e) {
    return { ok: false, detail: `frames call failed: ${(e as Error).message}` };
  }
  if (!res.ok) {
    let bodyTxt = '';
    try { bodyTxt = (await res.text()).slice(0, 300); } catch { /* keep status only */ }
    return { ok: false, detail: `frames HTTP ${res.status}: ${bodyTxt}` };
  }

  let framePaths: string[];
  try {
    const payload = await res.json();
    framePaths = ((payload.frames ?? []) as { path: string }[])
      .map((f) => String(f.path).replace(/^mint-staging\//, ''));
  } catch {
    return { ok: false, detail: 'frames response unparseable' };
  }
  if (framePaths.length === 0) return { ok: false, detail: 'no frames extracted' };

  // The staging bucket is private — sign short-lived URLs for the classifier only.
  const urls: string[] = [];
  for (const p of framePaths) {
    const { data: signed } = await db.storage.from('mint-staging').createSignedUrl(p, 600);
    if (signed?.signedUrl) urls.push(signed.signedUrl);
  }
  if (urls.length === 0) return { ok: false, detail: 'could not sign frame urls' };

  const verdict = await preGenModerate(moderationConfigFromEnv(), { imageUrls: urls });
  // The classifier fails closed to 'rejected' on infra errors — for POST-gen that
  // must mean "hold for a human", not a permanent reject of a clean generation.
  if (verdict.verdict !== 'approved' && !CONTENT_REJECT_REASONS.has(verdict.reason ?? '')) {
    return { ok: false, detail: `classifier unavailable: ${verdict.reason ?? 'unknown'}` };
  }
  return { ok: true, verdict: verdict.verdict, reason: verdict.reason };
}

// Remove every battle-media object under moments/<momentId> (card art + all
// cutscene attempts). Storage list() marks folders with a null id.
async function deleteMomentMedia(
  db: { storage: ReturnType<typeof createClient>['storage'] }, momentId: string,
): Promise<number> {
  const root = `moments/${momentId}`;
  const files: string[] = [];
  const { data: entries } = await db.storage.from('battle-media').list(root, { limit: 100 });
  for (const e of entries ?? []) {
    if (e.id) files.push(`${root}/${e.name}`);
    else {
      const { data: sub } = await db.storage.from('battle-media').list(`${root}/${e.name}`, { limit: 100 });
      for (const s of sub ?? []) if (s.id) files.push(`${root}/${e.name}/${s.name}`);
    }
  }
  if (files.length > 0) {
    const { error } = await db.storage.from('battle-media').remove(files);
    if (error) throw new Error(error.message);
  }
  return files.length;
}
