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

  // ── tier (engagement-derived — Hard Rule 34) + template selection ────────────────
  const { data: tier, error: tErr } = await db.rpc('tier_for_engagement', { p_engagement: moment.engagement_count });
  if (tErr || !tier) return json({ error: 'Tier derivation failed', detail: tErr?.message }, 500);

  let effectKind: string | null = null, target: string | null = null;
  if (body.effect_template_id) {
    const { data: eff } = await db.from('effect_templates')
      .select('effect_kind,target').eq('id', body.effect_template_id).single();
    effectKind = eff?.effect_kind ?? null;
    target = eff?.target ?? null;
  }
  const templateId = selectTemplate({
    chitType: chit_type, tier: tier as Tier, timing: body.timing_type, effectKind, target,
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

  // ── illustration (card art; also the cutscene subject reference) ─────────────────
  const illo = await generateIllustration(cfg, {
    prompt: illustrationPrompt(subject_desc),
    referenceImageUrl: moment.thumbnail_url ?? undefined,
    seed,
  });
  if (!illo.ok) {
    console.warn(`cinematic-mint illustration: ${illo.reason}`);
    return json({ error: 'generation_unavailable', stage: 'illustration', reason: illo.reason }, illo.reason === 'rate_limited' ? 429 : 502);
  }
  const artPath = `moments/${moment_id}/card_art.png`;
  const artUp = await db.storage.from('battle-media').upload(artPath, illo.bytes, {
    contentType: illo.contentType, upsert: true,
  });
  if (artUp.error) return json({ error: 'card art store failed', detail: artUp.error.message }, 500);
  const artUrl = db.storage.from('battle-media').getPublicUrl(artPath).data.publicUrl;

  // ── cutscene: bracketed by the plates, seeded, style-locked ──────────────────────
  const fAction = familyAction(family, templateId);
  const intensity = TIER_INTENSITY[tier as Tier];
  const motionPrompt = assembleMotionPrompt(promptTpl.prompt_body, {
    subjectDesc: subject_desc, familyAction: fAction, tierIntensity: intensity,
  });
  const durationS = Math.round(((tpl?.duration_min_s ?? 4) + (tpl?.duration_max_s ?? 6)) / 2);
  const cut = await generateCutscene(cfg, {
    prompt: motionPrompt,
    firstFrameUrl: plate.start_plate_url,
    lastFrameUrl: plate.end_plate_url,
    referenceImageUrl: artUrl,
    durationS,
    seed,
  });
  if (!cut.ok) {
    console.warn(`cinematic-mint cutscene: ${cut.reason}`);
    return json({ error: 'generation_unavailable', stage: 'cutscene', reason: cut.reason }, cut.reason === 'rate_limited' ? 429 : 502);
  }
  const mp4Path = `moments/${moment_id}/attempt${attempt}/cutscene.mp4`;
  const mp4Up = await db.storage.from('battle-media').upload(mp4Path, cut.bytes, {
    contentType: 'video/mp4', upsert: true,
  });
  if (mp4Up.error) return json({ error: 'cutscene store failed', detail: mp4Up.error.message }, 500);
  const mp4Url = db.storage.from('battle-media').getPublicUrl(mp4Path).data.publicUrl;

  // ── generation ledger row ─────────────────────────────────────────────────────────
  const { data: gen, error: gErr } = await db.from('cinematic_generations').insert({
    moment_id,
    template_id: templateId,
    anchor_plate_version: plate.version,
    prompt_template_version: promptTpl.version,
    subject_desc: sanitizeSubjectDesc(subject_desc),
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

  // ── post-gen moderation (mandatory — Hard Rule 39) ───────────────────────────────
  // sim/auto: approve and continue. manual: stop here; a human verdict + a follow-up
  // completion run the rest. Provider-side filtering is a bonus, never a substitute.
  const moderation = Deno.env.get('CINEMATIC_MODERATION') ?? (cfg.mode === 'sim' ? 'auto' : 'manual');
  if (moderation !== 'auto') {
    return json({
      status: 'pending_moderation', generation_id: gen.id,
      detail: 'Post-generation moderation verdict required before the chit is created',
    }, 202);
  }
  const { error: modErr } = await db.rpc('cinematic_moderation_verdict', {
    p_generation_id: gen.id, p_approved: true, p_reason: null,
  });
  if (modErr) return json({ error: 'moderation verdict failed', detail: modErr.message }, 500);

  // ── complete: chit + cinematic fields + ownership; inactive until previewed ──────
  const { data: chitId, error: cErr } = await db.rpc('cinematic_complete_mint', {
    p_generation_id: gen.id,
    p_family: family,
    p_chit_type: chit_type,
    p_timing: body.timing_type ?? null,
    p_effect_template_id: body.effect_template_id ?? null,
    p_name: body.name ?? null,
    p_keywords: body.keywords ?? [],
    p_vibe_gate: body.vibe_gate ?? null,
    p_card_art_url: artUrl,
    p_mp4_url: mp4Url,
  });
  if (cErr) return json({ error: 'mint completion failed', detail: cErr.message }, 500);

  return json({
    status: 'pending_preview',
    chit_id: chitId,
    generation_id: gen.id,
    template_id: templateId,
    tier,
    seed: cut.seed,
    card_art_url: artUrl,
    mp4_cutscene_url: mp4Url,
    next: 'Play the preview battle, then call chit_record_preview + chit_finalize_preview',
  });
});
