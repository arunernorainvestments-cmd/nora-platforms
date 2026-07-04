// tools/cinematic/wire_agnostic_plates.ts
// Launch wiring for the TWO agnostic anchor plates (Hard Rule 39, amended 2026-07-04):
// start = the glowing BattleChit card, end = the cyber impact flash. Unlike the C1
// per-template plates (generate_anchor_plates.ts), launch ships ONE shared start/end
// pair that brackets EVERY match-cut, character- and template-agnostic — so all six
// match_cut_anchor_plates template rows point at the same two files.
//
// This uploads the two local PNGs to battle-media and repoints every template row of
// the given version at them. Idempotent (x-upsert + PATCH). Sign-off is a human gate
// (SIGN_OFF=1 default here because these plates are user-authored and approved; pass
// SIGN_OFF=0 to leave them 'draft').
//
// Run (from repo root):
//   SUPABASE_URL=https://cceisywxwhgljdpisjrl.supabase.co \
//   SUPABASE_SERVICE_ROLE_KEY=... \
//   deno run --allow-net --allow-env --allow-read tools/cinematic/wire_agnostic_plates.ts
//
// Optional env: PLATE_VERSION (default 1), SIGN_OFF (default 1),
//   START_FILE / END_FILE (default assets/plates/agnostic_{start,end}_plate_v1_16x9.png).

const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
const PLATE_VERSION = Number(Deno.env.get('PLATE_VERSION') ?? '1');
const SIGN_OFF = (Deno.env.get('SIGN_OFF') ?? '1') === '1';
const START_FILE = Deno.env.get('START_FILE') ?? 'assets/plates/agnostic_start_plate_v1_16x9.png';
const END_FILE = Deno.env.get('END_FILE') ?? 'assets/plates/agnostic_end_plate_v1_16x9.png';

if (!SUPABASE_URL || !SERVICE_KEY) {
  console.error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required');
  Deno.exit(1);
}

const START_PATH = `plates/agnostic/v${PLATE_VERSION}/start.png`;
const END_PATH = `plates/agnostic/v${PLATE_VERSION}/end.png`;

const rest = (path: string) => `${SUPABASE_URL}/rest/v1/${path}`;
const restHeaders = {
  apikey: SERVICE_KEY!,
  Authorization: `Bearer ${SERVICE_KEY}`,
  'Content-Type': 'application/json',
};

async function uploadPlate(objectPath: string, file: string): Promise<string> {
  const bytes = await Deno.readFile(file);
  const res = await fetch(`${SUPABASE_URL}/storage/v1/object/battle-media/${objectPath}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'image/png',
      'x-upsert': 'true',
    },
    body: bytes as unknown as BodyInit,
  });
  if (!res.ok) throw new Error(`upload ${objectPath} failed: ${res.status} ${await res.text()}`);
  const publicUrl = `${SUPABASE_URL}/storage/v1/object/public/battle-media/${objectPath}`;
  console.log(`  uploaded ${file} → ${objectPath} (${bytes.length} bytes)`);
  return publicUrl;
}

console.log(`Wiring agnostic plates v${PLATE_VERSION} (sign_off=${SIGN_OFF})`);
const startUrl = await uploadPlate(START_PATH, START_FILE);
const endUrl = await uploadPlate(END_PATH, END_FILE);

// Repoint every template row of this version at the shared pair.
const patch: Record<string, unknown> = {
  start_plate_url: startUrl,
  end_plate_url: endUrl,
};
if (SIGN_OFF) patch.status = 'signed_off';

const res = await fetch(
  rest(`match_cut_anchor_plates?version=eq.${PLATE_VERSION}`),
  {
    method: 'PATCH',
    headers: { ...restHeaders, Prefer: 'return=representation' },
    body: JSON.stringify(patch),
  },
);
if (!res.ok) throw new Error(`repoint failed: ${res.status} ${await res.text()}`);
const rows = await res.json() as { template_id: string; status: string }[];
console.log(`Repointed ${rows.length} template rows: ${rows.map((r) => r.template_id).join(', ')}`);
console.log(`Status: ${rows[0]?.status ?? '(none matched — check PLATE_VERSION)'}`);
console.log('Done. All templates now bracket with the two agnostic plates.');
