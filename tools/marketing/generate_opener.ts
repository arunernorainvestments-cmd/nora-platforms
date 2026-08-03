// tools/marketing/generate_opener.ts — the "Mint Your Moment" cold open (draft 4).
//
// Draft 3 opened on 2.2s of RAW UNITY FOOTAGE of a card being thrown: blurry 3D, a dev
// menu at frame right, an @handle placeholder. The battle street two shots later — a
// Seedance render off the same game — was the best-looking frame in the film. Founder
// note: make the street shot the opener, and let ITS style and quality REINVENT the
// throw. So the throw is no longer footage; it is authored, in the street's own look,
// and given room to breathe (draft 3 gave the whole action 2.27s — it read as a glitch,
// not a beat).
//
// Two renders, one per master, each ~10s, both natively framed — a 9:16 centre-crop of
// a 16:9 throw would put the arc's apex off-frame, and the vertical cut is the primary
// channel (TikTok / Reels / Shorts), so it does not get the derived version.
//
// Reuses the mint pipeline's shared Segmind client verbatim (supabase/functions/
// _shared/segmind.ts) so the opener carries the house cel-shaded identity. Marketing
// imports that client; it never edits it.
//
//   SEGMIND_API_KEY=… SERVICE_KEY=… CINEMATIC_MODE=live \
//   deno run --allow-net --allow-env tools/marketing/generate_opener.ts --stills=9x16
//   … --motion=9x16 --confirm-spend
//   … --resume=<request-id> --aspect=9x16 --model=seedance-2.0 --seed=<n>
//
// Every artifact is parked in battle-media under marketing/promo-mint-your-moment/
// opener/ — a render is bought once, ever.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {
  cinematicConfigFromEnv,
  pollCutscene,
} from '../../supabase/functions/_shared/segmind.ts';

const url = (Deno.env.get('SUPABASE_URL') ?? 'https://cceisywxwhgljdpisjrl.supabase.co').replace(/\/$/, '');
const serviceKey = Deno.env.get('SERVICE_KEY') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
if (!serviceKey) {
  console.error('SERVICE_KEY (service role) required');
  Deno.exit(1);
}
const db = createClient(url, serviceKey, { auth: { persistSession: false } });
const BUCKET = 'battle-media';
const DIR = 'marketing/promo-mint-your-moment/opener';

const args = new Map<string, string>();
for (const a of Deno.args) {
  const m = a.match(/^--([\w-]+)(?:=(.*))?$/);
  if (m) args.set(m[1], m[2] ?? 'true');
}

type Aspect = '9x16' | '16x9';
const DIMS: Record<Aspect, { ratio: string; frame: string }> = {
  '9x16': { ratio: '9:16', frame: 'vertical 9:16' },
  '16x9': { ratio: '16:9', frame: 'widescreen 16:9' },
};

// Why this bypasses generateIllustration(): the shared client sends `image_urls` +
// `width`/`height`, and seedream-4 takes `image_input` + `size`/`aspect_ratio`. On the
// first pass that silently cost us both controls at once — the reference still was
// ignored (the model invented a different alley and a different rival) and every frame
// came back 2048x2048 square, which would have made a square opener. Marketing does not
// get to "fix" the mint client to suit itself (founder call 2026-08-02: the dependency
// runs one way), so the workaround lives here. Filed for the mint path separately.
async function segmindImage(
  cfg: ReturnType<typeof cinematicConfigFromEnv>,
  prompt: string, aspect: Aspect, referenceUrl: string | null, seed: number,
): Promise<{ bytes: Uint8Array; contentType: string; seed: number }> {
  const res = await fetch(`${cfg.baseUrl}/${cfg.imageModel}`, {
    method: 'POST',
    headers: { 'x-api-key': cfg.apiKey ?? '', 'Content-Type': 'application/json' },
    body: JSON.stringify({
      prompt,
      // A reference is a strong prior on COMPOSITION, not just style — passing the open
      // frame to the close frame produced a lightly-edited copy of it three passes
      // running, card still in the fighter's hand. The detonation frame is therefore
      // generated unreferenced, off the style lock alone; it is mostly light, so the
      // house look survives, and Seedance interpolates the street back in from frame one.
      ...(referenceUrl ? { image_input: [referenceUrl] } : {}),
      size: '2K',
      aspect_ratio: DIMS[aspect].ratio,
      max_images: 1,
      sequential_image_generation: 'disabled',
      seed,
    }),
  });
  if (!res.ok) {
    console.error(`✗ image ${res.status}: ${(await res.text()).slice(0, 400)}`);
    Deno.exit(1);
  }
  const ct = res.headers.get('content-type') ?? '';
  if (ct.includes('application/json')) {
    const payload = await res.json();
    const out = payload?.image_url ?? payload?.output_url ?? payload?.url ??
      (Array.isArray(payload?.images) ? payload.images[0]?.url ?? payload.images[0] : undefined);
    if (typeof out !== 'string') {
      console.error(`✗ no output url: ${JSON.stringify(payload).slice(0, 400)}`);
      Deno.exit(1);
    }
    const dl = await fetch(out);
    return { bytes: new Uint8Array(await dl.arrayBuffer()), contentType: dl.headers.get('content-type') ?? 'image/png', seed };
  }
  return { bytes: new Uint8Array(await res.arrayBuffer()), contentType: ct || 'image/png', seed };
}

// The source the whole promo's look comes from: the repaired gameplay still, both
// fighters in frame. Everything the opener generates is conditioned on it, so the new
// shot and the film it opens are the same street.
const STREET_SRC = `${url}/storage/v1/object/public/${BUCKET}/marketing/promo-mint-your-moment/src/gameplay-clean.jpg`;

// The house agnostic END plate (Hard Rule 39): the cyber impact flash that brackets the
// close of every minted cutscene. The opener lands on it deliberately — three passes of
// asking a text-to-image model for "card frozen dead centre inside a detonation" gave
// three different confused compositions, and the answer was already authored. Ending the
// cold open on the product's own seam is what makes the next cut (into the card's real
// cutscene) read as one continuous event instead of an edit. It is 16:9, so the vertical
// master gets a 9:16 restatement of it rather than a crop — an abstract radial flash is
// the one thing safe to regenerate, since there is no composition to lose.
const HOUSE_END_PLATE = `${url}/storage/v1/object/public/${BUCKET}/plates/agnostic/v1/end.png`;

// ── The style lock. Never varied between the two aspects, never softened: it is the
// only reason two independent renders read as one shot. The negative half matters as
// much as the positive — the source still is a game screenshot, so "no UI" has to be
// said loudly or the model paints the health bars back in.
const STYLE = [
  'STYLE: cel-shaded 2D anime, thick clean black line art, flat saturated colour with hard',
  'shadow edges, painted-background depth. Rain-soaked cyberpunk Tokyo backstreet at night:',
  'a ramen shop with glowing kanji neon, red paper lanterns, wet asphalt mirroring the signs,',
  'drifting steam, heavy rain streaks, volumetric light shafts. Palette locked to deep',
  'blue-black #0A0A0F, electric cyan-teal #03DAC6, violet #6C63FF and hot magenta neon.',
  'Cinematic anamorphic framing, shallow depth of field, film grain, lens bloom on the neon.',
  'CONSTRAINTS: absolutely NO user interface, NO health bars, NO name plates, NO @handles,',
  'NO menus or buttons, NO card tray, NO text, captions, subtitles, watermarks or logos',
  'anywhere in frame. Original armoured characters only — no real people, no recognisable',
  'existing characters, no third-party branding.',
].join(' ');

// The cast block is written as much to steer AWAY as toward. First pass, "crimson-and-
// steel armoured rival" came back as an unmistakable red-and-gold superhero suit —
// which fails the reviewer checklist's G-IP question before anyone even watches it. The
// rival is therefore specified by what it must NOT have. Faces stay hidden for the same
// reason: a clearly rendered face is a likeness question we do not need to open.
const CAST = [
  'CAST: near fighter — HELMETED figure in smooth teal-and-white plated armour with a',
  'featureless dark visor, no hair or face visible, seen from behind over the shoulder in',
  'the lower left of frame, cyan light-piping along the spine. Far fighter — a lean',
  'matte-crimson exo-frame across the wet street in the middle distance: smooth blank',
  'dark visor, angular shoulder fins, exposed cabling at the joints. The rival must NOT',
  'have a glowing chest disc, gold trim, a face-shaped mask, a cape, or any superhero',
  'iconography — it is industrial and anonymous. Both are original designs; neither face',
  'is ever visible.',
].join(' ');

// The card is a prop with a job (it has to read as THE product at 1/8 frame height and
// then survive being frozen dead centre), so it gets its own locked description.
const CARD = [
  'THE CARD: a single portrait-orientation trading card with rounded corners and a dark',
  'circuit-etched back, its edges burning with cyan light. It is the brightest object in',
  'every frame it appears in. Exactly one card — never a hand, spread or deck.',
].join(' ');

function stillPrompt(a: Aspect, which: 'open' | 'close'): string {
  const f = DIMS[a].frame;
  const beat = which === 'open'
    ? [
        `OPENING FRAME (${f}). Redraw the referenced game scene as a clean cinematic film`,
        'frame: same ramen-shop street, same standoff, every interface element deleted — no',
        'health bars, no name plates, no card tray along the bottom, no meter across the top.',
        'COMPOSITION: a third-person OVER-THE-SHOULDER shot from BEHIND the near fighter. The',
        'near fighter is large in the LOWER-LEFT foreground, back turned, head and shoulders',
        'cropped by the frame edge, facing away down the street. The rival stands SMALL in the',
        'middle distance, far down the wet street, facing back toward camera. Deep perspective',
        'along the street, low camera close to the wet ground. The near fighter holds the card',
        'edge-on between armoured fingers at hip height, arm drawn back and coiled to throw;',
        'the card is large and bright in the foreground, throwing a hard cyan reflection into',
        'the puddle below and rimming the armour in teal. Nothing is motion-blurred yet.',
      ].join(' ')
    : [
        `CLOSING FRAME (${f}). Restate the referenced impact plate in ${f} exactly as it is —`,
        'same artwork, same energy, only recomposed to the new frame shape. A brilliant',
        'cyan-white detonation core at the dead centre, blown out to pure white; radial',
        'shockwave streaks, arcing electric filaments and shattered dark fragments blasting',
        'outward through near-black space; heavy lens bloom and long horizontal anamorphic',
        'flares. Fills the whole frame edge to edge. Nothing else in shot — no street, no',
        'figures, no card, no text.',
      ].join(' ');
  // The close frame is pure light — handing it the street/cast blocks only invites the
  // model to paint a ramen shop back into an abstract flash. It gets the palette and the
  // no-text constraints, nothing more.
  const lock = which === 'open'
    ? `${STYLE}\n${CAST}\n${CARD}`
    : 'PALETTE: deep blue-black #0A0A0F, electric cyan-teal #03DAC6, violet #6C63FF, pure ' +
      'white core. Cel-shaded anime energy-effect rendering, hard-edged light, film grain. ' +
      'CONSTRAINTS: no text, captions, watermarks, logos, interface or figures of any kind.';
  return `${lock}\n${beat}`;
}

// The motion prompt is beat-timed on purpose. A ten-second render given one sentence
// spends the whole ten seconds drifting; given five timed beats it stages an action.
// The freeze at 6.5s is the load-bearing one — it is the frame the film cuts out of,
// into the card's own cutscene, so the card has to be still, upright and centred there.
function motionPrompt(a: Aspect): string {
  return [
    STYLE,
    CAST,
    CARD,
    'ACTION — one continuous 10-second shot, no cuts:',
    '0.0–2.0s  Hold wide and low. Rain falls hard, neon flickers, steam drifts across the',
    'street. The near fighter slowly raises the glowing card to shoulder height; its light',
    'sweeps across the wet asphalt and the rival braces.',
    '2.0–4.0s  The fighter snaps their whole body forward and HURLS the card. It leaves the',
    'hand as a streak of cyan light, trailing a wake that tears the rain apart. The camera',
    'whip-pans to follow it, motion blur smearing the neon into long horizontal bands.',
    '4.0–6.5s  Slow motion. The card tumbles end over end through the middle of the street,',
    'rain beading and flinging off its edges, reflected neon raking across its face. The',
    'camera arcs around it in a slow orbit, the ramen shop wheeling past behind.',
    '6.5–8.0s  The card SNAPS to a dead stop — upright, dead centre of frame, perfectly still,',
    'frozen in mid-air while everything around it keeps moving. Rings of energy race inward and',
    'gather on it, the street lights bend and stream toward it, the rain begins to fall upward.',
    '8.0–10.0s  Detonation. A spherical shockwave of cyan and violet light blows outward from',
    'the card, scattering the rain into sparks and blasting the steam back down the street.',
    'Both fighters are silhouetted against it. The core of the burst blooms out to pure white',
    'and fills the frame.',
    'CAMERA: one unbroken cinematic move — hold, whip-pan, slow orbit, settle, push in on the',
    'detonation. Deliberate and weighty throughout; never handheld or jittery.',
  ].join('\n');
}

function publicUrl(path: string): string {
  return db.storage.from(BUCKET).getPublicUrl(path).data.publicUrl;
}

async function upload(path: string, bytes: Uint8Array, contentType: string): Promise<string> {
  const { error } = await db.storage.from(BUCKET).upload(path, bytes, { contentType, upsert: true });
  if (error) {
    console.error(`✗ upload ${path} failed: ${error.message}`);
    Deno.exit(1);
  }
  return publicUrl(path);
}

// Bookends are cheap and are the only chance to reject a composition BEFORE paying for
// motion. Generate, look at them, then run --motion. Never fused into one command.
async function stills(a: Aspect): Promise<void> {
  const cfg = cinematicConfigFromEnv();
  // Fixed seeds: a bookend pair is iterated on prompt text, and a moving seed makes it
  // impossible to tell whether a change came from the words or the dice.
  const s0 = Number(args.get('seed') ?? 806746134);
  const rev = args.get('rev') ?? '';
  // --only=close re-rolls just the burst against an already-approved open frame. The
  // pair is iterated asymmetrically in practice (the establishing frame lands early,
  // the detonation takes three or four passes to centre), and re-buying a good frame
  // to fix a bad one is the cheapest mistake to stop making.
  const only = args.get('only') ?? '';
  const openPath = `${DIR}/${a}_open${rev}.png`;
  let openUrl = publicUrl(openPath);

  if (only !== 'close') {
    const open = await segmindImage(cfg, stillPrompt(a, 'open'), a, STREET_SRC, s0);
    openUrl = await upload(openPath, open.bytes, open.contentType);
    console.log(`open  (seed ${s0}) → ${openUrl}`);
  }
  if (only === 'open') return;

  // The close frame is conditioned on the HOUSE end plate, so the cold open resolves into
  // the same impact flash the product's own cutscenes are bracketed by (Hard Rule 39).
  const close = await segmindImage(cfg, stillPrompt(a, 'close'), a, HOUSE_END_PLATE, s0 + 1);
  console.log(`close (seed ${s0 + 1}) → ${await upload(`${DIR}/${a}_close${rev}.png`, close.bytes, close.contentType)}`);
  console.log('\nLOOK AT BOTH before --motion. The bookends are the shot.');
}

// Seedance's aspect_ratio DEFAULTS TO 16:9 and does not infer from the conditioning
// frames: the first vertical submit, anchored on a 1152x2048 first frame and a 1152x2048
// last frame, came back 1920x1080 landscape. The shared client never sends the field
// (the mint path is 16:9 by definition — Hard Rule 39 authors the plates at 16:9), so
// rather than widen a mint-critical function for a marketing need, the opener posts its
// own body. bitrate_mode=high goes with it: this is a master, not a draft.
async function submitMotion(
  cfg: ReturnType<typeof cinematicConfigFromEnv>, a: Aspect, rev: string, durationS: number,
): Promise<{ ok: true; requestId: string; seed: number; model: string } | { ok: false; reason: string; detail?: string }> {
  const model = cfg.seedanceStandardModel;
  const seed = Math.floor(Math.random() * 0x7fffffff);
  const body = {
    prompt: motionPrompt(a),
    first_frame_url: publicUrl(`${DIR}/${a}_open${rev}.png`),
    last_frame_url: publicUrl(`${DIR}/${a}_close${rev}.png`),
    aspect_ratio: DIMS[a].ratio,
    resolution: '1080p',
    bitrate_mode: 'high',
    duration: durationS,
    generate_audio: cfg.seedanceAudio,
    seed,
  };
  const res = await fetch(`${cfg.baseUrl.replace(/\/v1\/?$/, '/v2')}/${model}`, {
    method: 'POST',
    headers: { 'x-api-key': cfg.apiKey ?? '', 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) return { ok: false, reason: String(res.status), detail: (await res.text()).slice(0, 400) };
  const payload = await res.json();
  const requestId = payload?.request_id ?? payload?.id;
  if (typeof requestId !== 'string') return { ok: false, reason: 'provider_error', detail: JSON.stringify(payload).slice(0, 300) };
  return { ok: true, requestId, seed, model };
}

async function pollUntilDone(
  cfg: ReturnType<typeof cinematicConfigFromEnv>, requestId: string, model: string, seed: number,
) {
  const deadline = Date.now() + 20 * 60_000;
  let waited = 0;
  while (Date.now() < deadline) {
    const p = await pollCutscene(cfg, requestId, model, seed);
    if (p.done) return p.result;
    await new Promise((r) => setTimeout(r, 10_000));
    waited += 10;
    if (waited % 60 === 0) console.log(`  … still rendering (${waited}s)`);
  }
  return { ok: false as const, reason: 'provider_error' as const, detail: 'poll timed out at 20m (request id still resumable)' };
}

async function motion(a: Aspect): Promise<void> {
  const cfg = cinematicConfigFromEnv();
  if (cfg.mode === 'live' && !args.has('confirm-spend')) {
    console.error('CINEMATIC_MODE=live spends real budget. Re-run with --confirm-spend.');
    Deno.exit(1);
  }
  const rev = args.get('rev') ?? '';
  const sub = await submitMotion(cfg, a, rev, Number(args.get('duration') ?? 10));
  if (!sub.ok) {
    console.error(`✗ submit: ${sub.reason}${sub.detail ? ` — ${sub.detail}` : ''}`);
    Deno.exit(1);
  }
  // Printed BEFORE the first poll: a dropped terminal must never cost a second render.
  console.log(`submitted ${sub.requestId} (model ${sub.model}, seed ${sub.seed})`);
  console.log(`resume: --resume=${sub.requestId} --aspect=${a} --model=${sub.model} --seed=${sub.seed}`);
  const clip = await pollUntilDone(cfg, sub.requestId, sub.model, sub.seed);
  if (!clip.ok) {
    console.error(`✗ motion: ${clip.reason}${clip.detail ? ` — ${clip.detail}` : ''}`);
    Deno.exit(1);
  }
  console.log(`\n✓ ${await upload(`${DIR}/opener_${a}.mp4`, clip.bytes, 'video/mp4')}`);
}

async function resume(requestId: string): Promise<void> {
  const a = (args.get('aspect') ?? '9x16') as Aspect;
  const cfg = cinematicConfigFromEnv();
  const clip = await pollUntilDone(
    cfg, requestId, args.get('model') ?? cfg.seedanceStandardModel, Number(args.get('seed') ?? 0),
  );
  if (!clip.ok) {
    console.error(`✗ resume: ${clip.reason}${clip.detail ? ` — ${clip.detail}` : ''}`);
    Deno.exit(1);
  }
  console.log(`✓ ${await upload(`${DIR}/opener_${a}.mp4`, clip.bytes, 'video/mp4')}`);
}

if (args.has('stills')) await stills(args.get('stills') as Aspect);
else if (args.has('motion')) await motion(args.get('motion') as Aspect);
else if (args.has('resume')) await resume(args.get('resume')!);
else {
  console.log('usage: --stills=9x16|16x9 | --motion=9x16|16x9 --confirm-spend | --resume=<id> --aspect=…');
  console.log(`\nprompt preview (9x16 motion):\n\n${motionPrompt('9x16')}\n`);
}
