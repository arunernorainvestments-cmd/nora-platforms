// tools/cinematic/generate_anchor_plates.ts
// C1 — generate the ~12 anchor plates (start + end per Match Cut template) at 16:9
// in the house cel-shaded style, upload them to battle-media, and record the URLs on
// the versioned registry rows. Plates stay status='draft' — a HUMAN flips them to
// 'signed_off' after visual approval against the Arena anchor poses (the C1 gate).
//
// Run (from repo root):
//   SUPABASE_URL=https://cceisywxwhgljdpisjrl.supabase.co \
//   SUPABASE_SERVICE_ROLE_KEY=... \
//   CINEMATIC_MODE=live SEGMIND_API_KEY=... \
//   deno run --allow-net --allow-env tools/cinematic/generate_anchor_plates.ts
//
// CINEMATIC_MODE=sim dry-runs the whole flow with placeholder bytes (no key needed).
// Re-runs are safe: rows that already have both URLs are skipped unless FORCE=1.

import {
  cinematicConfigFromEnv,
  generateIllustration,
} from '../../supabase/functions/_shared/segmind.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
const PLATE_VERSION = Number(Deno.env.get('PLATE_VERSION') ?? '1');
const FORCE = Deno.env.get('FORCE') === '1';
if (!SUPABASE_URL || !SERVICE_KEY) {
  console.error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required');
  Deno.exit(1);
}

// The fixed plate look. Plates are the SEAM: neutral, empty of subjects, matching the
// framing Unity's anchor camera holds. The generated middle inherits this style.
const PLATE_STYLE =
  'cel-shaded anime game arena, bold ink outlines, flat shadows, house palette with ' +
  '#6C63FF and #03DAC6 accent lighting, dark stage floor, 16:9 widescreen, ' +
  'no characters, no creatures, no text, no logos, no photographic realism';

function platePrompts(t: { id: string; entry_framing: string; exit_framing: string }) {
  // The exit framing text includes the "-> Unity …" handoff note; strip it for the image.
  const exit = t.exit_framing.split('->')[0].trim();
  return {
    start: `Empty stage plate, opening framing for a summon cutscene: ${t.entry_framing}. ${PLATE_STYLE}.`,
    end: `Empty stage plate, resolution framing for a summon cutscene: ${exit}, moment already settled, calm and static. ${PLATE_STYLE}.`,
  };
}

const rest = (path: string) => `${SUPABASE_URL}/rest/v1/${path}`;
const restHeaders = {
  apikey: SERVICE_KEY!,
  Authorization: `Bearer ${SERVICE_KEY}`,
  'Content-Type': 'application/json',
};

async function uploadPlate(objectPath: string, bytes: Uint8Array, contentType: string): Promise<string> {
  const res = await fetch(`${SUPABASE_URL}/storage/v1/object/battle-media/${objectPath}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': contentType,
      'x-upsert': 'true',
    },
    body: bytes as unknown as BodyInit,
  });
  if (!res.ok) throw new Error(`upload ${objectPath} failed: ${res.status} ${await res.text()}`);
  return `${SUPABASE_URL}/storage/v1/object/public/battle-media/${objectPath}`;
}

const cfg = cinematicConfigFromEnv();
console.log(`mode=${cfg.mode} tier=${cfg.renderTier} plateVersion=${PLATE_VERSION}`);

const tplRes = await fetch(
  rest(`match_cut_templates?is_active=eq.true&select=id,entry_framing,exit_framing`),
  { headers: restHeaders },
);
if (!tplRes.ok) throw new Error(`templates fetch failed: ${tplRes.status}`);
const templates: { id: string; entry_framing: string; exit_framing: string }[] = await tplRes.json();

const plateRes = await fetch(
  rest(`match_cut_anchor_plates?version=eq.${PLATE_VERSION}&select=template_id,start_plate_url,end_plate_url,status`),
  { headers: restHeaders },
);
if (!plateRes.ok) throw new Error(`plates fetch failed: ${plateRes.status}`);
const plateRows = new Map(
  ((await plateRes.json()) as { template_id: string; start_plate_url: string | null; end_plate_url: string | null; status: string }[])
    .map((r) => [r.template_id, r]),
);

let generated = 0, skipped = 0, failed = 0;
for (const t of templates) {
  const row = plateRows.get(t.id);
  if (!row) { console.warn(`SKIP ${t.id}: no v${PLATE_VERSION} registry row (run mig 139)`); skipped++; continue; }
  if (row.status === 'signed_off' && !FORCE) { console.log(`SKIP ${t.id}: already signed_off`); skipped++; continue; }
  if (row.start_plate_url && row.end_plate_url && !FORCE) { console.log(`SKIP ${t.id}: URLs present (FORCE=1 to redo)`); skipped++; continue; }

  const prompts = platePrompts(t);
  const urls: Record<string, string> = {};
  let ok = true;
  for (const side of ['start', 'end'] as const) {
    // Deterministic per-plate seed → stylistically stable re-runs.
    const gen = await generateIllustration(cfg, {
      prompt: prompts[side],
      width: 1920,
      height: 1080,
    });
    if (!gen.ok) {
      console.error(`FAIL ${t.id}/${side}: ${gen.reason} ${gen.detail ?? ''}`);
      ok = false;
      break;
    }
    const ext = gen.contentType.includes('png') ? 'png' : 'jpg';
    urls[side] = await uploadPlate(`plates/${t.id}/v${PLATE_VERSION}/${side}.${ext}`, gen.bytes, gen.contentType);
    console.log(`  ${t.id}/${side}: seed=${gen.seed} -> ${urls[side]}`);
  }
  if (!ok) { failed++; continue; }

  const upd = await fetch(
    rest(`match_cut_anchor_plates?template_id=eq.${t.id}&version=eq.${PLATE_VERSION}`),
    {
      method: 'PATCH',
      headers: restHeaders,
      body: JSON.stringify({
        start_plate_url: urls.start,
        end_plate_url: urls.end,
        notes: `generated ${new Date().toISOString()} (mode=${cfg.mode}); awaiting visual sign-off vs Arena anchor pose`,
      }),
    },
  );
  if (!upd.ok) throw new Error(`registry update ${t.id} failed: ${upd.status} ${await upd.text()}`);
  generated++;
}

console.log(`\ndone: ${generated} generated, ${skipped} skipped, ${failed} failed`);
console.log('NEXT (human): review each start/end pair against the Arena MatchCutAnchor poses,');
console.log("then flip approved rows: UPDATE match_cut_anchor_plates SET status='signed_off' WHERE …");
