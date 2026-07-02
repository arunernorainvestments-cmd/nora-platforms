// deno test supabase/functions/_shared/segmind_test.ts
// C0 round-trip smoke for the Segmind client (sim mode — no key, no network).

import {
  cinematicConfigFromEnv,
  generateCutscene,
  generateIllustration,
} from './segmind.ts';

const simCfg = cinematicConfigFromEnv((k) =>
  ({ CINEMATIC_MODE: 'sim' } as Record<string, string>)[k]
);

Deno.test('config defaults to sim + fast (draft) tier', () => {
  if (simCfg.mode !== 'sim') throw new Error('default mode must be sim');
  if (simCfg.renderTier !== 'fast') throw new Error('default tier must be fast');
});

Deno.test('illustration round-trip: bytes + deterministic captured seed', async () => {
  const a = await generateIllustration(simCfg, { prompt: 'a cel-shaded dancer' });
  const b = await generateIllustration(simCfg, { prompt: 'a cel-shaded dancer' });
  if (!a.ok || !b.ok) throw new Error('sim illustration must succeed');
  if (a.bytes.length === 0) throw new Error('no bytes returned');
  if (a.contentType !== 'image/png') throw new Error('unexpected content type');
  if (a.seed !== b.seed) throw new Error('identical input must reproduce the seed');
});

Deno.test('cutscene round-trip: bookends honored, seed reproducible + overridable', async () => {
  const req = {
    prompt: 'jets streak toward the target and strike',
    firstFrameUrl: 'https://example.com/plates/projectile_strike_start_v1.png',
    lastFrameUrl: 'https://example.com/plates/projectile_strike_end_v1.png',
    durationS: 4,
  };
  const a = await generateCutscene(simCfg, req);
  const b = await generateCutscene(simCfg, req);
  if (!a.ok || !b.ok) throw new Error('sim cutscene must succeed');
  if (a.contentType !== 'video/mp4') throw new Error('unexpected content type');
  if (a.seed !== b.seed) throw new Error('identical input must reproduce the seed');

  const fixed = await generateCutscene(simCfg, { ...req, seed: 424242 });
  if (!fixed.ok || fixed.seed !== 424242) throw new Error('explicit seed must be captured verbatim');
});

Deno.test('cutscene without both anchor plates is rejected', async () => {
  const r = await generateCutscene(simCfg, {
    prompt: 'x',
    firstFrameUrl: 'https://example.com/start.png',
    lastFrameUrl: '',
    durationS: 4,
  });
  if (r.ok || r.reason !== 'invalid_request') throw new Error('missing bookend must be invalid_request');
});

Deno.test('live mode without a key degrades to not_configured (never throws)', async () => {
  const liveCfg = cinematicConfigFromEnv((k) =>
    ({ CINEMATIC_MODE: 'live' } as Record<string, string>)[k]
  );
  const r = await generateIllustration(liveCfg, { prompt: 'x' });
  if (r.ok || r.reason !== 'not_configured') throw new Error('keyless live must be not_configured');
});
