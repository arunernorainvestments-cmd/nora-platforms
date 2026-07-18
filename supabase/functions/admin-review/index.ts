// supabase/functions/admin-review/index.ts
// Admin console MVP (PLAN 2026-07-15 callout) — the moderation review queue +
// mint-pipeline ops that until now required raw SQL / management-API calls.
//
// Gate: the caller must be authenticated AND profiles.is_admin (mig 001). Every
// action re-checks server-side — the /admin screen is just a window.
//
// GET  ?action=queue   → held generations (status='generated', a human verdict
//                        pending) with sampled post-gen frames (signed — the
//                        mint-staging bucket is private), the public cutscene
//                        URL, moment context, open escalations, and
//                        similarity-flagged clips.
// GET  ?action=jobs    → live + recently-failed mint_jobs (stale detection).
// POST {action:'verdict', generation_id, approved, reason?}
//                      → cinematic_moderation_verdict (the mint resumes free on
//                        the user's next Generate click).
// POST {action:'reopen', generation_id}
//                      → moderation_rejected → back to 'generated' so the
//                        verdict RPC can re-run (rejected rows otherwise need a
//                        direct UPDATE — the old raw-SQL chore).
// POST {action:'fail_job', job_id}   → mark a stuck 'running' job failed.
// POST {action:'clip_verdict', moment_id, approved}
//                      → similarity_flagged clip → attached / rejected.
// POST {action:'resolve_escalation', escalation_id, cleared, note?}
//                      → close a moderation_escalations case. Clearing a
//                        minor_safety case NEVER auto-approves the moment
//                        (mig 141 contract) — it only closes the case.
//
// Privacy: this function exposes mint-pipeline state only. It must never read
// ubi_* documents/votes or lkn private data (Hard Rules 23–25, 29–32).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': 'https://noraplatforms.com',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

const JOB_STALE_MS = 8 * 60 * 1000;

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { status: 200, headers: corsHeaders });

  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) return json({ error: 'Unauthorized' }, 401);
  const anon = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!);
  const { data: { user }, error: authError } =
    await anon.auth.getUser(authHeader.replace('Bearer ', ''));
  if (authError || !user) return json({ error: 'Unauthorized' }, 401);

  const db = createClient(
    Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  const { data: profile } = await db.from('profiles')
    .select('is_admin').eq('id', user.id).single();
  if (!profile?.is_admin) return json({ error: 'Admin only' }, 403);

  const action = req.method === 'GET'
    ? new URL(req.url).searchParams.get('action')
    : null;

  if (req.method === 'GET' && action === 'queue') {
    // Held generations: rendered, screened, awaiting a human verdict.
    const { data: gens } = await db.from('cinematic_generations')
      .select('id, moment_id, status, reject_reason, mp4_path, attempt, created_at, '
        + 'subject_desc, requested_name, v2v_provider, '
        + 'moments(creator_handle, source_platform, source_url, owner_user_id, clip_video_desc)')
      .in('status', ['generated', 'moderation_rejected'])
      .order('created_at', { ascending: false }).limit(50);

    const held = [];
    for (const g of (gens ?? []) as unknown as Record<string, unknown>[]) {
      // Post-gen sample frames live under mint-staging/postgen/<genId> (private
      // bucket — sign short-lived URLs; the finished MP4 is public battle-media).
      const { data: frameEntries } = await db.storage.from('mint-staging')
        .list(`postgen/${g.id}`, { limit: 10 });
      const frames: string[] = [];
      for (const f of frameEntries ?? []) {
        const { data: s } = await db.storage.from('mint-staging')
          .createSignedUrl(`postgen/${g.id}/${f.name}`, 1800);
        if (s?.signedUrl) frames.push(s.signedUrl);
      }
      held.push({
        ...g,
        frames,
        mp4_url: g.mp4_path
          ? db.storage.from('battle-media').getPublicUrl(g.mp4_path as string).data.publicUrl
          : null,
      });
    }

    const { data: escalations } = await db.from('moderation_escalations')
      .select('id, moment_id, reason, status, created_at, '
        + 'moments(creator_handle, source_platform, source_url)')
      .eq('status', 'open').order('created_at', { ascending: false }).limit(50);

    const { data: flaggedClips } = await db.from('moments')
      .select('id, creator_handle, source_platform, source_url, clip_status, clip_attached_at')
      .eq('clip_status', 'similarity_flagged')
      .order('clip_attached_at', { ascending: false }).limit(50);

    return json({ held, escalations: escalations ?? [], flagged_clips: flaggedClips ?? [] });
  }

  if (req.method === 'GET' && action === 'jobs') {
    const { data: jobs } = await db.from('mint_jobs')
      .select('id, moment_id, user_id, stage, status, error, detail, created_at, updated_at')
      .or(`status.eq.running,and(status.eq.failed,updated_at.gte.${new Date(Date.now() - 24 * 3600 * 1000).toISOString()})`)
      .order('updated_at', { ascending: false }).limit(50);
    const now = Date.now();
    return json({
      jobs: (jobs ?? []).map((j) => ({
        ...j,
        stale: j.status === 'running'
          && now - new Date(j.updated_at as string).getTime() > JOB_STALE_MS,
      })),
    });
  }

  if (req.method !== 'POST') return json({ error: 'Unknown action' }, 400);

  let body: {
    action?: string; generation_id?: string; approved?: boolean; reason?: string;
    job_id?: string; moment_id?: string; escalation_id?: string; cleared?: boolean;
    note?: string;
  };
  try { body = await req.json(); } catch { return json({ error: 'Invalid JSON body' }, 400); }

  switch (body.action) {
    case 'verdict': {
      if (!body.generation_id || typeof body.approved !== 'boolean') {
        return json({ error: 'generation_id + approved required' }, 400);
      }
      const { error } = await db.rpc('cinematic_moderation_verdict', {
        p_generation_id: body.generation_id,
        p_approved: body.approved,
        p_reason: body.approved ? null : (body.reason ?? 'admin_rejected'),
      });
      if (error) return json({ error: error.message }, 409);
      console.log(`admin-review: ${user.id} verdict ${body.approved ? 'APPROVE' : 'REJECT'} gen ${body.generation_id}`);
      return json({ ok: true });
    }
    case 'reopen': {
      if (!body.generation_id) return json({ error: 'generation_id required' }, 400);
      const { data, error } = await db.from('cinematic_generations')
        .update({ status: 'generated', reject_reason: null })
        .eq('id', body.generation_id).eq('status', 'moderation_rejected')
        .select('id');
      if (error) return json({ error: error.message }, 409);
      if (!data?.length) return json({ error: 'Not found or not rejected' }, 409);
      console.log(`admin-review: ${user.id} reopened gen ${body.generation_id}`);
      return json({ ok: true });
    }
    case 'fail_job': {
      if (!body.job_id) return json({ error: 'job_id required' }, 400);
      const { data, error } = await db.from('mint_jobs')
        .update({
          status: 'failed', error: 'admin',
          detail: 'Marked failed by an admin — the user can retry (resume is free where a render was stashed).',
          updated_at: new Date().toISOString(),
        })
        .eq('id', body.job_id).eq('status', 'running').select('id');
      if (error) return json({ error: error.message }, 409);
      if (!data?.length) return json({ error: 'Not found or not running' }, 409);
      return json({ ok: true });
    }
    case 'clip_verdict': {
      if (!body.moment_id || typeof body.approved !== 'boolean') {
        return json({ error: 'moment_id + approved required' }, 400);
      }
      const { data, error } = await db.from('moments')
        .update({ clip_status: body.approved ? 'attached' : 'rejected' })
        .eq('id', body.moment_id).eq('clip_status', 'similarity_flagged')
        .select('id');
      if (error) return json({ error: error.message }, 409);
      if (!data?.length) return json({ error: 'Not found or not flagged' }, 409);
      console.log(`admin-review: ${user.id} clip ${body.approved ? 'APPROVE' : 'REJECT'} moment ${body.moment_id}`);
      return json({ ok: true });
    }
    case 'resolve_escalation': {
      if (!body.escalation_id || typeof body.cleared !== 'boolean') {
        return json({ error: 'escalation_id + cleared required' }, 400);
      }
      const { data, error } = await db.from('moderation_escalations')
        .update({
          status: body.cleared ? 'resolved_cleared' : 'resolved_blocked',
          resolution_note: body.note ?? null,
          resolved_at: new Date().toISOString(),
        })
        .eq('id', body.escalation_id).eq('status', 'open').select('id');
      if (error) return json({ error: error.message }, 409);
      if (!data?.length) return json({ error: 'Not found or not open' }, 409);
      return json({ ok: true });
    }
    default:
      return json({ error: 'Unknown action' }, 400);
  }
});
