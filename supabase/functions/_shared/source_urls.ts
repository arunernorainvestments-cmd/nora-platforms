// supabase/functions/_shared/source_urls.ts
// M-P1 Layer 1 — the source allowlist as URL shapes (Hard Rule 37).
// TikTok / Instagram / YouTube post URLs only; anything else returns null.

export type Platform = 'tiktok' | 'instagram' | 'youtube';

export interface ParsedSource { platform: Platform; externalId: string; canonicalUrl: string }


export function parsePostUrl(raw: string): ParsedSource | null {
  let url: URL;
  try { url = new URL(raw); } catch { return null; }
  if (url.protocol !== 'https:') return null;
  const host = url.hostname.toLowerCase().replace(/^www\./, '');
  const path = url.pathname.replace(/\/+$/, '');

  // youtube: watch?v=ID | /shorts/ID | youtu.be/ID
  if (host === 'youtube.com' || host === 'm.youtube.com') {
    const v = url.searchParams.get('v');
    if (path === '/watch' && v) return { platform: 'youtube', externalId: v, canonicalUrl: `https://www.youtube.com/watch?v=${v}` };
    const shorts = path.match(/^\/shorts\/([A-Za-z0-9_-]+)$/);
    if (shorts) return { platform: 'youtube', externalId: shorts[1], canonicalUrl: `https://www.youtube.com/shorts/${shorts[1]}` };
    return null;
  }
  if (host === 'youtu.be') {
    const id = path.match(/^\/([A-Za-z0-9_-]+)$/);
    if (id) return { platform: 'youtube', externalId: id[1], canonicalUrl: `https://www.youtube.com/watch?v=${id[1]}` };
    return null;
  }

  // tiktok: /@handle/video/ID  (short vm.tiktok.com links must be expanded client-side)
  if (host === 'tiktok.com') {
    const m = path.match(/^\/@[^/]+\/video\/(\d+)$/);
    if (m) return { platform: 'tiktok', externalId: m[1], canonicalUrl: `https://www.tiktok.com${path}` };
    return null;
  }

  // instagram: /p/SHORTCODE | /reel/SHORTCODE | /reels/SHORTCODE
  if (host === 'instagram.com') {
    const m = path.match(/^\/(?:p|reel|reels)\/([A-Za-z0-9_-]+)$/);
    if (m) return { platform: 'instagram', externalId: m[1], canonicalUrl: `https://www.instagram.com${path}` };
    return null;
  }

  return null;
}

