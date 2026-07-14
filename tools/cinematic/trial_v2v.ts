// tools/cinematic/trial_v2v.ts
// V2V provider MICRO-TRIAL (PLAN 2026-07-14 item 1c): restyle a real, already-attached
// + moderated clip through kling-o3-video2video-edit and/or runway-gen4-aleph via the
// dev-segmind-probe edge fn, and park each output in mint-staging/v2v-trials for
// review. The trial decides whether the V2V core replaces the Seedance clip-reference
// path (founder OK'd dropping ByteDance for the core).
//
// PAID: one provider render per submit. Dev tooling — removed at the pre-launch
// reset (ARCHIVE §A8) together with dev-segmind-probe.
//
// DEV_PROBE_SECRET=… [SUPABASE_URL=…] \
//   deno run --allow-net --allow-env tools/cinematic/trial_v2v.ts \
//     --moment=<moment id with clip_status=attached> \
//     [--provider=kling-o3|runway-aleph|both] (default both) \
//     [--prompt="override restyle prompt"] [--duration=5] [--keep-audio=false] \
//     [--aspect=16:9] [--tier=fast|standard]
//
// What each run answers (the PLAN's open questions):
//   * does the provider's INPUT moderation pass owned/self-shot real-face footage?
//     (submit-time or FAILED-status rejection = no)
//   * does the restyled core actually carry the source motion?
//   * kling: did keep_audio preserve the original soundtrack?
//   * does the card-art reference hold the character on-model?

const URL_ = (Deno.env.get('SUPABASE_URL') ?? 'https://cceisywxwhgljdpisjrl.supabase.co').replace(/\/$/, '');
const SECRET = Deno.env.get('DEV_PROBE_SECRET') ?? '';
if (!SECRET) { console.error('DEV_PROBE_SECRET required'); Deno.exit(1); }
const PROBE = `${URL_}/functions/v1/dev-segmind-probe`;

const args = new Map<string, string>();
for (const a of Deno.args) {
  const m = a.match(/^--([\w-]+)(?:=(.*))?$/);
  if (m) args.set(m[1], m[2] ?? 'true');
}
const momentId = args.get('moment');
if (!momentId) { console.error('--moment=<id> required'); Deno.exit(1); }
const providerArg = args.get('provider') ?? 'both';
const providers = providerArg === 'both' ? ['kling-o3', 'runway-aleph'] : [providerArg];

const headers: Record<string, string> = { 'X-Probe-Secret': SECRET, 'Content-Type': 'application/json' };
const anon = Deno.env.get('SUPABASE_ANON_KEY');
if (anon) { headers['apikey'] = anon; headers['Authorization'] = `Bearer ${anon}`; }

interface Submitted { provider: string; requestId: string; model: string; prompt: string }

async function submit(provider: string): Promise<Submitted | null> {
  const body: Record<string, unknown> = { v2v: provider, moment_id: momentId };
  if (args.has('prompt')) body.prompt_override = args.get('prompt');
  if (args.has('duration')) body.duration_s = Number(args.get('duration'));
  if (args.has('keep-audio')) body.keep_audio = args.get('keep-audio') === 'true';
  if (args.has('aspect')) body.aspect_ratio = args.get('aspect');
  if (args.has('tier')) body.tier = args.get('tier');
  const res = await fetch(PROBE, { method: 'POST', headers, body: JSON.stringify(body) });
  const payload = await res.json().catch(() => ({}));
  if (!res.ok || !payload.submitted) {
    console.error(`✗ ${provider} submit failed (HTTP ${res.status}):`, JSON.stringify(payload, null, 2));
    return null;
  }
  console.log(`→ ${provider} submitted: request ${payload.request_id} (model ${payload.model}, seed ${payload.seed})`);
  console.log(`  card_art_ref: ${payload.card_art_ref ?? 'none'} · keep_audio: ${payload.keep_audio}`);
  console.log(`  prompt:\n${String(payload.prompt).split('\n').map((l: string) => `    ${l}`).join('\n')}`);
  return { provider, requestId: payload.request_id, model: payload.model, prompt: payload.prompt };
}

async function pollAndStore(s: Submitted): Promise<void> {
  const deadline = Date.now() + 15 * 60 * 1000;
  while (Date.now() < deadline) {
    const res = await fetch(`${PROBE}?id=${s.requestId}&store=1&model=${encodeURIComponent(s.model)}`, { headers });
    const payload = await res.json().catch(() => ({}));
    if (payload.done === false) {
      await new Promise((r) => setTimeout(r, 15_000));
      continue;
    }
    if (payload.ok) {
      console.log(`✓ ${s.provider} COMPLETE — ${payload.bytes} bytes (${payload.content_type})`);
      console.log(`  stored: ${payload.stored_path}`);
      console.log(`  review (1h signed): ${payload.review_url}`);
    } else {
      console.error(`✗ ${s.provider} FAILED:`, JSON.stringify(payload, null, 2));
    }
    return;
  }
  console.error(`✗ ${s.provider} timed out after 15min (request ${s.requestId} — results retained 1h provider-side)`);
}

console.log(`V2V micro-trial · moment ${momentId} · providers: ${providers.join(', ')}`);
const submitted = (await Promise.all(providers.map(submit))).filter((s): s is Submitted => !!s);
if (submitted.length === 0) { console.error('nothing submitted'); Deno.exit(1); }
await Promise.all(submitted.map(pollAndStore));
console.log('\nTrial done. Judge: source motion present? real-face input accepted? audio? on-model vs card art?');
