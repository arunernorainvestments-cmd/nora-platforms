// deno test --allow-env supabase/functions/_shared/moderation_test.ts
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { moderationConfigFromEnv, preGenModerate } from './moderation.ts';

const SIM = moderationConfigFromEnv((k) => (k === 'MODERATION_MODE' ? 'sim' : undefined));

Deno.test('sim: clean content approves', async () => {
  const r = await preGenModerate(SIM, { imageUrls: ['https://x/thumb.jpg'], textContext: 'a skate trick' });
  assertEquals(r.verdict, 'approved');
  assertEquals(r.thirdPartyLikeness, false);
  assertEquals(r.model, 'sim');
});

Deno.test('sim: minor-safety marker escalates (absolute, wins over all)', async () => {
  const r = await preGenModerate(SIM, {
    imageUrls: [],
    textContext: '[[SIM_MINOR_SAFETY]] [[SIM_NSFW]] [[SIM_THIRD_PARTY]]',
  });
  assertEquals(r.verdict, 'escalated');
  assertEquals(r.reason, 'minor_safety');
  assertEquals(r.labels.minor_safety, true);
});

Deno.test('sim: nsfw / violence / hate reject', async () => {
  for (const marker of ['[[SIM_NSFW]]', '[[SIM_VIOLENCE]]', '[[SIM_HATE]]']) {
    const r = await preGenModerate(SIM, { imageUrls: [], textContext: marker });
    assertEquals(r.verdict, 'rejected', marker);
  }
});

Deno.test('sim: third-party likeness approves with the review flag', async () => {
  const r = await preGenModerate(SIM, { imageUrls: [], textContext: '[[SIM_THIRD_PARTY]]' });
  assertEquals(r.verdict, 'approved');
  assertEquals(r.thirdPartyLikeness, true);
});

Deno.test('live: missing API key fails CLOSED (rejected, never approved)', async () => {
  const cfg = moderationConfigFromEnv((k) => (k === 'MODERATION_MODE' ? 'live' : undefined));
  const r = await preGenModerate(cfg, { imageUrls: ['https://x/thumb.jpg'], textContext: 'anything' });
  assertEquals(r.verdict, 'rejected');
  assertEquals(r.reason, 'not_configured');
});

Deno.test('live: empty input fails closed', async () => {
  const cfg = {
    mode: 'live' as const,
    apiKey: 'test-key-never-sent',
    model: 'claude-sonnet-4-6',
  };
  const r = await preGenModerate(cfg, { imageUrls: [], textContext: '' });
  assertEquals(r.verdict, 'rejected');
  assertEquals(r.reason, 'no_content');
});
