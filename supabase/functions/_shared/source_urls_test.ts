// deno test supabase/functions/_shared/source_urls_test.ts
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { parsePostUrl } from './source_urls.ts';

Deno.test('allowlist: youtube watch / shorts / youtu.be parse', () => {
  assertEquals(parsePostUrl('https://www.youtube.com/watch?v=dQw4w9WgXcQ'), {
    platform: 'youtube', externalId: 'dQw4w9WgXcQ',
    canonicalUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
  });
  assertEquals(parsePostUrl('https://youtube.com/shorts/abc123XYZ_-')?.externalId, 'abc123XYZ_-');
  assertEquals(parsePostUrl('https://youtu.be/dQw4w9WgXcQ')?.canonicalUrl,
    'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
});

Deno.test('allowlist: tiktok video URL parses; profile/short-link do not', () => {
  assertEquals(parsePostUrl('https://www.tiktok.com/@somebody/video/7301234567890123456'), {
    platform: 'tiktok', externalId: '7301234567890123456',
    canonicalUrl: 'https://www.tiktok.com/@somebody/video/7301234567890123456',
  });
  assertEquals(parsePostUrl('https://www.tiktok.com/@somebody'), null);
  assertEquals(parsePostUrl('https://vm.tiktok.com/ZM8abcdef/'), null);
});

Deno.test('allowlist: instagram p / reel / reels parse', () => {
  assertEquals(parsePostUrl('https://www.instagram.com/p/Cx1abcDEF2g/')?.platform, 'instagram');
  assertEquals(parsePostUrl('https://instagram.com/reel/Cx1abcDEF2g')?.externalId, 'Cx1abcDEF2g');
  assertEquals(parsePostUrl('https://www.instagram.com/reels/Cx1abcDEF2g/')?.externalId, 'Cx1abcDEF2g');
});

Deno.test('allowlist: off-list sources rejected (Hard Rule 37)', () => {
  assertEquals(parsePostUrl('https://twitch.tv/videos/123'), null);
  assertEquals(parsePostUrl('https://x.com/user/status/123'), null);
  assertEquals(parsePostUrl('https://facebook.com/watch?v=123'), null);
  assertEquals(parsePostUrl('https://evil.com/watch?v=abc'), null);
  assertEquals(parsePostUrl('http://www.youtube.com/watch?v=abc'), null);  // https only
  assertEquals(parsePostUrl('not a url'), null);
});

Deno.test('allowlist: lookalike hosts rejected', () => {
  assertEquals(parsePostUrl('https://youtube.com.evil.com/watch?v=abc'), null);
  assertEquals(parsePostUrl('https://nottiktok.com/@u/video/123'), null);
});
