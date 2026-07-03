// tools/minting/smoke_ingest.ts
// M-P1 end-to-end proof against the deployed moment-ingest (sim ingest + sim
// moderation): allowlist, ownership gate, approved path (chains into cinematic-mint
// eligibility), minor-safety escalation, third-party review flag. Uses the same
// dedicated test user as the C2 smoke (dev tooling — removed at the pre-launch
// reset, ARCHIVE §A8).
//
// SUPABASE_URL=… SUPABASE_SERVICE_ROLE_KEY=… SUPABASE_ANON_KEY=… \
//   deno run --allow-net --allow-env tools/minting/smoke_ingest.ts

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const URL_ = Deno.env.get('SUPABASE_URL')!;
const SR = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const EMAIL = 'cinematic-smoke@noraplatforms.com';
const PASS = 'smoke-' + SR.slice(-12);

const admin = createClient(URL_, SR);
const fail = (m: string): never => { console.error(`SMOKE FAIL: ${m}`); Deno.exit(1); };

// 1. test user (idempotent — same user as the C2 smoke). SMOKE_USER_ID is the
//    fallback when the GoTrue admin list endpoint is unavailable.
let userId: string;
const created = await admin.auth.admin.createUser({ email: EMAIL, password: PASS, email_confirm: true });
if (created.data.user) userId = created.data.user.id;
else {
  const { data } = await admin.auth.admin.listUsers();
  userId = data?.users?.find((u) => u.email === EMAIL)?.id ??
    Deno.env.get('SMOKE_USER_ID') ??
    fail('cannot create/find smoke user (set SMOKE_USER_ID)');
  const upd = await admin.auth.admin.updateUserById(userId, { password: PASS });
  if (upd.error) fail(`password reset: ${upd.error.message}`);
}

// 2. fake OAuth link (Layer 0 gate needs a platform_connections row; sim ingest
//    never calls the platform API so the token is a placeholder)
const { error: connErr } = await admin.from('platform_connections').upsert({
  user_id: userId,
  platform: 'youtube',
  platform_user_id: 'smoke-channel',
  platform_username: 'smoke_creator',
  access_token: 'sim-token',
  refresh_token: null,
  token_expires_at: null,
  scopes: ['sim'],
  connected_at: new Date().toISOString(),
  is_active: true,
}, { onConflict: 'user_id,platform' });
if (connErr) fail(`platform_connections upsert: ${connErr.message}`);

// 3. sign in
const userClient = createClient(URL_, ANON);
const { data: session, error: sErr } = await userClient.auth.signInWithPassword({ email: EMAIL, password: PASS });
if (sErr || !session.session) fail(`sign-in: ${sErr?.message}`);
const ingest = (body: Record<string, unknown>) =>
  fetch(`${URL_}/functions/v1/moment-ingest`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${session.session!.access_token}`,
      apikey: ANON,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });
const ytUrl = () => `https://www.youtube.com/watch?v=${crypto.randomUUID().slice(0, 11)}`;
const cleanupMoments: string[] = [];

// 4. off-allowlist source → 400 (Hard Rule 37)
{
  const res = await ingest({ post_url: 'https://twitch.tv/videos/12345' });
  if (res.status !== 400) fail(`off-allowlist expected 400, got ${res.status}: ${await res.text()}`);
  await res.body?.cancel();
  console.log('allowlist rejection OK (twitch → 400)');
}

// 5. unlinked platform → 403 (Layer 0 — no instagram connection exists)
{
  const res = await ingest({ post_url: 'https://www.instagram.com/p/SmokeAbc123/' });
  if (res.status !== 403) fail(`unlinked expected 403, got ${res.status}: ${await res.text()}`);
  await res.body?.cancel();
  console.log('ownership/link gate OK (unlinked instagram → 403)');
}

// 6. approved path: clean post → approved moment, mint-eligible
{
  const res = await ingest({ post_url: ytUrl(), sim_engagement: 60000, sim_title: 'a clean skate trick' });
  const out = await res.json();
  if (!res.ok) fail(`approved path HTTP ${res.status}: ${JSON.stringify(out)}`);
  if (out.status !== 'approved' || !out.moment_id) fail(`unexpected payload: ${JSON.stringify(out)}`);
  if (out.projected_tier !== 'C') fail(`60k engagement should project tier C, got ${out.projected_tier}`);
  if (out.creator_handle !== '@smoke_creator') fail(`handle mismatch: ${out.creator_handle}`);
  cleanupMoments.push(out.moment_id);
  const { data: m } = await admin.from('moments')
    .select('moderation_status, mint_status, creator_handle, consent_granted_at').eq('id', out.moment_id).single();
  if (m?.moderation_status !== 'approved' || m?.mint_status !== 'moderated') {
    fail(`moment row not mint-eligible: ${JSON.stringify(m)}`);
  }
  if (!m?.consent_granted_at) fail('consent not recorded');
  console.log(`approved path OK (moment=${out.moment_id} tier=${out.projected_tier} handle=${out.creator_handle})`);
}

// 7. minor-safety marker → rejected + escalation row (absolute screen)
{
  const res = await ingest({ post_url: ytUrl(), sim_title: 'bad content [[SIM_MINOR_SAFETY]]' });
  const out = await res.json();
  if (!res.ok) fail(`escalation path HTTP ${res.status}: ${JSON.stringify(out)}`);
  if (out.status !== 'rejected') fail(`minor-safety must surface as plain rejection: ${JSON.stringify(out)}`);
  if (out.projected_tier !== undefined || out.detail?.includes('minor')) {
    fail('rejection response must not leak category detail');
  }
  cleanupMoments.push(out.moment_id);
  const { data: m } = await admin.from('moments').select('moderation_status').eq('id', out.moment_id).single();
  if (m?.moderation_status !== 'rejected') fail('escalated moment must be rejected in DB');
  const { data: esc } = await admin.from('moderation_escalations')
    .select('reason, status').eq('moment_id', out.moment_id);
  if (esc?.length !== 1 || esc[0].reason !== 'minor_safety' || esc[0].status !== 'open') {
    fail(`minor-safety escalation row missing: ${JSON.stringify(esc)}`);
  }
  console.log('minor-safety escalation OK (rejected + open human-review case, no category leak)');
}

// 8. third-party likeness → approved + review flag + review row
{
  const res = await ingest({ post_url: ytUrl(), sim_engagement: 500, sim_title: 'me and a celeb [[SIM_THIRD_PARTY]]' });
  const out = await res.json();
  if (!res.ok || out.status !== 'approved') fail(`third-party path: ${JSON.stringify(out)}`);
  if (out.third_party_likeness_review !== true) fail('third-party review flag missing');
  cleanupMoments.push(out.moment_id);
  const { data: esc } = await admin.from('moderation_escalations')
    .select('reason').eq('moment_id', out.moment_id);
  if (esc?.length !== 1 || esc[0].reason !== 'third_party_likeness') fail('third-party review row missing');
  console.log('third-party likeness OK (approved + flagged for review)');
}

// 9. client must NOT be able to see escalations or self-approve moderation
{
  const { data: escLeak } = await userClient.from('moderation_escalations').select('id');
  if (escLeak && escLeak.length > 0) fail('client can read moderation_escalations');
  const { error: selfApprove } = await userClient.rpc('moment_moderate', {
    p_moment_id: cleanupMoments[1], p_approved: true,
  });
  if (!selfApprove) fail('client can call moment_moderate (self-approval hole)');
  console.log('privacy/privilege OK (escalations invisible; moment_moderate denied to clients)');
}

// 10. cleanup (escalations cascade with moments)
for (const id of cleanupMoments) await admin.from('moments').delete().eq('id', id);
await admin.from('platform_connections').delete()
  .eq('user_id', userId).eq('platform', 'youtube').eq('platform_user_id', 'smoke-channel');
console.log('M-P1 SMOKE PASSED: allowlist + link gate + moderation verdict paths + privacy all enforced');
