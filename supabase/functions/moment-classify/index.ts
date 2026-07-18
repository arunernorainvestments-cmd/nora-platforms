// supabase/functions/moment-classify/index.ts
// Minting v2 — the "recommend/classify" stage the spec's link → recommend → classify
// chain was missing. Derives the creative inputs cinematic-mint requires (family,
// chit_type, subject_desc) from an already-approved, clip-attached moment so the web
// mint wizard can offer a "Review your card" step before generation.
//
// POST { moment_id, family_override?, subject_desc? }
// Returns { family, suggested_name, subject_desc, chit_type, effect_* }.
//
// The archetype FAMILY defaults to content-derived, but the user may override it with
// any family from the fixed 10-family allowlist (family_override — the wizard's
// "Automatic / pick it yourself" selector). Either way the family is persisted to
// moments.archetype_family and the EFFECT is always server-selected from that family's
// authored, balanced library — the override changes the card's effect STYLE, never its
// power: tier/cost/atk/hp stay engagement-derived (Hard Rule 34). Name is a suggestion
// the user may edit; chit_type defaults to creature.
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

// Keyword → family, scanned against title + handle + url in sim mode (and as the
// fallback if a live verdict is unparseable). Each family has several signal groups
// (identity / activity / scene terms); the family with the MOST matching groups wins —
// scored, not first-match-wins, so "gym prank" reads comedian+athlete and the stronger
// signal decides. Ties resolve in array order (specific families before the
// influencer fallback). No group hit at all → influencer.
const FAMILY_PATTERNS: [Family, RegExp[]][] = [
  ['athlete', [
    /\b(sports?|athletes?|athletic|basketball|football|soccer|baseball|hockey|tennis|golf|boxing|mma|ufc|wrestling|skate\w*|surf(ing|er)?|track|marathon|sprint(s|er)?)\b/i,
    /\b(dunks?|goals?|touchdowns?|home\s?runs?|knockouts?|buzzer\s?beaters?|game[- ]winn\w*|hat\s?trick|personal\s?record|championship|league|tournament|playoffs?)\b/i,
    /\b(gym|workouts?|fitness|lift(ing)?|deadlift|squats?|bench\s?press|crossfit|training|coach(ing)?)\b/i,
  ]],
  ['musician', [
    /\b(music|musicians?|songs?|albums?|singles?|beats?|melod\w*|lyrics?|vocals?|choir)\b/i,
    /\b(sing(er|ers|ing)?|rap(per|pers|ping)?|hip\s?hop|guitar\w*|piano|drum\w*|bass(ist)?|violin\w*|saxophone|dj|produc(er|ing)\b)\b/i,
    /\b(concerts?|tours?|studio\s?session|covers?|remix\w*|freestyle|acoustic|unplugged|mixtape|soundcheck)\b/i,
  ]],
  ['comedian', [
    /\b(comedy|comedians?|stand\s?up|roasts?|parod\w*|impressions?|improv)\b/i,
    /\b(funny|jokes?|pranks?|skits?|sketch(es)?|humor|hilarious|gags?)\b/i,
    /\b(memes?|lol|lmao|laugh\w*|punchlines?|crowd\s?work)\b/i,
  ]],
  ['gamer', [
    /\b(gam(ing|er|ers)|video\s?games?|esports?|speedrun\w*|ranked|lobby|respawn)\b/i,
    /\b(twitch|stream(er|ers|ing)|fps|mmo|battle\s?royale|minecraft|fortnite|valorant|warzone|roblox|league\s?of\s?legends|elden|zelda|mario)\b/i,
    /\b(clutch(ed)?|no\s?scope|killstreak|console|controller|ps[45]|xbox|nintendo|pc\s?build|gg)\b/i,
  ]],
  ['scientist', [
    /\b(science|scientists?|experiments?|research(er)?|lab(oratory)?|hypothesis|physics|chemistry|biology|astronom\w*|geolog\w*)\b/i,
    /\b(space|nasa|spacex|rockets?|robots?|robotics|drones?|engineer\w*|inventions?|3d\s?print\w*)\b/i,
    /\b(tech(nology)?|coding|programm\w*|software|hardware|ai|machine\s?learning|math(s|ematics)?|calculus|data\s?science)\b/i,
  ]],
  ['artist', [
    /\b(artists?|artwork|paint(er|ing|ings)?|draw(ing|ings)?|sketch(ing|es)?|illustrat\w*|canvas)\b/i,
    /\b(design(er|ers|ing)?|animation|animator|sculpt\w*|pottery|ceramics|murals?|tattoos?|calligraphy|origami)\b/i,
    /\b(crafts?|diy|handmade|digital\s?art|procreate|watercolor|acrylic|charcoal|time\s?lapse\s?art)\b/i,
  ]],
  ['politician', [
    /\b(politic\w*|senat\w*|congress\w*|governor|mayor|president(ial)?|parliament|legislat\w*|councilman|councilwoman)\b/i,
    /\b(campaigns?|elections?|polic(y|ies)|votes?|voting|voters?|ballots?|debates?|caucus)\b/i,
    /\b(rall(y|ies)|activis\w*|protests?|petitions?|town\s?hall|civic|constituents?)\b/i,
  ]],
  ['business', [
    /\b(business(es)?|startups?|entrepreneurs?\w*|founders?|ceo|cfo|llc|agency)\b/i,
    /\b(invest(or|ors|ing|ments?)?|finance|financial|revenue|profits?|sales?|e-?commerce|dropship\w*|real\s?estate|stocks?|crypto\w*)\b/i,
    /\b(hustle|side\s?hustle|pitch(ing|ed)?|shark\s?tank|network(ing)?|brand\s?deal|marketing|passive\s?income)\b/i,
  ]],
  ['actor', [
    /\b(act(or|ors|ress|resses|ing)|films?|movies?|cinema|hollywood|screenplay)\b/i,
    /\b(scenes?|theater|theatre|drama|monologues?|dialogue|improv\s?scene|table\s?read)\b/i,
    /\b(auditions?|casting|netflix|series|sitcom|behind\s?the\s?scenes|on\s?set|premiere|cosplay)\b/i,
  ]],
  // influencer is the explicit lifestyle bucket AND the no-signal fallback.
  ['influencer', [
    /\b(vlog\w*|influencers?|lifestyle|day\s?in\s?the\s?life|storytime|grwm|get\s?ready\s?with\s?me)\b/i,
    /\b(fashion|makeup|beauty|skincare|outfit|ootd|hauls?|unboxing|try\s?on)\b/i,
    /\b(travel\w*|food(ie)?|mukbang|recipes?|asmr|challenges?|viral|trend(ing|s)?)\b/i,
  ]],
];

function heuristicFamily(text: string): Family {
  let best: Family = FALLBACK_FAMILY;
  let bestScore = 0;
  for (const [family, groups] of FAMILY_PATTERNS) {
    const score = groups.reduce((n, re) => n + (re.test(text) ? 1 : 0), 0);
    if (score > bestScore) {
      best = family;
      bestScore = score;
    }
  }
  return best;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { status: 200, headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) return json({ error: 'Unauthorized' }, 401);
  const anon = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!);
  const { data: { user }, error: authError } = await anon.auth.getUser(authHeader.replace('Bearer ', ''));
  if (authError || !user) return json({ error: 'Unauthorized' }, 401);

  let body: { moment_id?: string; family_override?: string; subject_desc?: string; chit_type?: string };
  try { body = await req.json(); } catch { return json({ error: 'Invalid JSON body' }, 400); }
  const momentId = body.moment_id?.trim();
  if (!momentId) return json({ error: 'Missing required field: moment_id' }, 400);
  const override = body.family_override?.trim() || null;
  if (override && !FAMILIES.includes(override as Family)) {
    return json({ error: 'invalid_family', detail: `family_override must be one of: ${FAMILIES.join(', ')}` }, 400);
  }

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  // ── ownership + approval + not-yet-minted (same guards as moment-clip-attach) ─────
  const { data: moment } = await db.from('moments')
    .select('id, owner_user_id, moderation_status, mint_status, creator_handle, source_url, thumbnail_url, post_title')
    .eq('id', momentId).eq('owner_user_id', user.id)
    .maybeSingle();
  if (!moment) return json({ error: 'moment_not_found' }, 404);
  if (moment.moderation_status !== 'approved') {
    return json({ error: 'moment_not_approved', detail: 'Run moment-ingest first' }, 409);
  }
  if (moment.mint_status === 'minted') return json({ error: 'already_minted' }, 409);

  // Text signal: post title (persisted at ingest, mig 158) + handle + url; live mode
  // additionally leans on the thumbnail image itself (the strongest signal).
  const handle = String(moment.creator_handle ?? '').replace(/^@/, '');
  const title = String(moment.post_title ?? '').trim();
  const context = `${title} ${handle} ${moment.source_url ?? ''}`.trim();

  const mode = Deno.env.get('MOMENT_CLASSIFY_MODE') === 'live' ? 'live' : 'sim';
  let result: { family: Family; suggested_name: string; subject_desc: string; chit_type: 'creature' | 'spell_moment' };

  if (override) {
    // User-chosen family (allowlist-validated above): no family detection runs. The
    // wizard keeps its existing name/subject state; these fields are echo/fallback only.
    result = {
      family: override as Family,
      suggested_name: prettyName(handle) || 'My Moment',
      subject_desc: sanitizeSubjectDesc(
        body.subject_desc?.trim() ||
          `${prettyName(handle) || 'a creator'} in their signature ${override} moment`,
      ),
      // Honor the wizard's current card-type choice so the effect pool filters right.
      chit_type: body.chit_type === 'spell_moment' ? 'spell_moment' : 'creature',
    };
  } else if (mode === 'live') {
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
    // Authored template description — the Review step's rules preview (the user
    // used to confirm a card without ever seeing what its effect does).
    effect_desc: effect?.description ?? null,
  });
});

// ── effect selection: pick one authored template from the family's candidates ───────
// Candidate set = the classified family's active, single-clause (Wave 1), non-fusion
// templates, timing-filtered for spell-moments (one-shot: on_summon/activated only). sim →
// deterministic hash of the subject description (stable, no spend, gives variety once the
// library has >1 per family); live → an LLM allowlist pick with the deterministic fallback.
interface EffectPick {
  effect_template_id: string; timing_type: string; name: string; description: string | null;
}

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
  return {
    effect_template_id: chosen.id, timing_type: chosen.timing_type, name: chosen.name,
    description: list.find((c) => c.id === chosen.id)?.description ?? null,
  };
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
// Family criteria are explicit and content-first: classify WHAT IS HAPPENING in the
// moment, not who posted it or how popular they are. Signal priority: thumbnail image
// (visible activity, setting, props) > post title/caption > creator handle. The
// influencer family is a real category (lifestyle/vlog/fashion/beauty/travel content),
// but it is also the ONLY permitted fallback — it must never absorb a moment that
// clearly fits a specific family.
const CLASSIFIER_SYSTEM =
  'You name and classify a collectible battle card minted from a social-media post.\n\n' +
  'Choose "family" = the category of WHAT IS HAPPENING in the moment (the activity and ' +
  'setting), never merely who posted it. Judge the thumbnail image first (visible ' +
  'activity, setting, props, clothing), then the post title/caption, then the handle.\n' +
  'Family definitions:\n' +
  '- athlete: sports, fitness, physical competition or feats (game plays, gym, races, martial arts)\n' +
  '- musician: performing or making music — singing, rapping, instruments, DJing, studio work\n' +
  '- artist: visual/creative arts — drawing, painting, design, animation, sculpture, crafts, tattoos\n' +
  '- scientist: science, engineering, technology, coding, experiments, space, robotics, math\n' +
  '- comedian: content whose PURPOSE is comedy — jokes, pranks, skits, stand-up, parody (comedic intent, not merely an amusing clip)\n' +
  '- politician: politics and civic life — campaigns, debates, policy, activism, public office\n' +
  '- business: entrepreneurship, startups, finance, investing, sales, commerce\n' +
  '- gamer: video games — gameplay, streaming, esports, speedruns, consoles\n' +
  '- actor: film/TV/theater performance — scripted scenes, monologues, auditions, on-set moments\n' +
  '- influencer: lifestyle/vlog/fashion/beauty/food/travel content; ALSO the only fallback when no ' +
  'specific family above fits. Never use it for a moment that clearly fits another family.\n\n' +
  'Respond with ONLY a JSON object, no prose:\n' +
  '{"family": <one of: athlete, musician, artist, scientist, comedian, influencer, ' +
  'politician, business, gamer, actor>,\n' +
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
  content.push({ type: 'text', text: `Post title + creator handle + context: ${context}\n\nClassify and name now.` });

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
