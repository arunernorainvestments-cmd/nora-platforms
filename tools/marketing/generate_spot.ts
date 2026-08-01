// tools/marketing/generate_spot.ts — marketing spot generation (Playset spec PHASE S3).
//
// Reuses the SAME cinematic client the mint pipeline uses (supabase/functions/_shared/
// segmind.ts) so marketing assets carry the house cel-shaded identity rather than a second
// look — but writes to its own ledger (marketing_generations, mig 183) so marketing spend
// is never mixed into mint spend (REPO-CHECK S3.1).
//
// The pipeline is deliberately three separate commands, because the middle one is a human:
//
//   1. list                      what the slate holds, and where each spot stands
//   2. --render=<key>            generate one spot's asset (sim by default; live is
//                                budget-capped in the DB and needs --confirm-spend)
//   3. --approve=<gen id> --reviewer="name"     the anti-slop gate (§0.5, hard gate)
//      --publish=<key>           refuses unless an approved, human-signed render exists
//
// Nothing here can publish an unreviewed render: marketing_spot_publish RAISEs, by design.
//
// Run:
//   SUPABASE_URL=… SERVICE_KEY=… deno run --allow-net --allow-env tools/marketing/generate_spot.ts
//   … --render=transformation-hero
//   CINEMATIC_MODE=live SEGMIND_API_KEY=… … --render=transformation-hero --confirm-spend
//   … --approve=<generation-id> --reviewer="Aruner" [--note="..."]
//   … --reject=<generation-id> --reviewer="Aruner" --note="reads like slop"
//   … --publish=transformation-hero

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {
  cinematicConfigFromEnv,
  generateIllustration,
  generateCutscene,
} from '../../supabase/functions/_shared/segmind.ts';

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

// Per-render cost estimates, in integer cents (money is never floating point).
// Calibrate from tools/cinematic/trial_*.ts micro-trials before raising the cap
// (spec §4 Q12) — these are the numbers the budget guard counts against.
const COST_CENTS: Record<string, number> = { fast: 25, standard: 120 };

interface Spot {
  id: string;
  key: string;
  title: string;
  format: string;
  aspect: string;
  duration_s: number;
  hook: string | null;
  cta: string | null;
  description: string | null;
  channels: string[];
  scheduled_for: string | null;
  status: string;
  chit_id: string | null;
}

async function spots(): Promise<Spot[]> {
  const { data, error } = await db.from('marketing_spots')
    .select('id,key,title,format,aspect,duration_s,hook,cta,description,channels,scheduled_for,status,chit_id')
    .order('format');
  if (error) throw new Error(`spot read failed: ${error.message}`);
  return (data ?? []) as unknown as Spot[];
}

async function list(): Promise<void> {
  const all = await spots();
  const { data: spend } = await db.rpc('marketing_spend_summary');
  console.log('\nMarketing slate\n');
  for (const s of all) {
    const { data: gens } = await db.from('marketing_generations')
      .select('id,attempt,mode,status,reviewed_by,cost_cents')
      .eq('spot_id', s.id).order('attempt', { ascending: false });
    const latest = (gens ?? [])[0];
    console.log(`  ${s.key.padEnd(22)} ${s.status.padEnd(11)} ${s.aspect} ${String(s.duration_s).padStart(2)}s  ` +
      `${(s.channels ?? []).join(',')}`);
    console.log(`    "${s.hook ?? ''}"`);
    if (latest) {
      console.log(`    latest render: ${latest.id} (attempt ${latest.attempt}, ${latest.mode}, ` +
        `${latest.status}${latest.reviewed_by ? ` by ${latest.reviewed_by}` : ''})`);
    } else {
      console.log('    latest render: none');
    }
    if (s.scheduled_for) console.log(`    scheduled: ${s.scheduled_for}`);
  }
  console.log(`\n  budget: ${JSON.stringify(spend)}\n`);
  console.log('  Nothing publishes without a named human approval (anti-slop hard gate).\n');
}

// The spot prompt: house style-lock is inherited from the shared client's grammar;
// only the subject/beat text varies per spot. Never user-influenced (Hard Rule 39).
function spotPrompt(s: Spot): string {
  return [
    `NORA marketing spot — ${s.title}.`,
    s.description ?? '',
    s.hook ? `On-screen beat: "${s.hook}"` : '',
    s.cta ? `Closing card: "${s.cta}"` : '',
    `Format: ${s.aspect} vertical, ${s.duration_s}s, house cel-shaded style, crafted and`,
    'deliberate — no generic AI-stock look. Original characters and settings only:',
    'no real people, no third-party characters, no existing branding or game footage.',
  ].filter(Boolean).join('\n');
}

async function render(key: string): Promise<void> {
  const all = await spots();
  const spot = all.find((s) => s.key === key);
  if (!spot) {
    console.error(`no marketing spot with key "${key}" (run without args to list)`);
    Deno.exit(1);
  }

  const cfg = cinematicConfigFromEnv();
  if (cfg.mode === 'live' && !args.has('confirm-spend')) {
    console.error('CINEMATIC_MODE=live spends real budget. Re-run with --confirm-spend.');
    Deno.exit(1);
  }
  const prompt = spotPrompt(spot);
  const cost = cfg.mode === 'live' ? (COST_CENTS[cfg.renderTier] ?? 0) : 0;

  console.log(`\nrendering "${spot.key}" (${cfg.mode}/${cfg.renderTier})\n`);
  console.log(prompt.split('\n').map((l) => `  ${l}`).join('\n'));

  // A spot is a short film, not a card cutscene: no anchor plates, no match-cut seam.
  // Still-first spots (starter reveals) use the image model; motion spots use the
  // video model with the still as its opening frame.
  const still = await generateIllustration(cfg, { prompt, width: 1080, height: 1920 });
  if (!still.ok) {
    console.error(`\n✗ still failed: ${still.reason}${still.detail ? ` — ${still.detail}` : ''}`);
    Deno.exit(1);
  }
  const stillPath = `marketing/${spot.key}/still-${still.seed}.png`;
  const upStill = await db.storage.from('battle-media')
    .upload(stillPath, still.bytes, { contentType: still.contentType, upsert: true });
  if (upStill.error) {
    console.error(`✗ still upload failed: ${upStill.error.message}`);
    Deno.exit(1);
  }
  const { data: stillPub } = db.storage.from('battle-media').getPublicUrl(stillPath);

  let assetPath = stillPath;
  let model = cfg.imageModel;
  let seed = still.seed;

  if (!args.has('still-only')) {
    const clip = await generateCutscene(cfg, {
      prompt,
      firstFrameUrl: stillPub.publicUrl,
      durationS: spot.duration_s,
      seed: still.seed,
    });
    if (!clip.ok) {
      console.warn(`\n! motion pass failed (${clip.reason}) — keeping the still as the asset`);
    } else {
      assetPath = `marketing/${spot.key}/spot-${clip.seed}.mp4`;
      const upClip = await db.storage.from('battle-media')
        .upload(assetPath, clip.bytes, { contentType: clip.contentType, upsert: true });
      if (upClip.error) {
        console.error(`✗ spot upload failed: ${upClip.error.message}`);
        Deno.exit(1);
      }
      model = clip.model;
      seed = clip.seed;
    }
  }

  const { data: genId, error } = await db.rpc('marketing_generation_record', {
    p_spot_id: spot.id,
    p_model: model,
    p_mode: cfg.mode,
    p_render_tier: cfg.renderTier,
    p_seed: seed,
    p_prompt: prompt,
    p_asset_path: assetPath,
    p_cost_cents: cost,
  });
  if (error) {
    console.error(`\n✗ ledger write refused: ${error.message}`);
    Deno.exit(1);
  }

  const { data: pub } = db.storage.from('battle-media').getPublicUrl(assetPath);
  console.log(`\n✓ rendered → ${pub.publicUrl}`);
  console.log(`  generation: ${genId}`);
  console.log(`\n  WATCH IT, then:`);
  console.log(`    --approve=${genId} --reviewer="your name"     (or --reject=… --note="why")`);
  console.log(`    --publish=${spot.key}\n`);
}

async function verdict(genId: string, approved: boolean): Promise<void> {
  const reviewer = args.get('reviewer') ?? '';
  if (!reviewer.trim()) {
    console.error('--reviewer="your name" required: a human owns this decision (§4 Q13)');
    Deno.exit(1);
  }
  const { error } = await db.rpc('marketing_generation_verdict', {
    p_generation_id: genId, p_approved: approved, p_reviewer: reviewer, p_note: args.get('note') ?? null,
  });
  if (error) {
    console.error(`verdict failed: ${error.message}`);
    Deno.exit(1);
  }
  console.log(`✓ generation ${genId} ${approved ? 'APPROVED' : 'rejected'} by ${reviewer}`);
}

async function publish(key: string): Promise<void> {
  const spot = (await spots()).find((s) => s.key === key);
  if (!spot) {
    console.error(`no marketing spot with key "${key}"`);
    Deno.exit(1);
  }
  const { error } = await db.rpc('marketing_spot_publish', { p_spot_id: spot.id });
  if (error) {
    console.error(`publish refused: ${error.message}`);
    Deno.exit(1);
  }
  console.log(`✓ "${key}" marked published — post it to ${(spot.channels ?? []).join(', ')}`);
}

if (args.has('render')) {
  await render(args.get('render')!);
} else if (args.has('approve')) {
  await verdict(args.get('approve')!, true);
} else if (args.has('reject')) {
  await verdict(args.get('reject')!, false);
} else if (args.has('publish')) {
  await publish(args.get('publish')!);
} else {
  await list();
}
