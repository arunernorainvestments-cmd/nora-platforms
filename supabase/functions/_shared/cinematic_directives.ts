// supabase/functions/_shared/cinematic_directives.ts
// Directive assembly (minting spec P3 / cinematic spec §4): role → Match Cut template,
// family → aesthetic verb phrase, tier → VFX intensity. House-owned; users influence
// NONE of this — only {SUBJECT_DESC} originates from the post, and it is sanitized
// so it can never break out of its slot (Hard Rule 39).

export type Family =
  | 'athlete' | 'musician' | 'artist' | 'scientist' | 'comedian'
  | 'influencer' | 'politician' | 'business' | 'gamer' | 'actor';
export type Tier = 'F' | 'E' | 'D' | 'C' | 'B' | 'A' | 'S';

// role → template (camera geometry). Creatures split aggressive/majestic by tier;
// spells route on effect semantics (effect_kind/target from effect_templates).
export function selectTemplate(args: {
  chitType: 'creature' | 'spell_moment';
  tier: Tier;
  timing?: string | null;
  effectKind?: string | null;
  target?: string | null;
}): string {
  if (args.chitType === 'creature') {
    return args.tier === 'A' || args.tier === 'S' ? 'sky_descent' : 'ground_slam';
  }
  if (args.timing === 'counter') return 'counter_veil';
  if (args.effectKind === 'aoe_damage' || args.target === 'all_enemies') return 'radial_burst';
  const supportive = ['heal', 'buff_atk', 'buff_hp', 'buff_atk_hp', 'shield_grant', 'taunt_grant', 'aura_refund', 'draw_card', 'summon_token'];
  const allyTargets = ['self', 'ally_target', 'all_allies'];
  if ((args.effectKind && supportive.includes(args.effectKind)) ||
      (args.target && allyTargets.includes(args.target))) return 'aura_surge';
  return 'projectile_strike';
}

const ROLE_ACTION: Record<string, string> = {
  ground_slam: 'charges in and slams down at the spawn point',
  sky_descent: 'descends from above and lands majestically at center field',
  projectile_strike: 'launches toward the opponent and strikes',
  radial_burst: 'unleashes an expanding shockwave across the whole field',
  aura_surge: 'channels a protective surge that wraps the ally in light',
  counter_veil: 'snaps into a defensive stance and rebounds the incoming threat',
};

const FAMILY_FLAVOR: Record<Family, string> = {
  athlete: 'with explosive athletic power',
  musician: 'as rings of visible sound and rhythm',
  artist: 'in a swirl of living paint and ink',
  scientist: 'in a crackle of arcing experimental energy',
  comedian: 'in a burst of manic, cartoonish chaos',
  influencer: 'in a storm of glowing reactions and light trails',
  politician: 'with a commanding, crowd-rallying surge',
  business: 'in a cascade of golden momentum',
  gamer: 'in a pixel-burst power-up glow',
  actor: 'with dramatic spotlight flair',
};

export function familyAction(family: Family, templateId: string): string {
  return `${ROLE_ACTION[templateId] ?? ROLE_ACTION.projectile_strike} ${FAMILY_FLAVOR[family]}`;
}

export const TIER_INTENSITY: Record<Tier, string> = {
  F: 'modest, quick effects',
  E: 'light, snappy effects',
  D: 'moderate, confident effects',
  C: 'strong, vivid effects',
  B: 'heavy, dramatic effects',
  A: 'massive, screen-shaking spectacle',
  S: 'screen-filling, overwhelming spectacle',
};

// {SUBJECT_DESC} is the only post-derived slot: strip anything that could read as
// grammar/markup, collapse whitespace, hard length cap.
export function sanitizeSubjectDesc(raw: string): string {
  return raw.replace(/[{}\[\]<>|`]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 200);
}

// {CLIP_REF} fill (prompt template v2, mig 163): house-owned constant text telling
// Seedance to recreate the user's actual uploaded clip (passed as reference_videos[0])
// — the only variable inside is the sanitized clip_video_desc. Built here so the
// wording can never drift per-call, and collapses to empty when no clip is attached.
export function clipRefDirective(videoDesc: string | null | undefined): string {
  const desc = videoDesc ? sanitizeSubjectDesc(videoDesc) : '';
  return (
    '[SOURCE] reference video 1 is the real source moment: recreate its subject and ' +
    `action${desc ? ` — ${desc} —` : ''} fully restyled into the cel-shaded look below; ` +
    'the character design follows the person in reference video 1, stylized.'
  );
}

export function assembleMotionPrompt(
  promptBody: string,
  slots: {
    subjectDesc: string;
    familyAction: string;
    tierIntensity: string;
    videoDesc?: string | null;
    // TRUE only when the clip is actually being sent as reference_videos[0] —
    // the directive must never promise a video the request doesn't carry.
    clipAttached?: boolean;
  },
): string {
  // {VIDEO_DESC} is a VARIABLE slot filled only for the V2V core node (Hard Rule 39:
  // the constant STYLE-LOCK/CONSTRAINTS still win; the agnostic bridge templates carry
  // no {VIDEO_DESC} placeholder, so a bridge prompt is a no-op replace and stays
  // character-agnostic). Absent description → the slot collapses to empty.
  // {CLIP_REF} (template v2) collapses the same way when no clip rides along.
  return promptBody
    .replaceAll('{SUBJECT_DESC}', sanitizeSubjectDesc(slots.subjectDesc))
    .replaceAll('{FAMILY_ACTION}', slots.familyAction)
    .replaceAll('{TIER_INTENSITY}', slots.tierIntensity)
    .replaceAll('{VIDEO_DESC}', slots.videoDesc ? sanitizeSubjectDesc(slots.videoDesc) : '')
    .replaceAll('{CLIP_REF}', slots.clipAttached ? clipRefDirective(slots.videoDesc) : '')
    .replace(/\n{3,}/g, '\n\n')   // a collapsed slot never leaves a hole in the prompt
    .replace(/\n\s*\n/g, '\n')
    .trim();
}

// ── {VIDEO_DESC} generation: a Vision-LLM read of the clip's sampled frames ───────
// Produced by moment-clip-attach AFTER pre-gen moderation approves the upload (it is
// another CSAM checkpoint — never described otherwise). sim → a deterministic stub so
// the pipeline is testable with no spend; live → Claude vision over the same frames the
// moderator saw. Best-effort: a failure returns null and the pipeline proceeds on
// {SUBJECT_DESC} alone (never blocks minting). Reuses ModerationConfig's mode/key/model.
export interface ClipDescribeConfig {
  mode: 'sim' | 'live';
  apiKey: string | null;
  model: string;
}

const CLIP_DESCRIBE_SYSTEM =
  'You describe the visible ACTION in a short social-video clip for a stylized ' +
  'video-restyle prompt. Respond with ONE vivid sentence, present tense, no names of ' +
  'real people or brands, no quotes, no preamble — just the sentence. Describe motion ' +
  'and subject only (what moves and how), never text overlays or watermarks.';

export async function describeClipFrames(
  cfg: ClipDescribeConfig,
  frameUrls: string[],
  simHint?: string,
): Promise<string | null> {
  if (cfg.mode === 'sim' || !cfg.apiKey) {
    const hint = (simHint ?? '').trim();
    return sanitizeSubjectDesc(hint || 'the subject moves through their signature moment');
  }
  if (frameUrls.length === 0) return null;

  const content: unknown[] = frameUrls.slice(0, 4).map((url) => ({
    type: 'image', source: { type: 'url', url },
  }));
  content.push({ type: 'text', text: 'Describe the action across these clip frames now.' });

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
        model: cfg.model, max_tokens: 150, system: CLIP_DESCRIBE_SYSTEM,
        messages: [{ role: 'user', content }],
      }),
    });
  } catch (err) {
    console.warn('describeClipFrames call failed:', err instanceof Error ? err.message : String(err));
    return null;
  }
  // Hard Rule 8: rate-limited → skip cleanly (pipeline continues without a description).
  if (res.status === 429) { await res.body?.cancel(); console.warn('describeClipFrames rate-limited'); return null; }
  if (!res.ok) { await res.body?.cancel(); return null; }

  try {
    const data = await res.json();
    const text: string = data.content?.find((b: { type: string }) => b.type === 'text')?.text ?? '';
    const cleaned = sanitizeSubjectDesc(text);
    return cleaned || null;
  } catch (err) {
    console.warn('describeClipFrames parse failed:', err instanceof Error ? err.message : String(err));
    return null;
  }
}

// Per-family accent glow — the "variability within uniformity" for the card art
// (the frame's violet→teal piping is the fixed brand constant; the illustration's
// glow shifts per classified family). hex mirrors the Flutter CardFace accent so the
// AI glow and the app-rendered chrome read as the same hue. House-owned: the family
// is classified from content (Hard Rule 34), never user-picked.
export const FAMILY_ACCENT: Record<Family, { hex: string; phrase: string }> = {
  athlete: { hex: '#FF5A1F', phrase: 'fiery orange-red' },
  musician: { hex: '#FF3DBE', phrase: 'magenta violet-pink' },
  artist: { hex: '#B15CFF', phrase: 'vivid violet-purple' },
  scientist: { hex: '#2BE0C8', phrase: 'teal-cyan' },
  comedian: { hex: '#B6E62E', phrase: 'yellow-green' },
  influencer: { hex: '#FF4D9D', phrase: 'hot rose-pink' },
  politician: { hex: '#FF3B3B', phrase: 'commanding crimson' },
  business: { hex: '#FFC53D', phrase: 'golden amber' },
  gamer: { hex: '#39FF14', phrase: 'neon green' },
  actor: { hex: '#E8D9A0', phrase: 'silver-gold spotlight' },
};

// Fixed house illustration script (cinematic spec §3.3) — the card-art prompt.
// Three bands, mirroring assembleMotionPrompt's discipline: a CONSTANT style-lock
// (never user-influenced), the VARIABLE post-derived subject (sanitized), and the
// VARIABLE house-mapped family glow — then CONSTRAINTS that keep the asset CLEAN
// (no frame, no text): the chip frame + all card text are rendered by the app/Unity
// over this illustration, never baked in by the model (avoids AI text garble and lets
// stats/localization change without regenerating art).
export function illustrationPrompt(subjectDesc: string, family: Family): string {
  const accent = FAMILY_ACCENT[family];
  return [
    'Stylized trading-card character illustration,',
    'cel-shaded, bold black ink outlines, flat cel shadows, painterly rim-lit accents,',
    'dynamic hero pose, centered subject, dark studio void background,',
    'portrait 4:5 composition,',
    `subject: ${sanitizeSubjectDesc(subjectDesc)},`,
    `${accent.phrase} accent rim-light and energy glow around the subject,`,
    // 2026-07-13 audit cause #5: without these, an under-specified subject defaulted
    // to the archetypal shonen-anime hero (a recognizable DBZ likeness) — a quality
    // AND IP failure. The subject must be an original design derived from the moment.
    'an original character design unique to this card,',
    'never any existing anime, manga, video-game, comic, or cartoon character,',
    'no celebrity likeness, no franchise costume or hairstyle,',
    'no text, no words, no letters, no logos, no card frame, no border, no UI panels,',
    'no photographic realism',
  ].join(' ');
}
