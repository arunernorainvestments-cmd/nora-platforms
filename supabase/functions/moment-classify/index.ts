// supabase/functions/moment-classify/index.ts
// Minting v2 — the "recommend/classify" stage the spec's link → recommend → classify
// chain was missing. Derives the creative inputs cinematic-mint requires (family,
// chit_type, subject_desc) from an already-approved, clip-attached moment so the web
// mint wizard can offer a "Review your card" step before generation.
//
// POST { moment_id }
// Returns { family, suggested_name, subject_desc, chit_type }.
//
// The archetype FAMILY is content-derived, never user-set (Hard Rule 34) — it is
// classified here and persisted to moments.archetype_family. Name is a suggestion the
// user may edit; chit_type defaults to creature.
//
// MOMENT_CLASSIFY_MODE=sim (default) → deterministic heuristic (no model spend).
// live → Claude (claude-sonnet-4-6), reusing the call shape in _shared/moderation.ts.
// Deployed --no-verify-jwt (ES256 project); auth via supabase.auth.getUser().

import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { sanitizeSubjectDesc, type Family } from '../_shared/cinematic_directives.ts';

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

// The 10 effect-families (cinematic_directives.ts Family union) as a runtime allowlist.
const FAMILIES: Family[] = [
  'athlete', 'musician', 'artist', 'scientist', 'comedian',
  'influencer', 'politician', 'business', 'gamer', 'actor',
];
const FALLBACK_FAMILY: Family = 'influencer';

// Keyword → family, scanned against handle + title in sim mode (and as the fallback
// if a live verdict is unparseable). First match wins; order is intentional.
const FAMILY_HINTS: [Family, RegExp][] = [
  ['athlete', /\b(sport|athlet|ball|game winning|dunk|goal|touchdown|workout|gym|lift|race|match)\b/i],
  ['musician', /\b(music|song|beat|sing|rap|guitar|piano|dj|concert|album|cover|remix)\b/i],
  ['comedian', /\b(comedy|funny|joke|prank|skit|meme|lol|laugh)\b/i],
  ['gamer', /\b(gaming|gamer|stream|twitch|speedrun|clutch|fps|valorant|fortnite|clip)\b/i],
  ['scientist', /\b(science|experiment|physics|chemistry|space|math|engineer|tech|coding|build)\b/i],
  ['artist', /\b(art|paint|draw|sketch|design|craft|sculpt|animation|illustrat)\b/i],
  ['politician', /\b(politic|senat|congress|governor|campaign|policy|vote|debate)\b/i],
  ['business', /\b(business|startup|entrepreneur|founder|invest|market|brand|hustle|money)\b/i],
  ['actor', /\b(acting|actor|actress|film|movie|scene|theater|drama|monologue)\b/i],
];

function heuristicFamily(text: string): Family {
  for (const [family, re] of FAMILY_HINTS) if (re.test(text)) return family;
  return FALLBACK_FAMILY;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { status: 200, headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) return json({ error: 'Unauthorized' }, 401);
  const anon = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!);
  const { data: { user }, error: authError } = await anon.auth.getUser(authHeader.replace('Bearer ', ''));
  if (authError || !user) return json({ error: 'Unauthorized' }, 401);

  let body: { moment_id?: string };
  try { body = await req.json(); } catch { return json({ error: 'Invalid JSON body' }, 400); }
  const momentId = body.moment_id?.trim();
  if (!momentId) return json({ error: 'Missing required field: moment_id' }, 400);

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  // ── ownership + approval + not-yet-minted (same guards as moment-clip-attach) ─────
  const { data: moment } = await db.from('moments')
    .select('id, owner_user_id, moderation_status, mint_status, creator_handle, source_url, thumbnail_url')
    .eq('id', momentId).eq('owner_user_id', user.id)
    .maybeSingle();
  if (!moment) return json({ error: 'moment_not_found' }, 404);
  if (moment.moderation_status !== 'approved') {
    return json({ error: 'moment_not_approved', detail: 'Run moment-ingest first' }, 409);
  }
  if (moment.mint_status === 'minted') return json({ error: 'already_minted' }, 409);

  // No post title is persisted on moments, so the sim signal is handle + url; live
  // mode leans on the thumbnail image itself (the real classification signal).
  const handle = String(moment.creator_handle ?? '').replace(/^@/, '');
  const context = `${handle} ${moment.source_url ?? ''}`.trim();

  const mode = Deno.env.get('MOMENT_CLASSIFY_MODE') === 'live' ? 'live' : 'sim';
  let result: { family: Family; suggested_name: string; subject_desc: string; chit_type: 'creature' | 'spell_moment' };

  if (mode === 'live') {
    result = await liveClassify(context, moment.thumbnail_url ?? null, handle);
  } else {
    const family = heuristicFamily(context);
    result = {
      family,
      suggested_name: prettyName(handle) || 'My Moment',
      subject_desc: sanitizeSubjectDesc(
        `${prettyName(handle) || 'a creator'} in their signature ${family} moment`,
      ),
      chit_type: 'creature',
    };
  }

  // ── select the effect from the family's authored library (Hard Rule 34) ───────────
  // The effect is chosen from the classified family's balanced templates and PERSISTED on
  // the moment — cinematic-mint reads it from here, never from the client (a client-supplied
  // effect_template_id would be a power-selection tamper vector). The AI only *selects* an
  // authored option; magnitude comes from the tier (engagement), never from the description.
  const effect = await selectEffectTemplate(
    db, result.family, result.chit_type, result.subject_desc, mode,
    Deno.env.get('ANTHROPIC_API_KEY') ?? null,
    Deno.env.get('MODERATION_MODEL') ?? 'claude-sonnet-4-6',
  );

  // ── persist the content-derived family + selected effect (Hard Rule 34) ───────────
  const { error: upErr } = await db.from('moments')
    .update({
      archetype_family: result.family,
      selected_effect_template_id: effect?.effect_template_id ?? null,
      selected_timing: effect?.timing_type ?? null,
    }).eq('id', momentId);
  if (upErr) return json({ error: 'classify_persist_failed', detail: upErr.message }, 500);

  return json({
    ...result,
    effect_template_id: effect?.effect_template_id ?? null,
    effect_timing: effect?.timing_type ?? null,
    effect_name: effect?.name ?? null,
  });
});

// ── effect selection: pick one authored template from the family's candidates ───────
// Candidate set = the classified family's active, single-clause (Wave 1), non-fusion
// templates, timing-filtered for spell-moments (one-shot: on_summon/activated only). sim →
// deterministic hash of the subject description (stable, no spend, gives variety once the
// library has >1 per family); live → an LLM allowlist pick with the deterministic fallback.
interface EffectPick { effect_template_id: string; timing_type: string; name: string }

async function selectEffectTemplate(
  db: SupabaseClient,
  family: Family, chitType: 'creature' | 'spell_moment', subjectDesc: string,
  mode: 'sim' | 'live', apiKey: string | null, model: string,
): Promise<EffectPick | null> {
  const { data: rows } = await db.from('effect_templates')
    .select('id, key, name, timing_type, effect_kind, target, description')
    .eq('archetype_family', family).eq('is_active', true)
    .eq('is_fusion', false).eq('complexity', 1)
    .order('key');
  let list = (rows ?? []) as Array<{
    id: string; key: string; name: string; timing_type: string;
    effect_kind: string; target: string; description: string | null;
  }>;
  if (chitType === 'spell_moment') {
    list = list.filter((c) => c.timing_type === 'on_summon' || c.timing_type === 'activated');
  }
  if (list.length === 0) return null;

  // Deterministic default (also the live fallback).
  let chosen: { id: string; timing_type: string; name: string } =
    list[fnv1a(subjectDesc || family) % list.length];

  if (mode === 'live' && apiKey) {
    const live = await liveSelectEffect(apiKey, model, subjectDesc, list);
    if (live) chosen = live;
  }
  return { effect_template_id: chosen.id, timing_type: chosen.timing_type, name: chosen.name };
}

function fnv1a(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193); }
  return h >>> 0;
}

const EFFECT_SELECT_SYSTEM =
  'You pick the single battle effect that best fits a social moment, from a fixed list. ' +
  'Respond with ONLY the chosen template key (one token from the list), no prose.';

async function liveSelectEffect(
  apiKey: string, model: string, subjectDesc: string,
  list: Array<{ id: string; key: string; name: string; timing_type: string; effect_kind: string; description: string | null }>,
): Promise<{ id: string; key: string; name: string; timing_type: string } | null> {
  const menu = list.map((c) => `- ${c.key}: ${c.name} — ${c.description ?? c.effect_kind}`).join('\n');
  let res: Response;
  try {
    res = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': apiKey, 'anthropic-version': '2023-06-01', 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model, max_tokens: 40, system: EFFECT_SELECT_SYSTEM,
        messages: [{ role: 'user', content: `Moment: ${subjectDesc}\n\nOptions:\n${menu}\n\nBest key:` }],
      }),
    });
  } catch { return null; }
  if (res.status === 429) { await res.body?.cancel(); return null; }   // Hard Rule 8
  if (!res.ok) { await res.body?.cancel(); return null; }
  try {
    const data = await res.json();
    const text: string = data.content?.find((b: { type: string }) => b.type === 'text')?.text ?? '';
    const key = text.trim().replace(/[^a-z0-9_]/gi, '');
    return list.find((c) => c.key === key) ?? null;   // allowlist — unknown → fallback
  } catch { return null; }
}

// Title-case a handle into a readable card name ("lifeofruner" → "Lifeofruner").
function prettyName(handle: string): string {
  const cleaned = handle.replace(/[._-]+/g, ' ').replace(/\s+/g, ' ').trim();
  if (!cleaned) return '';
  return cleaned.replace(/\b\w/g, (c) => c.toUpperCase()).slice(0, 40);
}

// ── live: Claude classification (reuses the _shared/moderation.ts call shape) ───────
const CLASSIFIER_SYSTEM =
  'You name and classify a collectible battle card minted from a social-media post. ' +
  'Respond with ONLY a JSON object, no prose:\n' +
  '{"family": <one of: athlete, musician, artist, scientist, comedian, influencer, ' +
  'politician, business, gamer, actor — the effect-family that best fits the creator/moment>,\n' +
  ' "name": <a short punchy card name, <= 4 words, no quotes>,\n' +
  ' "subject_desc": <one vivid sentence describing the visible subject for card art, no names of ' +
  'real third parties>,\n' +
  ' "chit_type": <"creature" for a person/character, "spell_moment" for an effect/action moment>}';

async function liveClassify(
  context: string, thumbnailUrl: string | null, handle: string,
): Promise<{ family: Family; suggested_name: string; subject_desc: string; chit_type: 'creature' | 'spell_moment' }> {
  const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
  const model = Deno.env.get('MODERATION_MODEL') ?? 'claude-sonnet-4-6';
  const fallback = {
    family: heuristicFamily(context),
    suggested_name: prettyName(handle) || 'My Moment',
    subject_desc: sanitizeSubjectDesc(`${prettyName(handle) || 'a creator'} in their signature moment`),
    chit_type: 'creature' as const,
  };
  if (!apiKey) return fallback;

  const content: unknown[] = [];
  if (thumbnailUrl) content.push({ type: 'image', source: { type: 'url', url: thumbnailUrl } });
  content.push({ type: 'text', text: `Creator handle + context: ${context}\n\nClassify and name now.` });

  let res: Response;
  try {
    res = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model, max_tokens: 300, system: CLASSIFIER_SYSTEM,
        messages: [{ role: 'user', content }],
      }),
    });
  } catch (err) {
    console.warn('moment-classify live call failed:', err instanceof Error ? err.message : String(err));
    return fallback;
  }
  if (res.status === 429) { await res.body?.cancel(); console.warn('moment-classify rate-limited'); return fallback; }
  if (!res.ok) { await res.body?.cancel(); return fallback; }

  try {
    const data = await res.json();
    const text: string = data.content?.find((b: { type: string }) => b.type === 'text')?.text ?? '';
    const match = text.match(/\{[\s\S]*\}/);
    if (!match) return fallback;
    const raw = JSON.parse(match[0]) as Record<string, unknown>;
    const family = FAMILIES.includes(raw.family as Family) ? (raw.family as Family) : fallback.family;
    const chitType = raw.chit_type === 'spell_moment' ? 'spell_moment' : 'creature';
    const name = typeof raw.name === 'string' && raw.name.trim()
      ? raw.name.trim().slice(0, 40) : fallback.suggested_name;
    const subject = typeof raw.subject_desc === 'string' && raw.subject_desc.trim()
      ? sanitizeSubjectDesc(raw.subject_desc) : fallback.subject_desc;
    return { family, suggested_name: name, subject_desc: subject, chit_type: chitType };
  } catch (err) {
    console.warn('moment-classify parse failed:', err instanceof Error ? err.message : String(err));
    return fallback;
  }
}
