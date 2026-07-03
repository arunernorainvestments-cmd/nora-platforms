// supabase/functions/_shared/moderation.ts
// M-P1 — pre-generation vision moderation (minting spec P1, Layer 2).
//
// Classifies the fetched source (thumbnail/frames + text context) BEFORE any
// generation runs. Verdict semantics (Hard Rule 37):
//   - minor_safety   → 'escalated' — ABSOLUTE: block + human escalation, never generate.
//   - nsfw / graphic_violence / hate → 'rejected'.
//   - third_party_likeness → approved WITH a review flag (not a block).
//
// Sim-first per governance: MODERATION_MODE=sim (default) is deterministic via
// [[SIM_*]] markers in the text context so the whole gate is exercisable without
// a model. Live mode classifies with Claude (claude-sonnet-4-6) vision.
//
// Invariants:
// - FAIL CLOSED: any provider error, parse failure, or missing key in live mode
//   returns 'rejected' (reason on the result) — moderation is never skipped open.
// - HTTP 429 → logged, returned as 'rejected'/'rate_limited', never thrown (Hard Rule 8).
// - The API key is never logged (Hard Rule 9).

export interface ModerationConfig {
  mode: 'sim' | 'live';
  apiKey: string | null;      // ANTHROPIC_API_KEY
  model: string;
}

export function moderationConfigFromEnv(
  env: (k: string) => string | undefined = Deno.env.get.bind(Deno.env),
): ModerationConfig {
  return {
    mode: env('MODERATION_MODE') === 'live' ? 'live' : 'sim',
    apiKey: env('ANTHROPIC_API_KEY') ?? null,
    model: env('MODERATION_MODEL') ?? 'claude-sonnet-4-6',
  };
}

export type PreGenVerdict = 'approved' | 'rejected' | 'escalated';

export interface PreGenLabels {
  minor_safety: boolean;
  nsfw: boolean;
  graphic_violence: boolean;
  hate: boolean;
  third_party_likeness: boolean;
}

export interface PreGenInput {
  imageUrls: string[];        // thumbnail + any representative frames
  textContext?: string;       // title / caption / description from the source post
}

export interface PreGenResult {
  verdict: PreGenVerdict;
  thirdPartyLikeness: boolean;
  labels: PreGenLabels;
  model: string;              // 'sim' or the live model id
  reason?: string;            // set on rejected/escalated (incl. fail-closed causes)
}

const CLEAN_LABELS: PreGenLabels = {
  minor_safety: false,
  nsfw: false,
  graphic_violence: false,
  hate: false,
  third_party_likeness: false,
};

// Labels → verdict. Order matters: minor-safety wins over everything (absolute).
function verdictFor(labels: PreGenLabels, model: string): PreGenResult {
  if (labels.minor_safety) {
    return {
      verdict: 'escalated', thirdPartyLikeness: labels.third_party_likeness,
      labels, model, reason: 'minor_safety',
    };
  }
  if (labels.nsfw || labels.graphic_violence || labels.hate) {
    const reason = labels.nsfw ? 'nsfw' : labels.graphic_violence ? 'graphic_violence' : 'hate';
    return { verdict: 'rejected', thirdPartyLikeness: labels.third_party_likeness, labels, model, reason };
  }
  return { verdict: 'approved', thirdPartyLikeness: labels.third_party_likeness, labels, model };
}

function failClosed(reason: string, model: string): PreGenResult {
  console.warn(`pre-gen moderation fail-closed: ${reason}`);
  return {
    verdict: 'rejected', thirdPartyLikeness: false,
    labels: { ...CLEAN_LABELS }, model, reason,
  };
}

export async function preGenModerate(cfg: ModerationConfig, input: PreGenInput): Promise<PreGenResult> {
  if (cfg.mode === 'sim') return simModerate(input);
  return await liveModerate(cfg, input);
}

// ── sim: deterministic marker-driven verdicts ────────────────────────────────────
function simModerate(input: PreGenInput): PreGenResult {
  const hay = `${input.textContext ?? ''} ${input.imageUrls.join(' ')}`;
  const labels: PreGenLabels = {
    minor_safety: hay.includes('[[SIM_MINOR_SAFETY]]'),
    nsfw: hay.includes('[[SIM_NSFW]]'),
    graphic_violence: hay.includes('[[SIM_VIOLENCE]]'),
    hate: hay.includes('[[SIM_HATE]]'),
    third_party_likeness: hay.includes('[[SIM_THIRD_PARTY]]'),
  };
  return verdictFor(labels, 'sim');
}

// ── live: Claude vision classification ──────────────────────────────────────────
const CLASSIFIER_SYSTEM =
  'You are a strict content-safety classifier for a game that mints collectible cards ' +
  'from social-media posts. Classify the provided post images and text. Respond with ' +
  'ONLY a JSON object, no prose, with these boolean fields:\n' +
  '{"minor_safety": <true if ANY sexual content involving a minor, content that ' +
  'sexualizes a minor, or any ambiguity about whether a sexualized subject is a minor>,\n' +
  ' "nsfw": <true if sexual/explicit adult content>,\n' +
  ' "graphic_violence": <true if gore or graphic real-world violence>,\n' +
  ' "hate": <true if hate symbols/speech or targeted harassment>,\n' +
  ' "third_party_likeness": <true if the content prominently features identifiable ' +
  'people other than the poster>}\n' +
  'When uncertain on minor_safety, answer true.';

async function liveModerate(cfg: ModerationConfig, input: PreGenInput): Promise<PreGenResult> {
  if (!cfg.apiKey) return failClosed('not_configured', cfg.model);
  if (input.imageUrls.length === 0 && !input.textContext?.trim()) {
    return failClosed('no_content', cfg.model);
  }

  const content: unknown[] = input.imageUrls.slice(0, 8).map((url) => ({
    type: 'image', source: { type: 'url', url },
  }));
  content.push({
    type: 'text',
    text: `Post text context (may be empty):\n${input.textContext ?? ''}\n\nClassify now.`,
  });

  let res: Response;
  try {
    res = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'x-api-key': cfg.apiKey,
        'anthropic-version': '2023-06-01',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: cfg.model,
        max_tokens: 300,
        system: CLASSIFIER_SYSTEM,
        messages: [{ role: 'user', content }],
      }),
    });
  } catch (err) {
    return failClosed(`network_error: ${err instanceof Error ? err.message : String(err)}`, cfg.model);
  }

  if (res.status === 429) {
    await res.body?.cancel();
    return failClosed('rate_limited', cfg.model);
  }
  if (!res.ok) {
    const detail = (await res.text()).slice(0, 200);
    return failClosed(`provider_error_${res.status}: ${detail}`, cfg.model);
  }

  try {
    const data = await res.json();
    const text: string = data.content?.find((b: { type: string }) => b.type === 'text')?.text ?? '';
    const match = text.match(/\{[\s\S]*\}/);
    if (!match) return failClosed('unparseable_verdict', cfg.model);
    const raw = JSON.parse(match[0]) as Record<string, unknown>;
    const labels: PreGenLabels = {
      minor_safety: raw.minor_safety === true,
      nsfw: raw.nsfw === true,
      graphic_violence: raw.graphic_violence === true,
      hate: raw.hate === true,
      third_party_likeness: raw.third_party_likeness === true,
    };
    return verdictFor(labels, cfg.model);
  } catch (err) {
    return failClosed(`parse_error: ${err instanceof Error ? err.message : String(err)}`, cfg.model);
  }
}
