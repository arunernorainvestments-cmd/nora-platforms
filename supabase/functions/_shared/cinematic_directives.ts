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

export function assembleMotionPrompt(
  promptBody: string,
  slots: { subjectDesc: string; familyAction: string; tierIntensity: string },
): string {
  return promptBody
    .replaceAll('{SUBJECT_DESC}', sanitizeSubjectDesc(slots.subjectDesc))
    .replaceAll('{FAMILY_ACTION}', slots.familyAction)
    .replaceAll('{TIER_INTENSITY}', slots.tierIntensity);
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
    'cel-shaded anime, bold black ink outlines, flat cel shadows,',
    'dynamic hero pose, centered subject, dark studio void background,',
    'portrait 4:5 composition,',
    `subject: ${sanitizeSubjectDesc(subjectDesc)},`,
    `${accent.phrase} accent rim-light and energy glow around the subject,`,
    'no text, no words, no letters, no logos, no card frame, no border, no UI panels,',
    'no photographic realism',
  ].join(' ');
}
