// supabase/functions/_shared/segmind.ts
// Cinematic Engine — Segmind client (phase C0).
//
// One vendor/API key for the whole generation chain: stylized illustration (image
// model) + bracketed cutscene (Seedance 2.0, first/last-frame conditioned, seeded).
// Spec: NORA_PLATFORMS_CINEMATIC_ENGINE_SPEC.md §1/§3. Fallback provider (BytePlus
// ModelArk) would slot in behind the same interface.
//
// Sim-first per governance: CINEMATIC_MODE=sim (default) needs no key and returns
// deterministic placeholder assets so the whole pipeline (incl. battle-media upload)
// is exercisable end-to-end. Live mode requires SEGMIND_API_KEY.
//
// Invariants:
// - Results are returned as BYTES, never provider URLs — callers can only store them
//   into battle-media (Hard Rule 38: never hotlink a provider URL).
// - The seed used is always captured on the result (reproducible re-runs, Hard Rule 39).
// - HTTP 429 → { ok:false, reason:'rate_limited' }, logged, never thrown (Hard Rule 8).
// - The API key is never logged (Hard Rule 9).

export interface CinematicConfig {
  mode: 'sim' | 'live';
  renderTier: 'fast' | 'standard';       // fast = drafts/dev, standard = final renders
  apiKey: string | null;
  imageModel: string;                    // Segmind model slug for illustration/plates
  seedanceFastModel: string;             // Seedance 2.0 Fast slug
  seedanceStandardModel: string;         // Seedance 2.0 standard slug
  baseUrl: string;
}

export function cinematicConfigFromEnv(env: (k: string) => string | undefined = Deno.env.get.bind(Deno.env)): CinematicConfig {
  const mode = env('CINEMATIC_MODE') === 'live' ? 'live' : 'sim';
  const renderTier = env('CINEMATIC_RENDER_TIER') === 'standard' ? 'standard' : 'fast';
  return {
    mode,
    renderTier,
    apiKey: env('SEGMIND_API_KEY') ?? null,
    imageModel: env('SEGMIND_IMAGE_MODEL') ?? 'seedream-v4',
    seedanceFastModel: env('SEGMIND_SEEDANCE_FAST_MODEL') ?? 'seedance-2.0-fast',
    seedanceStandardModel: env('SEGMIND_SEEDANCE_MODEL') ?? 'seedance-2.0',
    baseUrl: env('SEGMIND_BASE_URL') ?? 'https://api.segmind.com/v1',
  };
}

export type GenFailureReason =
  | 'not_configured'      // live mode without an API key
  | 'invalid_request'     // missing bookends / empty prompt
  | 'rate_limited'        // HTTP 429 — log and skip (Hard Rule 8)
  | 'provider_moderation' // provider-side content refusal (bonus layer; ours is separate)
  | 'provider_error';

export type GenResult =
  | { ok: true; bytes: Uint8Array; contentType: string; seed: number; model: string; mode: 'sim' | 'live' }
  | { ok: false; reason: GenFailureReason; status?: number; detail?: string };

export interface IllustrationRequest {
  prompt: string;
  referenceImageUrl?: string;  // the post thumbnail (subject reference)
  seed?: number;
  width?: number;              // plates/cutscene frames are 16:9
  height?: number;
}

export interface CutsceneRequest {
  prompt: string;              // assembled from the motion prompt template (§4)
  firstFrameUrl: string;       // template start-plate — mandatory bookend
  lastFrameUrl: string;        // template end-plate — mandatory bookend
  referenceImageUrl?: string;  // the stylized illustration (subject reference)
  durationS: number;
  seed?: number;
  tierOverride?: 'fast' | 'standard';
}

// Deterministic 32-bit FNV-1a — sim-mode seed derivation so identical inputs
// reproduce identical results (mirrors the fixed-seed re-run contract).
function fnv1a(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

function pickSeed(explicit: number | undefined, promptForSim: string, mode: 'sim' | 'live'): number {
  if (explicit !== undefined && Number.isFinite(explicit)) return Math.floor(explicit);
  if (mode === 'sim') return fnv1a(promptForSim);
  return crypto.getRandomValues(new Uint32Array(1))[0];
}

// Minimal valid placeholder bytes (sim mode) — enough for storage round-trips.
const SIM_PNG = Uint8Array.from([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
  0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
]);
// 'ftyp' box only — a marker, not a playable video; sim mode is plumbing-only.
const SIM_MP4 = Uint8Array.from([
  0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d,
  0x00, 0x00, 0x02, 0x00, 0x69, 0x73, 0x6f, 0x6d,
]);

async function callSegmind(
  cfg: CinematicConfig, model: string, body: Record<string, unknown>,
): Promise<GenResult> {
  if (!cfg.apiKey) return { ok: false, reason: 'not_configured', detail: 'SEGMIND_API_KEY missing' };

  let res: Response;
  try {
    res = await fetch(`${cfg.baseUrl}/${model}`, {
      method: 'POST',
      headers: { 'x-api-key': cfg.apiKey, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
  } catch (e) {
    console.error(`segmind ${model}: network error`, (e as Error).message);
    return { ok: false, reason: 'provider_error', detail: (e as Error).message };
  }

  if (res.status === 429) {
    console.warn(`segmind ${model}: 429 rate-limited — skipping (Hard Rule 8)`);
    return { ok: false, reason: 'rate_limited', status: 429 };
  }
  if (res.status === 400 || res.status === 422) {
    const detail = (await res.text()).slice(0, 500);
    const reason: GenFailureReason = /nsfw|moderat|safety|policy/i.test(detail)
      ? 'provider_moderation' : 'invalid_request';
    return { ok: false, reason, status: res.status, detail };
  }
  if (!res.ok) {
    return { ok: false, reason: 'provider_error', status: res.status, detail: (await res.text()).slice(0, 500) };
  }

  const contentType = res.headers.get('content-type') ?? 'application/octet-stream';
  if (contentType.includes('application/json')) {
    // Some Segmind models return JSON with an output URL: download it so callers
    // only ever hold bytes (Hard Rule 38 — the provider URL must not escape).
    const payload = await res.json();
    const url = payload?.video?.url ?? payload?.output_url ?? payload?.url ?? payload?.image_url;
    if (typeof url !== 'string') {
      return { ok: false, reason: 'provider_error', detail: 'no output url in JSON response' };
    }
    const dl = await fetch(url);
    if (!dl.ok) return { ok: false, reason: 'provider_error', status: dl.status, detail: 'output download failed' };
    return {
      ok: true,
      bytes: new Uint8Array(await dl.arrayBuffer()),
      contentType: dl.headers.get('content-type') ?? 'application/octet-stream',
      seed: Number(body.seed),
      model,
      mode: 'live',
    };
  }
  return {
    ok: true,
    bytes: new Uint8Array(await res.arrayBuffer()),
    contentType,
    seed: Number(body.seed),
    model,
    mode: 'live',
  };
}

// ── Illustration (card art / plates): image model via Segmind ─────────────────────
export async function generateIllustration(cfg: CinematicConfig, req: IllustrationRequest): Promise<GenResult> {
  if (!req.prompt?.trim()) return { ok: false, reason: 'invalid_request', detail: 'empty prompt' };
  const seed = pickSeed(req.seed, `illustration:${req.prompt}`, cfg.mode);

  if (cfg.mode === 'sim') {
    return { ok: true, bytes: SIM_PNG, contentType: 'image/png', seed, model: 'sim-image', mode: 'sim' };
  }
  return await callSegmind(cfg, cfg.imageModel, {
    prompt: req.prompt,
    ...(req.referenceImageUrl ? { image_urls: [req.referenceImageUrl] } : {}),
    width: req.width ?? 1920,
    height: req.height ?? 1080,
    seed,
  });
}

// ── Cutscene (Seedance 2.0): bracketed by the anchor plates ───────────────────────
export async function generateCutscene(cfg: CinematicConfig, req: CutsceneRequest): Promise<GenResult> {
  if (!req.prompt?.trim()) return { ok: false, reason: 'invalid_request', detail: 'empty prompt' };
  // The engine's core mechanic: both bookends are mandatory, always.
  if (!req.firstFrameUrl || !req.lastFrameUrl) {
    return { ok: false, reason: 'invalid_request', detail: 'firstFrameUrl and lastFrameUrl (anchor plates) are required' };
  }
  const durationS = Math.min(15, Math.max(4, Math.round(req.durationS)));  // Seedance clip bounds
  const seed = pickSeed(req.seed, `cutscene:${req.prompt}:${req.firstFrameUrl}:${req.lastFrameUrl}`, cfg.mode);

  if (cfg.mode === 'sim') {
    return { ok: true, bytes: SIM_MP4, contentType: 'video/mp4', seed, model: 'sim-seedance', mode: 'sim' };
  }
  const tier = req.tierOverride ?? cfg.renderTier;
  const model = tier === 'standard' ? cfg.seedanceStandardModel : cfg.seedanceFastModel;
  return await callSegmind(cfg, model, {
    prompt: req.prompt,
    first_frame_url: req.firstFrameUrl,
    last_frame_url: req.lastFrameUrl,   // requires first — both always set here
    ...(req.referenceImageUrl ? { reference_image_url: req.referenceImageUrl } : {}),
    duration: durationS,
    resolution: tier === 'standard' ? '1080p' : '720p',
    seed,
  });
}
