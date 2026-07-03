// tools/cinematic/smoke_mint.ts
// C2 end-to-end proof: moment → cinematic-mint (sim) → pending_preview chit →
// preview hook → finalize. Uses a dedicated test user (dev tooling — removed at the
// pre-launch reset, ARCHIVE §A8).
//
// SUPABASE_URL=… SUPABASE_SERVICE_ROLE_KEY=… SUPABASE_ANON_KEY=… \
//   deno run --allow-net --allow-env tools/cinematic/smoke_mint.ts

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const URL_ = Deno.env.get('SUPABASE_URL')!;
const SR = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const EMAIL = 'cinematic-smoke@noraplatforms.com';
const PASS = 'smoke-' + SR.slice(-12);

const admin = createClient(URL_, SR);
const fail = (m: string): never => { console.error(`SMOKE FAIL: ${m}`); Deno.exit(1); };

// 1. test user (idempotent)
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

// 2. moment: recorded + handle + PRE-GEN moderation approved (60k engagement → tier C)
const { data: momentId, error: mErr } = await admin.rpc('moment_record', {
  p_owner: userId, p_platform: 'youtube', p_external_id: 'c2-e2e-' + crypto.randomUUID(),
  p_url: 'https://youtube.com/watch?v=smoke', p_thumbnail: null, p_engagement: 60000, p_consent: true,
});
if (mErr) fail(`moment_record: ${mErr.message}`);
await admin.from('moments').update({ creator_handle: '@smoke_creator' }).eq('id', momentId);
const { error: modErr } = await admin.rpc('moment_moderate', { p_moment_id: momentId, p_approved: true });
if (modErr) fail(`moment_moderate: ${modErr.message}`);

// 3. sign in as the user, call cinematic-mint
const userClient = createClient(URL_, ANON);
const { data: session, error: sErr } = await userClient.auth.signInWithPassword({ email: EMAIL, password: PASS });
if (sErr || !session.session) fail(`sign-in: ${sErr?.message}`);
const res = await fetch(`${URL_}/functions/v1/cinematic-mint`, {
  method: 'POST',
  headers: {
    Authorization: `Bearer ${session.session!.access_token}`,
    apikey: ANON,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({
    moment_id: momentId, family: 'athlete', chit_type: 'creature',
    timing_type: 'on_summon', name: 'C2 Smoke Sprinter',
    subject_desc: 'a cel-shaded sprinter exploding off the blocks',
  }),
});
const mint = await res.json();
if (!res.ok) fail(`cinematic-mint HTTP ${res.status}: ${JSON.stringify(mint)}`);
if (mint.status !== 'pending_preview' || !mint.chit_id) fail(`unexpected mint payload: ${JSON.stringify(mint)}`);
console.log(`minted pending_preview chit=${mint.chit_id} template=${mint.template_id} tier=${mint.tier} seed=${mint.seed}`);
if (mint.template_id !== 'ground_slam') fail(`tier C creature should route to ground_slam, got ${mint.template_id}`);
if (!String(mint.mp4_cutscene_url).includes('/battle-media/')) fail('mp4 not in battle-media');

// 4. gate order: finalize before preview must fail; then preview → finalize
const { error: earlyErr } = await userClient.rpc('chit_finalize_preview', { p_chit_id: mint.chit_id });
if (!earlyErr) fail('finalize before preview should be rejected');
const { error: pErr } = await userClient.rpc('chit_record_preview', { p_chit_id: mint.chit_id });
if (pErr) fail(`chit_record_preview: ${pErr.message}`);
const { error: fErr } = await userClient.rpc('chit_finalize_preview', { p_chit_id: mint.chit_id });
if (fErr) fail(`chit_finalize_preview: ${fErr.message}`);

// 5. verify final state
const { data: chit } = await admin.from('moment_chits').select('*').eq('id', mint.chit_id).single();
if (!chit?.is_active || !chit.finalized_at) fail('chit not active/finalized');
if (chit.generation_seed === null || chit.anchor_plate_version !== 1 || chit.prompt_template_version !== 1) {
  fail('cinematic version/seed fields not persisted');
}
if (chit.original_minter_handle !== '@smoke_creator') fail('minter attribution missing');
const { data: own } = await admin.from('chit_ownership').select('quantity')
  .eq('chit_id', mint.chit_id).eq('user_id', userId).single();
if (!own || own.quantity < 1) fail('ownership not granted');

console.log('C2 E2E SMOKE OK: mint → moderation → store → preview gate → finalize → owned, versioned, attributed');
