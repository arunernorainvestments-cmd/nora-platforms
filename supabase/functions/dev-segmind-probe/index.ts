// dev-segmind-probe — TEMPORARY dev tooling (delete before launch, ARCHIVE §A8).
// Echoes the raw Segmind v2 status/result payload for an async request id so the
// poll-shape can be verified without the API key leaving the edge environment.
// Auth: caller must present the service-role key (never deployed to clients).

Deno.serve(async (req: Request): Promise<Response> => {
  const probe = req.headers.get('X-Probe-Secret') ?? '';
  const expected = Deno.env.get('DEV_PROBE_SECRET') ?? '';
  if (!expected || probe !== expected) {
    return new Response('forbidden', { status: 403 });
  }
  const id = new URL(req.url).searchParams.get('id');
  if (!id) return new Response('missing id', { status: 400 });
  const key = Deno.env.get('SEGMIND_API_KEY') ?? '';
  const base = (Deno.env.get('SEGMIND_BASE_URL') ?? 'https://api.segmind.com/v1').replace(/\/v1\/?$/, '/v2');

  const st = await fetch(`${base}/requests/${id}/status`, { headers: { 'x-api-key': key } });
  const stBody = (await st.text()).slice(0, 1500);
  const res = await fetch(`${base}/requests/${id}`, { headers: { 'x-api-key': key } });
  const ct = res.headers.get('content-type') ?? '';
  const resBody = ct.includes('json') || ct.includes('text') ? (await res.text()).slice(0, 1500) : `[${ct}]`;

  return new Response(JSON.stringify({
    status_http: st.status, status_body: stBody,
    result_http: res.status, result_ct: ct, result_body: resBody,
  }), { headers: { 'Content-Type': 'application/json' } });
});
