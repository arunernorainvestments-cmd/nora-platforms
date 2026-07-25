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
// Iteration 2 (mig 168 — user/account ops, config, marketplace ops):
// GET  ?action=users&q=…  → search profiles (username/display_name fragment or
//                        exact uuid): flags, KYC status, token balance,
//                        active-listing count. Status only — never documents.
// GET  ?action=config  → platform_integrity_settings + marketplace tier pricing
//                        + live ops counts (the kill-switch panel).
// GET  ?action=listings → active marketplace listings (dispute review).
// POST {action:'set_test_flag', user_id, is_test}
//                      → profiles.is_test_account (Hard Rule 15 filters).
// POST {action:'adjust_tokens', user_id, delta, note}
//                      → admin_adjust_tokens_internal (mig 168): audited via
//                        token_transactions type 'admin_adjustment' (HR 5).
// POST {action:'toggle_setting', key, value}
//                      → allowlisted platform_integrity_settings columns only.
//                        enforce_one_role_per_match is NOT toggleable — it
//                        stays TRUE always (money-independent integrity).
// POST {action:'admin_delist', listing_id}
//                      → marketplace_admin_delist_internal (mig 168): escrow
//                        returns to the seller, listing → 'delisted' (HR 40).
//
// Iteration 3 (mig 177 — Clip Campaigns ops, the Mystery Box gate, audit):
// GET  ?action=campaigns → open clip_campaign_moderation cases (with short-lived
//                        signed clip URLs — clip-staging is private), campaign
//                        clips still awaiting a verdict, and campaigns whose
//                        deadline has passed but are still holding escrow.
// GET  ?action=audit   → the recent admin_audit_log tail.
// POST {action:'resolve_clip_escalation', escalation_id, cleared, note?}
//                      → close a clip_campaign_moderation case. As with the mint
//                        queue, clearing a minor_safety case NEVER approves the
//                        clip — it only closes the case.
// POST {action:'clip_submission_verdict', submission_id, approved}
//                      → the explicit human re-run. The RPC refuses to approve a
//                        submission carrying a minor_safety case, whatever the
//                        case's resolution says (enforced in the DB, mig 177).
// POST {action:'expire_campaigns'}
//                      → run the escrow-refund sweep now (pg_cron runs hourly).
// POST {action:'set_mystery_mode', value:'disabled'|'sim'|'live'}
//                      → the G-MYSTERY founder gate (Hard Rule 41).
//
// Every POST is recorded in admin_audit_log (mig 177) — console.log alone does
// not survive log rotation, and founder-gate flips must stay attributable.
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

  // Append-only audit (mig 177). Best-effort: a logging failure must never block
  // the moderation action itself, but it is loud in the function logs.
  const audit = async (
    act: string, target?: string | null, detail?: Record<string, unknown>,
  ) => {
    const { error } = await db.rpc('admin_log_action', {
      p_admin: user.id,
      p_action: act,
      p_target: target ?? null,
      p_detail: detail ?? null,
    });
    if (error) console.error(`admin-review: AUDIT WRITE FAILED for ${act}`, error.message);
  };

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

  if (req.method === 'GET' && action === 'users') {
    const q = (new URL(req.url).searchParams.get('q') ?? '').trim();
    if (!q) return json({ users: [] });
    const uuidRe = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    let query = db.from('profiles')
      .select('id, username, display_name, is_admin, is_test_account, '
        + 'is_market_maker, created_at, token_balances(available_tokens)')
      .limit(20);
    query = uuidRe.test(q)
      ? query.eq('id', q)
      : query.or(`username.ilike.%${q}%,display_name.ilike.%${q}%`);
    const { data, error } = await query;
    if (error) return json({ error: error.message }, 400);
    const profiles = (data ?? []) as unknown as Record<string, unknown>[];

    const ids = profiles.map((p) => p.id as string);
    // KYC STATUS only (never documents/identity data — status is the ops need).
    const kycByUser: Record<string, string> = {};
    const listingsByUser: Record<string, number> = {};
    if (ids.length) {
      const { data: kyc } = await db.from('kyc_verifications')
        .select('user_id, status, created_at')
        .in('user_id', ids).order('created_at', { ascending: false });
      for (const k of kyc ?? []) {
        kycByUser[k.user_id as string] ??= k.status as string;
      }
      const { data: listings } = await db.from('marketplace_listings')
        .select('seller_user_id').in('seller_user_id', ids).eq('status', 'active');
      for (const l of listings ?? []) {
        const id = l.seller_user_id as string;
        listingsByUser[id] = (listingsByUser[id] ?? 0) + 1;
      }
    }
    return json({
      users: profiles.map((p) => ({
        ...p,
        kyc_status: kycByUser[p.id as string] ?? null,
        active_listings: listingsByUser[p.id as string] ?? 0,
      })),
    });
  }

  if (req.method === 'GET' && action === 'config') {
    const { data: settings } = await db.from('platform_integrity_settings')
      .select('*').eq('id', true).single();
    const { data: pricing } = await db.from('marketplace_tier_pricing')
      .select('tier, token_price, fee_bps, usd_cents').order('token_price');
    const { data: mystery } = await db.from('mystery_pool_settings')
      .select('mode').eq('id', true).maybeSingle();
    const [escalations, listings, jobs, held,
      clipEscalations, pendingClips, overdueCampaigns] = await Promise.all([
      db.from('moderation_escalations').select('id', { count: 'exact', head: true })
        .eq('status', 'open'),
      db.from('marketplace_listings').select('id', { count: 'exact', head: true })
        .eq('status', 'active'),
      db.from('mint_jobs').select('id', { count: 'exact', head: true })
        .eq('status', 'running'),
      db.from('cinematic_generations').select('id', { count: 'exact', head: true })
        .eq('status', 'generated'),
      db.from('clip_campaign_moderation').select('id', { count: 'exact', head: true })
        .eq('status', 'open'),
      db.from('clip_campaign_submissions').select('id', { count: 'exact', head: true })
        .in('status', ['submitted', 'in_moderation']),
      db.from('clip_campaigns').select('id', { count: 'exact', head: true })
        .in('status', ['open', 'reviewing']).lte('deadline', new Date().toISOString()),
    ]);
    return json({
      settings: settings ?? null,
      tier_pricing: pricing ?? [],
      mystery_pool_mode: mystery?.mode ?? 'disabled',
      counts: {
        open_escalations: escalations.count ?? 0,
        active_listings: listings.count ?? 0,
        running_jobs: jobs.count ?? 0,
        held_generations: held.count ?? 0,
        open_clip_escalations: clipEscalations.count ?? 0,
        pending_clip_submissions: pendingClips.count ?? 0,
        overdue_campaigns: overdueCampaigns.count ?? 0,
      },
    });
  }

  if (req.method === 'GET' && action === 'listings') {
    const { data: rows } = await db.from('marketplace_listings')
      .select('id, chit_id, seller_user_id, currency, tier_snapshot, '
        + 'price_snapshot, fee_bps_snapshot, created_at, '
        + 'moment_chits(name, card_art_url, original_minter_handle)')
      .eq('status', 'active').order('created_at', { ascending: false }).limit(50);
    const listings = (rows ?? []) as unknown as Record<string, unknown>[];
    const sellerIds = [...new Set(listings.map((l) => l.seller_user_id as string))];
    const names: Record<string, string> = {};
    if (sellerIds.length) {
      const { data: sellers } = await db.from('profiles')
        .select('id, username, display_name').in('id', sellerIds);
      for (const s of sellers ?? []) {
        names[s.id as string] =
          (s.display_name ?? s.username ?? 'unknown') as string;
      }
    }
    return json({
      listings: listings.map((l) => ({
        ...l,
        seller_name: names[l.seller_user_id as string] ?? 'unknown',
      })),
    });
  }

  if (req.method === 'GET' && action === 'campaigns') {
    // Open human-review cases on campaign clips (mig 176 keeps these in their own
    // table — moderation_escalations.moment_id is NOT NULL and FK'd to moments).
    const { data: cases } = await db.from('clip_campaign_moderation')
      .select('id, submission_id, reason, status, created_at, '
        + 'clip_campaign_submissions(id, campaign_id, clipper_user_id, clip_path, '
        + 'status, note, created_at, clip_campaigns(title, market_maker_user_id))')
      .eq('status', 'open').order('created_at', { ascending: false }).limit(50);

    // Sign each clip for review — the bucket is private and has no read policy.
    const escalations = [];
    for (const c of (cases ?? []) as unknown as Record<string, unknown>[]) {
      const sub = c.clip_campaign_submissions as Record<string, unknown> | null;
      let clipUrl: string | null = null;
      if (sub?.clip_path) {
        const { data: s } = await db.storage.from('clip-staging')
          .createSignedUrl(sub.clip_path as string, 1800);
        clipUrl = s?.signedUrl ?? null;
      }
      escalations.push({ ...c, clip_url: clipUrl });
    }

    // Clips that never got a verdict (e.g. moderation was rate-limited mid-flight).
    const { data: pending } = await db.from('clip_campaign_submissions')
      .select('id, campaign_id, clipper_user_id, clip_path, status, note, created_at, '
        + 'clip_campaigns(title)')
      .in('status', ['submitted', 'in_moderation'])
      .order('created_at', { ascending: false }).limit(50);

    // Overdue campaigns still sitting on escrow — the sweep should have caught
    // these, so anything here means the hourly cron is not running.
    const { data: overdue } = await db.from('clip_campaigns')
      .select('id, title, market_maker_user_id, escrow_remaining_cents, deadline, status')
      .in('status', ['open', 'reviewing'])
      .lte('deadline', new Date().toISOString())
      .order('deadline').limit(50);

    return json({
      escalations,
      pending: pending ?? [],
      overdue: overdue ?? [],
    });
  }

  if (req.method === 'GET' && action === 'audit') {
    const { data: rows } = await db.from('admin_audit_log')
      .select('id, admin_id, action, target_id, detail, created_at')
      .order('created_at', { ascending: false }).limit(100);
    const adminIds = [...new Set((rows ?? []).map((r) => r.admin_id as string))];
    const names: Record<string, string> = {};
    if (adminIds.length) {
      const { data: admins } = await db.from('profiles')
        .select('id, username, display_name').in('id', adminIds);
      for (const a of admins ?? []) {
        names[a.id as string] =
          (a.display_name ?? a.username ?? 'admin') as string;
      }
    }
    return json({
      entries: (rows ?? []).map((r) => ({
        ...r,
        admin_name: names[r.admin_id as string] ?? 'admin',
      })),
    });
  }

  if (req.method !== 'POST') return json({ error: 'Unknown action' }, 400);

  let body: {
    action?: string; generation_id?: string; approved?: boolean; reason?: string;
    job_id?: string; moment_id?: string; escalation_id?: string; cleared?: boolean;
    note?: string; user_id?: string; is_test?: boolean; delta?: number;
    key?: string; value?: boolean | string; listing_id?: string;
    submission_id?: string;
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
      await audit('verdict', body.generation_id, { approved: body.approved });
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
      await audit('reopen', body.generation_id);
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
      await audit('fail_job', body.job_id);
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
      await audit('clip_verdict', body.moment_id, { approved: body.approved });
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
      await audit('resolve_escalation', body.escalation_id, { cleared: body.cleared });
      return json({ ok: true });
    }
    case 'set_test_flag': {
      if (!body.user_id || typeof body.is_test !== 'boolean') {
        return json({ error: 'user_id + is_test required' }, 400);
      }
      const { data, error } = await db.from('profiles')
        .update({ is_test_account: body.is_test })
        .eq('id', body.user_id).select('id');
      if (error) return json({ error: error.message }, 409);
      if (!data?.length) return json({ error: 'User not found' }, 409);
      await audit('set_test_flag', body.user_id, { is_test: body.is_test });
      return json({ ok: true });
    }
    case 'adjust_tokens': {
      if (!body.user_id || typeof body.delta !== 'number'
        || !Number.isInteger(body.delta) || !body.note?.trim()) {
        return json({ error: 'user_id + integer delta + note required' }, 400);
      }
      const { data, error } = await db.rpc('admin_adjust_tokens_internal', {
        p_admin: user.id,
        p_user_id: body.user_id,
        p_delta: body.delta,
        p_note: body.note.trim(),
      });
      if (error) return json({ error: error.message }, 409);
      await audit('adjust_tokens', body.user_id, { delta: body.delta, note: body.note.trim() });
      return json(data ?? { ok: true });
    }
    case 'toggle_setting': {
      // Allowlist only. enforce_one_role_per_match is deliberately absent —
      // it stays TRUE always (money-independent integrity, CLAUDE.md).
      const boolKeys = [
        'require_kyc_for_staking', 'require_kyc_for_combatant',
        'marketplace_usd_lane',
      ];
      const key = body.key ?? '';
      let patch: Record<string, unknown>;
      if (boolKeys.includes(key) && typeof body.value === 'boolean') {
        patch = { [key]: body.value };
      } else if (key === 'battle_payments_mode'
        && (body.value === 'sim' || body.value === 'live')) {
        patch = { battle_payments_mode: body.value };
      } else {
        return json({ error: 'Setting not toggleable from the console' }, 400);
      }
      const { error } = await db.from('platform_integrity_settings')
        .update({ ...patch, updated_at: new Date().toISOString() })
        .eq('id', true);
      if (error) return json({ error: error.message }, 409);
      await audit('toggle_setting', key, { value: body.value });
      return json({ ok: true });
    }
    case 'admin_delist': {
      if (!body.listing_id) return json({ error: 'listing_id required' }, 400);
      const { error } = await db.rpc('marketplace_admin_delist_internal', {
        p_admin: user.id,
        p_listing_id: body.listing_id,
      });
      if (error) return json({ error: error.message }, 409);
      await audit('admin_delist', body.listing_id);
      return json({ ok: true });
    }
    case 'resolve_clip_escalation': {
      if (!body.escalation_id || typeof body.cleared !== 'boolean') {
        return json({ error: 'escalation_id + cleared required' }, 400);
      }
      const { data, error } = await db.from('clip_campaign_moderation')
        .update({
          status: body.cleared ? 'resolved_cleared' : 'resolved_blocked',
          resolution_note: body.note ?? null,
          resolved_at: new Date().toISOString(),
        })
        .eq('id', body.escalation_id).eq('status', 'open').select('id');
      if (error) return json({ error: error.message }, 409);
      if (!data?.length) return json({ error: 'Not found or not open' }, 409);
      await audit('resolve_clip_escalation', body.escalation_id,
        { cleared: body.cleared });
      return json({ ok: true });
    }
    case 'clip_submission_verdict': {
      if (!body.submission_id || typeof body.approved !== 'boolean') {
        return json({ error: 'submission_id + approved required' }, 400);
      }
      // The RPC re-checks admin AND refuses to approve a minor-safety clip.
      const { error } = await db.rpc('admin_clip_submission_verdict_internal', {
        p_admin: user.id,
        p_submission: body.submission_id,
        p_approved: body.approved,
      });
      if (error) return json({ error: error.message }, 409);
      return json({ ok: true });
    }
    case 'expire_campaigns': {
      const { data, error } = await db.rpc('admin_expire_campaigns_internal', {
        p_admin: user.id,
      });
      if (error) return json({ error: error.message }, 409);
      return json({ ok: true, expired: data ?? 0 });
    }
    case 'set_mystery_mode': {
      const mode = body.value;
      if (mode !== 'disabled' && mode !== 'sim' && mode !== 'live') {
        return json({ error: 'value must be disabled | sim | live' }, 400);
      }
      const { error } = await db.rpc('admin_set_mystery_mode_internal', {
        p_admin: user.id,
        p_mode: mode,
      });
      if (error) return json({ error: error.message }, 409);
      return json({ ok: true });
    }
    default:
      return json({ error: 'Unknown action' }, 400);
  }
});
