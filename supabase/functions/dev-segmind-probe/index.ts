// dev-segmind-probe — TEMPORARY dev tooling (delete before launch, ARCHIVE §A8).
// Mode 1 (?id=): echo the raw Segmind v2 status/result payload for an async request.
// Mode 2 (?screen=<mp4 public url>&gen=<id>): replay the post-gen screening chain
// (stitch /frames → sign → live classifier) and echo each step's outcome.
// Auth: X-Probe-Secret must match the DEV_PROBE_SECRET edge secret.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { moderationConfigFromEnv, preGenModerate } from '../_shared/moderation.ts';

Deno.serve(async (req: Request): Promise<Response> => {
  const probe = req.headers.get('X-Probe-Secret') ?? '';
  const expected = Deno.env.get('DEV_PROBE_SECRET') ?? '';
  if (!expected || probe !== expected) {
    return new Response('forbidden', { status: 403 });
  }
  const url = new URL(req.url);
  const id = url.searchParams.get('id');
  const screen = url.searchParams.get('screen');
  const gen = url.searchParams.get('gen') ?? 'probe';
  const json = (b: unknown) => new Response(JSON.stringify(b), { headers: { 'Content-Type': 'application/json' } });

  if (screen) {
    const out: Record<string, unknown> = {};
    const workerUrl = Deno.env.get('STITCH_WORKER_URL');
    const secret = Deno.env.get('STITCH_SECRET');
    out.worker_configured = !!(workerUrl && secret);
    if (!workerUrl || !secret) return json(out);
    let fr: Response;
    try {
      fr = await fetch(`${workerUrl.replace(/\/$/, '')}/frames`, {
        method: 'POST',
        headers: { 'X-Stitch-Secret': secret, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          video_url: screen,
          times: [0.4, 2.5, 'last'],
          upload: { bucket: 'mint-staging', prefix: `postgen/${gen}` },
        }),
      });
    } catch (e) {
      out.frames_error = (e as Error).message;
      return json(out);
    }
    out.frames_http = fr.status;
    const frBody = await fr.text();
    out.frames_body = frBody.slice(0, 800);
    if (!fr.ok) return json(out);
    let framePaths: string[] = [];
    try {
      framePaths = ((JSON.parse(frBody).frames ?? []) as { path: string }[])
        .map((f) => String(f.path).replace(/^mint-staging\//, ''));
    } catch { out.frames_parse = 'failed'; return json(out); }
    out.frame_paths = framePaths;
    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const urls: string[] = [];
    for (const p of framePaths) {
      const { data: signed, error } = await db.storage.from('mint-staging').createSignedUrl(p, 600);
      if (signed?.signedUrl) urls.push(signed.signedUrl);
      else out[`sign_error_${p}`] = error?.message;
    }
    out.signed_count = urls.length;
    if (urls.length > 0) {
      const cfg = moderationConfigFromEnv();
      out.moderation_mode = cfg.mode;
      out.moderation_model = cfg.model;
      const verdict = await preGenModerate(cfg, { imageUrls: urls });
      out.verdict = verdict;
    }
    return json(out);
  }

  if (!id) return new Response('missing id or screen', { status: 400 });
  const key = Deno.env.get('SEGMIND_API_KEY') ?? '';
  const base = (Deno.env.get('SEGMIND_BASE_URL') ?? 'https://api.segmind.com/v1').replace(/\/v1\/?$/, '/v2');
  const st = await fetch(`${base}/requests/${id}/status`, { headers: { 'x-api-key': key } });
  const stBody = (await st.text()).slice(0, 1500);
  const res = await fetch(`${base}/requests/${id}`, { headers: { 'x-api-key': key } });
  const ct = res.headers.get('content-type') ?? '';
  const resBody = ct.includes('json') || ct.includes('text') ? (await res.text()).slice(0, 1500) : `[${ct}]`;
  return json({ status_http: st.status, status_body: stBody, result_http: res.status, result_ct: ct, result_body: resBody });
});
