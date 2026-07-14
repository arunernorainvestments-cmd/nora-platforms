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

// The V2V core provider (PLAN 2026-07-14 item 1c — Track A collapsed to one call):
// restyle the user's trimmed clip into the cel-shaded core instead of riding it as a
// Seedance reference video. Unset → the Seedance clip-reference path, unchanged.
export type V2VProvider = 'kling-o3' | 'runway-aleph';

export interface CinematicConfig {
  mode: 'sim' | 'live';
  renderTier: 'fast' | 'standard';       // fast = drafts/dev, standard = final renders
  apiKey: string | null;
  imageModel: string;                    // Segmind model slug for illustration/plates
  seedanceFastModel: string;             // Seedance 2.0 Fast slug
  seedanceStandardModel: string;         // Seedance 2.0 standard slug
  seedanceAudio: boolean;                // generate_audio on Seedance calls (native SFX)
  skipProviderModeration: boolean;       // Seedance skip_moderation (provider filter only)
  v2vProvider: V2VProvider | null;       // null = Seedance clip-reference path
  klingV2VModel: string;                 // Kling O3 video2video-edit slug
  alephV2VModel: string;                 // Runway Gen-4 Aleph slug
  baseUrl: string;
}

export function cinematicConfigFromEnv(env: (k: string) => string | undefined = Deno.env.get.bind(Deno.env)): CinematicConfig {
  const mode = env('CINEMATIC_MODE') === 'live' ? 'live' : 'sim';
  const renderTier = env('CINEMATIC_RENDER_TIER') === 'standard' ? 'standard' : 'fast';
  const v2vRaw = env('CINEMATIC_V2V_PROVIDER') ?? '';
  return {
    mode,
    renderTier,
    apiKey: env('SEGMIND_API_KEY') ?? null,
    imageModel: env('SEGMIND_IMAGE_MODEL') ?? 'seedream-4',
    seedanceFastModel: env('SEGMIND_SEEDANCE_FAST_MODEL') ?? 'seedance-2.0-fast',
    seedanceStandardModel: env('SEGMIND_SEEDANCE_MODEL') ?? 'seedance-2.0',
    // Founder feedback 2026-07-14 item 2: cutscenes ship silent. Seedance supports
    // native audio co-generation (generate_audio, provider default false) — on unless
    // explicitly switched off.
    seedanceAudio: env('CINEMATIC_SEEDANCE_AUDIO') !== 'off',
    // Founder call 2026-07-14: the provider's INPUT filter (BytePlus) false-positives
    // on owned/consented footage (copyright/likeness) and blocks concept-proving.
    // Seedance documents skip_moderation to bypass it. This bypasses ONLY the
    // provider's bonus layer — NORA's own pre-gen + post-gen screens (minor-safety
    // absolute, Hard Rules 37/39) run regardless and are never skippable.
    skipProviderModeration: env('CINEMATIC_SKIP_PROVIDER_MODERATION') === 'true',
    v2vProvider: v2vRaw === 'kling-o3' || v2vRaw === 'runway-aleph' ? v2vRaw : null,
    klingV2VModel: env('SEGMIND_KLING_V2V_MODEL') ?? 'kling-o3-video2video-edit',
    alephV2VModel: env('SEGMIND_ALEPH_V2V_MODEL') ?? 'runway-gen4-aleph',
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
  | { ok: true; bytes: Uint8Array; contentType: string; seed: number; model: string; mode: 'sim' | 'live'; requestId?: string }
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
  firstFrameUrl: string;       // template start-plate — ALWAYS anchored (the card seam)
  // Template end-plate. Live-trial 2026-07-13: ByteDance rejects ANY reference
  // content (image/video/audio) combined with BOTH first and last frames — so when a
  // reference clip rides along, the caller omits the last frame and the prompt's
  // ENDING directive steers into the impact-flash whiteout instead (Unity's local
  // impact-flash particle covers that seam). No clip → both bookends, as always.
  lastFrameUrl?: string;
  // The user's moderated uploaded clip (signed mint-staging URL) — the old singular
  // reference_image_url spelling was silently dropped (2026-07-13 audit cause #4).
  referenceVideoUrls?: string[];
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
  // ByteDance (Seedream/Seedance) rejects seeds outside int32 — clamp every path to
  // [0, 2^31-1]. Also normalizes stored uint32 seeds from before this clamp existed.
  const raw = explicit !== undefined && Number.isFinite(explicit)
    ? Math.floor(explicit)
    : mode === 'sim'
      ? fnv1a(promptForSim)
      : crypto.getRandomValues(new Uint32Array(1))[0];
  return raw & 0x7fffffff;
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

  // Provider request id (audit item 6) — for support tickets / dashboard lookups.
  const requestId = res.headers.get('x-request-id') ?? res.headers.get('request-id') ?? undefined;

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
      requestId,
    };
  }
  return {
    ok: true,
    bytes: new Uint8Array(await res.arrayBuffer()),
    contentType,
    seed: Number(body.seed),
    model,
    mode: 'live',
    requestId,
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

// ── Async cutscene (Seedance 2.0 via Segmind v2): submit now, poll later ──────────
// Live V2V renders can outlive the edge-runtime wall clock, so the synchronous call
// (generateCutscene below) is only safe for sim mode. Live mode submits to the v2
// queue and polls; the request id is persisted by the caller so a killed worker can
// be resumed with zero re-spend (provider retains results for 1 hour).
function v2Base(cfg: CinematicConfig): string {
  return cfg.baseUrl.replace(/\/v1\/?$/, '/v2');
}

function cutsceneBody(cfg: CinematicConfig, req: CutsceneRequest, seed: number): Record<string, unknown> {
  // Probe 2026-07-13: ByteDance forbids reference media combined with ANY frame
  // anchor ("first/last frame content cannot be mixed with reference media content")
  // — the earlier "both frames" error text was misleading. Clip mode therefore sends
  // NO plates; the card-back opening and impact-flash ending live in the prompt's
  // constant [OPENING]/[ENDING] directives, and Unity's zoom-in + flash particles
  // cover both seams. No clip → both plate bookends, exactly as before.
  const withClip = !!req.referenceVideoUrls?.length;
  const tier = req.tierOverride ?? cfg.renderTier;
  return {
    prompt: req.prompt,
    ...(withClip
      ? { reference_videos: req.referenceVideoUrls!.slice(0, 3) }
      : {
          first_frame_url: req.firstFrameUrl,
          ...(req.lastFrameUrl ? { last_frame_url: req.lastFrameUrl } : {}),
        }),
    duration: Math.min(15, Math.max(4, Math.round(req.durationS))),
    resolution: tier === 'standard' ? '1080p' : '720p',
    // Native audio co-generation (SFX/ambient) — founder feedback item 2. The
    // provider default is false; NORA's default is on (CINEMATIC_SEEDANCE_AUDIO=off
    // to disable).
    generate_audio: cfg.seedanceAudio,
    // Bypass the provider's input/content filter only (documented Seedance param) —
    // NORA's own moderation stack still gates before and after (HR37/39).
    ...(cfg.skipProviderModeration ? { skip_moderation: true } : {}),
    seed,
  };
}

export type CutsceneSubmit =
  | { ok: true; requestId: string; seed: number; model: string }
  | { ok: false; reason: GenFailureReason; status?: number; detail?: string };

export async function submitCutscene(cfg: CinematicConfig, req: CutsceneRequest): Promise<CutsceneSubmit> {
  if (!cfg.apiKey) return { ok: false, reason: 'not_configured', detail: 'SEGMIND_API_KEY missing' };
  if (!req.prompt?.trim()) return { ok: false, reason: 'invalid_request', detail: 'empty prompt' };
  if (!req.firstFrameUrl || (!req.lastFrameUrl && !req.referenceVideoUrls?.length)) {
    return { ok: false, reason: 'invalid_request', detail: 'firstFrameUrl required; lastFrameUrl required without a reference clip' };
  }
  const tier = req.tierOverride ?? cfg.renderTier;
  const model = tier === 'standard' ? cfg.seedanceStandardModel : cfg.seedanceFastModel;
  const seed = pickSeed(req.seed, `cutscene:${req.prompt}:${req.firstFrameUrl}`, cfg.mode);

  let res: Response;
  try {
    res = await fetch(`${v2Base(cfg)}/${model}`, {
      method: 'POST',
      headers: { 'x-api-key': cfg.apiKey, 'Content-Type': 'application/json' },
      body: JSON.stringify(cutsceneBody(cfg, req, seed)),
    });
  } catch (e) {
    return { ok: false, reason: 'provider_error', detail: (e as Error).message };
  }
  if (res.status === 429) {
    console.warn(`segmind ${model} submit: 429 rate-limited — skipping (Hard Rule 8)`);
    await res.body?.cancel();
    return { ok: false, reason: 'rate_limited', status: 429 };
  }
  if (!res.ok) {
    const detail = (await res.text()).slice(0, 500);
    const reason: GenFailureReason = res.status === 400 || res.status === 422
      ? (/nsfw|moderat|safety|policy|sensitive/i.test(detail) ? 'provider_moderation' : 'invalid_request')
      : 'provider_error';
    return { ok: false, reason, status: res.status, detail };
  }
  try {
    const payload = await res.json();
    const requestId = payload?.request_id ?? payload?.id;
    if (typeof requestId !== 'string' || !requestId) {
      return { ok: false, reason: 'provider_error', detail: 'no request_id in async submit response' };
    }
    return { ok: true, requestId, seed, model };
  } catch {
    return { ok: false, reason: 'provider_error', detail: 'async submit response unparseable' };
  }
}

export type CutscenePoll =
  | { done: false }                      // queued / processing / transient poll error
  | { done: true; result: GenResult };   // terminal: bytes or a definite failure

export async function pollCutscene(cfg: CinematicConfig, requestId: string, model: string, seed: number): Promise<CutscenePoll> {
  if (!cfg.apiKey) return { done: true, result: { ok: false, reason: 'not_configured', detail: 'SEGMIND_API_KEY missing' } };

  let st: Response;
  try {
    st = await fetch(`${v2Base(cfg)}/requests/${requestId}/status`, { headers: { 'x-api-key': cfg.apiKey } });
  } catch {
    return { done: false };  // transient network error — keep polling
  }
  if (st.status === 429) { await st.body?.cancel(); return { done: false }; }
  if (st.status === 404) {
    await st.body?.cancel();
    return { done: true, result: { ok: false, reason: 'provider_error', status: 404, detail: 'async request expired or unknown' } };
  }
  // A FAILED request comes back as HTTP 422 with {"status":"FAILED","error":...} —
  // non-ok is NOT automatically transient; read the body before deciding.
  let statusPayload: Record<string, unknown>;
  try { statusPayload = await st.json(); } catch {
    return st.ok ? { done: false } : { done: false };
  }
  const state = String(statusPayload?.status ?? '').toUpperCase();
  if (!st.ok && (state === 'FAILED' || statusPayload?.error)) {
    const detail = JSON.stringify(statusPayload).slice(0, 500);
    const reason: GenFailureReason =
      /nsfw|moderat|safety|policy|sensitive|copyright/i.test(detail) ? 'provider_moderation'
      : /not valid|invalid/i.test(detail) ? 'invalid_request' : 'provider_error';
    return { done: true, result: { ok: false, reason, status: st.status, detail } };
  }
  if (!st.ok) return { done: false };
  if (state === 'QUEUED' || state === 'PROCESSING' || state === 'IN_PROGRESS' || state === 'PENDING') {
    return { done: false };
  }
  if (state && state !== 'COMPLETED' && state !== 'SUCCEEDED') {
    const detail = JSON.stringify(statusPayload).slice(0, 500);
    const reason: GenFailureReason =
      /nsfw|moderat|safety|policy|sensitive|copyright/i.test(detail) ? 'provider_moderation' : 'provider_error';
    return { done: true, result: { ok: false, reason, detail } };
  }

  // COMPLETED → fetch the final response (JSON with an output URL, or raw bytes).
  let out: Response;
  try {
    out = await fetch(`${v2Base(cfg)}/requests/${requestId}`, { headers: { 'x-api-key': cfg.apiKey } });
  } catch {
    return { done: false };
  }
  if (!out.ok) { await out.body?.cancel(); return { done: false }; }
  const contentType = out.headers.get('content-type') ?? 'application/octet-stream';
  if (contentType.includes('application/json')) {
    const payload = await out.json();
    const url = payload?.video?.url ?? payload?.output_url ?? payload?.url ?? payload?.image_url;
    if (typeof url !== 'string') {
      return { done: true, result: { ok: false, reason: 'provider_error', detail: 'no output url in async result' } };
    }
    const dl = await fetch(url);
    if (!dl.ok) return { done: true, result: { ok: false, reason: 'provider_error', status: dl.status, detail: 'output download failed' } };
    return {
      done: true,
      result: {
        ok: true, bytes: new Uint8Array(await dl.arrayBuffer()),
        contentType: dl.headers.get('content-type') ?? 'video/mp4',
        seed, model, mode: 'live', requestId,
      },
    };
  }
  return {
    done: true,
    result: {
      ok: true, bytes: new Uint8Array(await out.arrayBuffer()), contentType,
      seed, model, mode: 'live', requestId,
    },
  };
}

// ── Cutscene (Seedance 2.0): bracketed by the anchor plates ───────────────────────
export async function generateCutscene(cfg: CinematicConfig, req: CutsceneRequest): Promise<GenResult> {
  if (!req.prompt?.trim()) return { ok: false, reason: 'invalid_request', detail: 'empty prompt' };
  // The start plate is always anchored; the end plate is required UNLESS a reference
  // clip rides along (ByteDance: reference content + both frames = invalid request).
  if (!req.firstFrameUrl || (!req.lastFrameUrl && !req.referenceVideoUrls?.length)) {
    return { ok: false, reason: 'invalid_request', detail: 'firstFrameUrl required; lastFrameUrl required without a reference clip' };
  }
  const seed = pickSeed(req.seed, `cutscene:${req.prompt}:${req.firstFrameUrl}:${req.lastFrameUrl ?? ''}`, cfg.mode);

  if (cfg.mode === 'sim') {
    return { ok: true, bytes: SIM_MP4, contentType: 'video/mp4', seed, model: 'sim-seedance', mode: 'sim' };
  }
  const tier = req.tierOverride ?? cfg.renderTier;
  const model = tier === 'standard' ? cfg.seedanceStandardModel : cfg.seedanceFastModel;
  // NOTE: never send reference_images here — like all reference content it conflicts
  // with dual-frame conditioning. Subject identity travels in the prompt + the clip.
  return await callSegmind(cfg, model, cutsceneBody(cfg, req, seed));
}

// ── V2V core restyle (PLAN 2026-07-14 item 1c: Track A collapsed to one call) ──────
// The user's trimmed, pre-gen-moderated clip is restyled INTO the cel-shaded core —
// the source motion is actually in the output, unlike the reference-video path where
// the provider merely looks at it. Two docs-verified candidates (2026-07-14):
//
//   kling-o3-video2video-edit — video_url + prompt (+ @Image1 refs via image_urls[]),
//     duration STRING 3–15s, keep_audio preserves the ORIGINAL soundtrack (provider
//     default false — we set it), mode std|pro, no seed param. Input video width must
//     be 720–2160px (the trimmer caps long edge at 1280, so small portrait sources
//     may fall short — a micro-trial finding to watch).
//   runway-gen4-aleph — video (≤16MB; trims run 1–3MB) + prompt + reference_image +
//     int seed. Output is SILENT: the caller lays the original clip audio back via
//     the stitch worker's audio-overlay path.
//
// Both run through Segmind's v2 async queue, so submit/poll/park/resume reuse the
// exact machinery of the Seedance path (pollCutscene is request-id generic).

export interface V2VRestyleRequest {
  prompt: string;              // house style-lock restyle prompt (never user-authored)
  videoUrl: string;            // signed mint-staging clip URL (pre-gen moderated)
  referenceImageUrl?: string;  // the card art — character consistency across surfaces
  durationS?: number;          // kling only (clamped 3–15); aleph follows the input
  keepAudio?: boolean;         // kling only; aleph output is always silent
  aspectRatio?: string;        // default 16:9 (the cutscene canvas)
  seed?: number;               // aleph only; captured on the result either way (HR39)
  tierOverride?: 'fast' | 'standard';
}

export function v2vModelFor(cfg: CinematicConfig, provider: V2VProvider): string {
  return provider === 'kling-o3' ? cfg.klingV2VModel : cfg.alephV2VModel;
}

function v2vBody(
  cfg: CinematicConfig, provider: V2VProvider, req: V2VRestyleRequest, seed: number,
): Record<string, unknown> {
  const tier = req.tierOverride ?? cfg.renderTier;
  if (provider === 'kling-o3') {
    return {
      prompt: req.prompt,
      video_url: req.videoUrl,
      duration: String(Math.min(15, Math.max(3, Math.round(req.durationS ?? 5)))),
      aspect_ratio: req.aspectRatio ?? '16:9',
      mode: tier === 'standard' ? 'pro' : 'std',
      // Founder feedback item 2 (audio) solved at the source: the original clip
      // soundtrack survives the restyle. Explicit — the provider default is false.
      keep_audio: req.keepAudio !== false,
      ...(req.referenceImageUrl ? { image_urls: [req.referenceImageUrl] } : {}),
    };
  }
  return {
    prompt: req.prompt,
    video: req.videoUrl,
    aspect_ratio: req.aspectRatio ?? '16:9',
    ...(req.referenceImageUrl ? { reference_image: req.referenceImageUrl } : {}),
    seed,
  };
}

// Sim-mode stub (governance: every pipeline is exercisable with zero spend/keys).
export async function generateV2VRestyle(
  cfg: CinematicConfig, provider: V2VProvider, req: V2VRestyleRequest,
): Promise<GenResult> {
  if (!req.prompt?.trim() || !req.videoUrl) {
    return { ok: false, reason: 'invalid_request', detail: 'prompt and videoUrl required' };
  }
  const seed = pickSeed(req.seed, `v2v:${provider}:${req.prompt}:${req.videoUrl}`, cfg.mode);
  if (cfg.mode === 'sim') {
    return { ok: true, bytes: SIM_MP4, contentType: 'video/mp4', seed, model: `sim-${provider}`, mode: 'sim' };
  }
  return await callSegmind(cfg, v2vModelFor(cfg, provider), v2vBody(cfg, provider, req, seed));
}

// Live submit to the v2 async queue — poll with pollCutscene(cfg, requestId, model,
// seed), park/resume identical to the Seedance path (results retained 1h).
export async function submitV2VRestyle(
  cfg: CinematicConfig, provider: V2VProvider, req: V2VRestyleRequest,
): Promise<CutsceneSubmit> {
  if (!cfg.apiKey) return { ok: false, reason: 'not_configured', detail: 'SEGMIND_API_KEY missing' };
  if (!req.prompt?.trim() || !req.videoUrl) {
    return { ok: false, reason: 'invalid_request', detail: 'prompt and videoUrl required' };
  }
  const model = v2vModelFor(cfg, provider);
  const seed = pickSeed(req.seed, `v2v:${provider}:${req.prompt}:${req.videoUrl}`, cfg.mode);

  let res: Response;
  try {
    res = await fetch(`${v2Base(cfg)}/${model}`, {
      method: 'POST',
      headers: { 'x-api-key': cfg.apiKey, 'Content-Type': 'application/json' },
      body: JSON.stringify(v2vBody(cfg, provider, req, seed)),
    });
  } catch (e) {
    return { ok: false, reason: 'provider_error', detail: (e as Error).message };
  }
  if (res.status === 429) {
    console.warn(`segmind ${model} submit: 429 rate-limited — skipping (Hard Rule 8)`);
    await res.body?.cancel();
    return { ok: false, reason: 'rate_limited', status: 429 };
  }
  if (!res.ok) {
    const detail = (await res.text()).slice(0, 500);
    const reason: GenFailureReason = res.status === 400 || res.status === 422
      ? (/nsfw|moderat|safety|policy|sensitive|rai/i.test(detail) ? 'provider_moderation' : 'invalid_request')
      : 'provider_error';
    return { ok: false, reason, status: res.status, detail };
  }
  try {
    const payload = await res.json();
    const requestId = payload?.request_id ?? payload?.id;
    if (typeof requestId !== 'string' || !requestId) {
      return { ok: false, reason: 'provider_error', detail: 'no request_id in async submit response' };
    }
    return { ok: true, requestId, seed, model };
  } catch {
    return { ok: false, reason: 'provider_error', detail: 'async submit response unparseable' };
  }
}
