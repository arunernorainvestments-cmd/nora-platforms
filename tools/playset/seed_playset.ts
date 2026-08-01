// tools/playset/seed_playset.ts — Standard Playset operator tool (spec PHASE S2).
//
// The 30-card slate itself is DATA, authored in migration 182 through the sanctioned
// admin_seed_* path (ladder-derived stats, moderated, generic + starter stamps). This
// tool is the re-runnable half the spec asks for: it verifies the shipped set against
// the coverage contract, reports where each card's media stands, and carries cards
// from sim placeholders to live renders one moderated attach at a time.
//
// It NEVER writes stats, tiers, or effects — those come from the ladder, always.
//
// Modes:
//   (default) verify   — coverage contract + grant health, read-only. Exit 1 on any miss.
//   --report           — per-card table: tier, type, effect, keywords, media state.
//   --add              — author ONE new base card through the sanctioned seed path
//                        (moment → moderation → ladder-derived mint), then hand it to
//                        every account. Stats/tier are NEVER passed in: --tier picks the
//                        engagement band, the ladder derives cost/atk/hp/effect from it.
//                          --add="Card Name" --family=gamer --type=creature --tier=D \
//                          --effect=gamer_on_summon_multikill [--keywords=charge,taunt]
//                          [--flavor="one line"] [--no-grant]
//   --render-art       — PAID. Generate the card-art illustration for cards that have
//                        none, via the shared Segmind client, and store it in
//                        battle-media. Requires CINEMATIC_MODE=live, SEGMIND_API_KEY and
//                        an explicit --confirm-spend. One image per card, resumable.
//   --attach           — attach finished, HUMAN-REVIEWED media to one card:
//                        --attach=<card name|id> --verdict=approved
//                        with --art=<battle-media url> and/or --mp4=<battle-media url>.
//                        Either leg alone is fine — art-only is the usual first step,
//                        since card art lands long before any cutscene. The DB refuses
//                        anything that is not an approved battle-media object
//                        (Hard Rule 38 + mandatory post-gen moderation).
//
// Anti-slop gate (spec §0.5, hard publish gate): --render-art produces DRAFTS. Nothing
// this tool generates reaches a player until a human has looked at it and run --attach
// (or set card_art_url through the same reviewed flow). The tool prints the review URL
// and refuses to auto-approve anything.
//
// Run:
//   SUPABASE_URL=https://<ref>.supabase.co SERVICE_KEY=… \
//     deno run --allow-net --allow-env tools/playset/seed_playset.ts [--report]
//
//   CINEMATIC_MODE=live SEGMIND_API_KEY=… SUPABASE_URL=… SERVICE_KEY=… \
//     deno run --allow-net --allow-env tools/playset/seed_playset.ts \
//       --render-art --confirm-spend [--limit=5]

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {
  cinematicConfigFromEnv,
  generateIllustration,
} from '../../supabase/functions/_shared/segmind.ts';
import { illustrationPrompt, type Family } from '../../supabase/functions/_shared/cinematic_directives.ts';

const url = (Deno.env.get('SUPABASE_URL') ?? 'https://cceisywxwhgljdpisjrl.supabase.co').replace(/\/$/, '');
const serviceKey = Deno.env.get('SERVICE_KEY') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
if (!serviceKey) {
  console.error('SERVICE_KEY (service role) required');
  Deno.exit(1);
}
const db = createClient(url, serviceKey, { auth: { persistSession: false } });

const args = new Map<string, string>();
for (const a of Deno.args) {
  const m = a.match(/^--([\w-]+)(?:=(.*))?$/);
  if (m) args.set(m[1], m[2] ?? 'true');
}

const EXPECTED_CARDS = 30;
const EXPECTED_SPREAD: Record<string, number> = { F: 10, E: 9, D: 7, C: 4 };
const TIMINGS = ['on_summon', 'activated', 'triggered', 'counter'];
const KEYWORDS = ['taunt', 'charge', 'shield', 'stealth'];
const FAMILIES = [
  'athlete', 'musician', 'artist', 'scientist', 'comedian',
  'influencer', 'politician', 'business', 'gamer', 'actor',
];

interface Chit {
  id: string;
  name: string;
  archetype_family: Family;
  chit_type: string;
  tier: string;
  timing_type: string | null;
  keywords: string[];
  aura_cost: number;
  atk: number | null;
  hp: number | null;
  card_art_url: string | null;
  mp4_cutscene_url: string | null;
  is_generic: boolean;
  is_starter: boolean;
  seed_source: string | null;
  moment_id: string | null;
}

let failures = 0;
function check(cond: unknown, msg: string) {
  if (cond) {
    console.log(`  ✓ ${msg}`);
  } else {
    console.error(`  ✗ ${msg}`);
    failures++;
  }
}

async function loadPlayset(): Promise<Chit[]> {
  const { data, error } = await db.from('moment_chits')
    .select('id,name,archetype_family,chit_type,tier,timing_type,keywords,aura_cost,atk,hp,' +
            'card_art_url,mp4_cutscene_url,is_generic,is_starter,seed_source,moment_id')
    .eq('is_starter', true).eq('is_active', true).order('archetype_family').order('tier');
  if (error) throw new Error(`playset read failed: ${error.message}`);
  return (data ?? []) as unknown as Chit[];
}

// ── verify: the coverage contract from spec §1.2 ────────────────────────────────
async function verify(cards: Chit[]): Promise<void> {
  console.log(`\nStandard Playset — coverage contract (${cards.length} cards)\n`);

  check(cards.length === EXPECTED_CARDS, `30 starter cards live (got ${cards.length})`);

  const spread: Record<string, number> = {};
  for (const c of cards) spread[c.tier] = (spread[c.tier] ?? 0) + 1;
  const spreadStr = Object.entries(spread).sort().map(([t, n]) => `${t}:${n}`).join(' ');
  const spreadOk = Object.entries(EXPECTED_SPREAD).every(([t, n]) => spread[t] === n)
    && Object.keys(spread).length === Object.keys(EXPECTED_SPREAD).length;
  check(spreadOk, `tier spread F10/E9/D7/C4 (got ${spreadStr})`);

  check(!cards.some((c) => ['A', 'S', 'B'].includes(c.tier)), 'no A/S (or B) starters — economy guard');

  check(cards.every((c) => c.is_generic && c.seed_source === 'platform'),
    'every card is generic + platform-seeded (never listable/tradeable)');

  const fams = new Map<string, Chit[]>();
  for (const c of cards) fams.set(c.archetype_family, [...(fams.get(c.archetype_family) ?? []), c]);
  check(fams.size === 10, `all 10 archetype families represented (got ${fams.size})`);
  const shapeOk = [...fams.values()].every((f) =>
    f.length === 3 && f.filter((c) => c.chit_type === 'creature').length === 2
                   && f.filter((c) => c.chit_type === 'spell_moment').length === 1);
  check(shapeOk, 'every family is 2 creatures + 1 spell-moment');

  for (const t of TIMINGS) {
    check(cards.some((c) => c.timing_type === t), `timing type "${t}" covered`);
  }
  for (const k of KEYWORDS) {
    check(cards.some((c) => (c.keywords ?? []).includes(k)), `keyword "${k}" covered`);
  }

  // fusion must be DISCOVERABLE with starters alone
  const { data: rules } = await db.from('fusion_rules')
    .select('key,match_family,match_keyword,min_count').eq('is_active', true);
  for (const r of rules ?? []) {
    const n = cards.filter((c) => c.chit_type === 'creature'
      && (!r.match_family || c.archetype_family === r.match_family)
      && (!r.match_keyword || (c.keywords ?? []).includes(r.match_keyword))).length;
    check(n >= (r.min_count ?? 2),
      `fusion rule ${r.key} discoverable with starters (${n}/${r.min_count} creatures)`);
  }

  // a legal 20-card deck needs >= 10 uniques; 30 gives real deckbuilding choice
  check(cards.length >= 10, 'a legal 20-card starter-only deck is buildable (>=10 uniques)');

  // grant health. The receipt is per (account, card), so row count is not a headcount —
  // ask the DB how many real accounts hold the COMPLETE set.
  const { data: cov } = await db.rpc('starter_playset_coverage');
  const c = (cov ?? {}) as Record<string, number>;
  check((c.fully_granted ?? 0) >= (c.accounts ?? 0),
    `every non-test account holds the full playset ` +
    `(${c.fully_granted ?? 0}/${c.accounts ?? 0} accounts, ${c.card_grants ?? 0} card grants)`);
  if ((c.fully_granted ?? 0) < (c.accounts ?? 0)) {
    console.error('      → run claim_starter_playset() per account, or re-run ' +
      'grant_starter_playset(<uuid>) — it tops up only what is missing');
  }

  // media state is reported, never asserted — sim placeholders are a legal state
  const withArt = cards.filter((c) => c.card_art_url).length;
  const withMp4 = cards.filter((c) => c.mp4_cutscene_url).length;
  console.log(`\n  media: ${withArt}/${cards.length} card art · ${withMp4}/${cards.length} cutscene ` +
    `(placeholders are a legal pre-launch state — P6 pattern)`);

  console.log(`\nG-IP: every card is a Lane-A original format brief. Any card naming or ` +
    `depicting a real person must go through the lkn_* licensing rail or be cut.\n`);
}

function report(cards: Chit[]): void {
  console.log('\n  tier  type          family      name                        cost/atk/hp  keywords            media');
  console.log('  ' + '-'.repeat(112));
  for (const c of cards) {
    const stats = c.chit_type === 'creature' ? `${c.aura_cost}/${c.atk}/${c.hp}` : `${c.aura_cost}/–/–`;
    const media = [c.card_art_url ? 'art' : '—', c.mp4_cutscene_url ? 'mp4' : '—'].join('+');
    console.log(`  ${c.tier.padEnd(5)} ${c.chit_type.padEnd(13)} ${c.archetype_family.padEnd(11)} ` +
      `${c.name.padEnd(27)} ${stats.padEnd(12)} ${(c.keywords ?? []).join(',').padEnd(19)} ${media}`);
  }
  console.log('');
}

// ── add: author one more base card for launch ──────────────────────────────────
// Everything that decides POWER stays server-side: --tier only chooses which
// engagement band the platform moment sits in, and tier_for_engagement + the tier
// ladder do the rest (Hard Rule 34). There is deliberately no --atk/--hp/--cost.
async function addCard(): Promise<void> {
  const name = args.get('add')!;
  const family = args.get('family') ?? '';
  const type = args.get('type') ?? 'creature';
  const tier = (args.get('tier') ?? 'F').toUpperCase();
  const effectKey = args.get('effect') ?? '';
  const keywords = (args.get('keywords') ?? '').split(',').map((k) => k.trim()).filter(Boolean);

  if (!FAMILIES.includes(family)) {
    console.error(`--family must be one of: ${FAMILIES.join(', ')}`);
    Deno.exit(1);
  }
  if (type !== 'creature' && type !== 'spell_moment') {
    console.error('--type must be creature or spell_moment');
    Deno.exit(1);
  }
  if (!['F', 'E', 'D', 'C'].includes(tier)) {
    console.error('--tier must be F, E, D or C — starters never reach A/S (economy guard)');
    Deno.exit(1);
  }

  // The effect must belong to the card's family: the DB refuses a mismatch, but a
  // clear list here beats a raw constraint error.
  const { data: templates } = await db.from('effect_templates')
    .select('id,key,name,timing_type').eq('archetype_family', family)
    .eq('is_active', true).eq('is_fusion', false);
  const tmpl = (templates ?? []).find((t) => t.key === effectKey);
  if (!tmpl) {
    console.error(`--effect must be one of ${family}'s authored templates:`);
    for (const t of templates ?? []) console.error(`    ${t.key}  (${t.name}, ${t.timing_type})`);
    Deno.exit(1);
  }

  const slug = 'playset:' + name.toLowerCase().replace(/[^a-z0-9]+/g, '-');
  const { data: momentId, error: mErr } = await db.rpc('admin_seed_moment', {
    p_slug: slug, p_target_tier: tier, p_thumbnail_url: null, p_post_title: name,
  });
  if (mErr) {
    console.error(`seed moment failed: ${mErr.message}`);
    Deno.exit(1);
  }

  // Platform content is not exempt from moderation — record the verdict, then mint.
  const { error: modErr } = await db.rpc('moment_pre_gen_moderate', {
    p_moment_id: momentId,
    p_verdict: 'approved',
    p_labels: { lane: 'A_original_format', brief: name, real_person: false },
    p_third_party: false,
    p_model: 'sim',
  });
  if (modErr) {
    console.error(`moderation record failed: ${modErr.message}`);
    Deno.exit(1);
  }

  const { data: chitId, error: cErr } = await db.rpc('admin_seed_chit', {
    p_moment_id: momentId,
    p_name: name,
    p_family: family,
    p_chit_type: type,
    p_effect_template_id: tmpl.id,
    p_keywords: keywords,
    p_description: args.get('flavor') ?? null,
    p_vibe_gate: null,
    p_is_starter: true,
    p_card_art_url: null,
  });
  if (cErr) {
    console.error(`mint failed: ${cErr.message}`);
    Deno.exit(1);
  }

  const { data: row } = await db.from('moment_chits')
    .select('name,tier,aura_cost,atk,hp,keywords,timing_type').eq('id', chitId).single();
  const r = row as Record<string, unknown>;
  console.log(`\n✓ minted ${r.name} — tier ${r.tier}, cost ${r.aura_cost}` +
    (type === 'creature' ? `, ${r.atk}/${r.hp}` : '') +
    `, ${tmpl.name} (${r.timing_type})` +
    ((r.keywords as string[])?.length ? `, keywords: ${(r.keywords as string[]).join(',')}` : ''));
  console.log(`  chit id: ${chitId}   (art: none yet — --render-art or --attach)`);

  if (args.has('no-grant')) {
    console.log('\n  --no-grant: nobody holds it yet. Grant it with a re-run without the flag.\n');
    return;
  }

  // Hand it to everyone. The grant is idempotent per card, so this only ever adds
  // the new card — it never re-grants anything an account already has.
  const { data: profiles } = await db.from('profiles').select('id').eq('is_test_account', false);
  let touched = 0;
  for (const p of (profiles ?? []) as { id: string }[]) {
    const { data: res } = await db.rpc('grant_starter_playset', { p_user: p.id });
    if (((res as Record<string, number>)?.cards ?? 0) > 0) touched++;
  }
  console.log(`  granted to ${touched} account(s); new signups get it automatically.\n`);
}

// ── render-art: PAID drafts, human review still required before they ship ───────
async function renderArt(cards: Chit[]): Promise<void> {
  const cfg = cinematicConfigFromEnv();
  if (cfg.mode !== 'live') {
    console.error('--render-art needs CINEMATIC_MODE=live (sim renders would just re-stub placeholders)');
    Deno.exit(1);
  }
  if (!cfg.apiKey) {
    console.error('--render-art needs SEGMIND_API_KEY');
    Deno.exit(1);
  }
  if (!args.has('confirm-spend')) {
    console.error('--render-art spends real Segmind budget. Re-run with --confirm-spend.');
    Deno.exit(1);
  }
  const limit = Number(args.get('limit') ?? '5');
  const todo = cards.filter((c) => !c.card_art_url).slice(0, limit);
  console.log(`\nrendering card art for ${todo.length} card(s) (limit ${limit}) — drafts, not published\n`);

  for (const c of todo) {
    const prompt = illustrationPrompt(c.name, c.archetype_family);
    const res = await generateIllustration(cfg, { prompt });
    if (!res.ok) {
      console.error(`  ✗ ${c.name}: ${res.reason}${res.detail ? ` — ${res.detail}` : ''}`);
      continue;
    }
    const path = `playset/art/${c.id}-${res.seed}.png`;
    const { error: upErr } = await db.storage.from('battle-media')
      .upload(path, res.bytes, { contentType: res.contentType, upsert: true });
    if (upErr) {
      console.error(`  ✗ ${c.name}: upload failed — ${upErr.message}`);
      continue;
    }
    const { data: pub } = db.storage.from('battle-media').getPublicUrl(path);
    console.log(`  ✓ ${c.name} → ${pub.publicUrl}`);
    console.log(`    REVIEW IT, then publish with:`);
    console.log(`      --attach="${c.name}" --art=${pub.publicUrl} --verdict=approved`);
  }
  console.log('\nNothing was published. A human decides what ships (anti-slop gate, §0.5).\n');
}

// ── attach: the only path from a reviewed render to a live card ─────────────────
async function attach(cards: Chit[]): Promise<void> {
  const nameArg = args.get('attach')!;
  const card = cards.find((c) => c.name.toLowerCase() === nameArg.toLowerCase() || c.id === nameArg);
  if (!card) {
    console.error(`no starter card matches "${nameArg}"`);
    Deno.exit(1);
  }
  const verdict = args.get('verdict') ?? '';
  const mp4 = args.get('mp4') ?? null;
  const art = args.get('art') ?? null;
  if (verdict !== 'approved') {
    console.error('--verdict=approved required: post-generation moderation is mandatory (Hard Rule 39) ' +
      'and this flag records that a human ran it.');
    Deno.exit(1);
  }
  if (!mp4 && !art) {
    console.error('nothing to attach: pass --mp4=<battle-media url> and/or --art=<battle-media url>');
    Deno.exit(1);
  }

  // The RPC enforces battle-media + an approved verdict on whichever leg is
  // supplied. A null mp4 leaves the existing cutscene alone (art-only attach is
  // the normal first step — card art lands long before any cutscene).
  const { error } = await db.rpc('admin_seed_attach_media', {
    p_chit_id: card.id,
    p_mp4_url: mp4,
    p_verdict: verdict,
    p_card_art_url: art,
    p_template_id: args.get('template') ?? null,
    p_seed: args.has('seed') ? Number(args.get('seed')) : null,
  });
  if (error) {
    console.error(`attach failed: ${error.message}`);
    Deno.exit(1);
  }
  console.log(`✓ ${card.name}: media attached (mp4=${mp4 ?? 'unchanged'}, art=${art ?? 'unchanged'})`);
}

const cards = await loadPlayset();
if (cards.length === 0) {
  console.error('No starter cards found — apply migrations 181 + 182 first.');
  Deno.exit(1);
}

if (args.has('add')) {
  await addCard();
} else if (args.has('attach')) {
  await attach(cards);
} else if (args.has('render-art')) {
  await renderArt(cards);
} else {
  await verify(cards);
  if (args.has('report')) report(cards);
  if (failures > 0) {
    console.error(`\n${failures} coverage check(s) FAILED\n`);
    Deno.exit(1);
  }
  console.log('Standard Playset: coverage contract holds.\n');
}
