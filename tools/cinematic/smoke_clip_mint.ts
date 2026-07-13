// tools/cinematic/smoke_clip_mint.ts
// Live trial of the clip-referenced cutscene path (PLAN 2026-07-13 audit item 5):
// moment + ATTACHED CLIP → async cinematic-mint → Seedance called with the plate
// bookends AND reference_videos[0] = the clip → assert the mig-163 ledger fields
// (clip_reference_used, full prompts, provider request ids, template v2).
//
// PAID: one live illustration + one live cutscene (billed at V2V rate). Dev tooling —
// removed at the pre-launch reset (ARCHIVE §A8).
//
// SUPABASE_URL=… SUPABASE_SERVICE_ROLE_KEY=… SUPABASE_ANON_KEY=… \
//   (SOURCE_CLIP_MOMENT_ID=<moment with clip_status=attached> | SOURCE_CLIP_FILE=<local mp4>) \
//   [SMOKE_USER_ID=…] \
//   deno run --allow-net --allow-env --allow-read tools/cinematic/smoke_clip_mint.ts
//
// NOTE (trial 2026-07-13): ByteDance moderates input assets — a third-party celebrity
// clip is rejected with InputVideoSensitiveContentDetected/copyright. Use owned or
// synthetic footage (SOURCE_CLIP_FILE) to exercise the happy path; the flagged-clip
// path now degrades to a prompt-only cutscene inside cinematic-mint.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const URL_ = Deno.env.get('SUPABASE_URL')!;
const SR = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SOURCE_MOMENT = Deno.env.get('SOURCE_CLIP_MOMENT_ID');
const SOURCE_FILE = Deno.env.get('SOURCE_CLIP_FILE');
const EMAIL = 'cinematic-smoke@noraplatforms.com';
const PASS = 'smoke-' + SR.slice(-12);

const admin = createClient(URL_, SR);
const fail = (m: string): never => { console.error(`SMOKE FAIL: ${m}`); Deno.exit(1); };

// 1. smoke user (idempotent; GoTrue listUsers 500s on this project → SMOKE_USER_ID)
let userId: string;
const created = await admin.auth.admin.createUser({ email: EMAIL, password: PASS, email_confirm: true });
if (created.data.user) userId = created.data.user.id;
else {
  userId = Deno.env.get('SMOKE_USER_ID') ?? fail('cannot create smoke user (set SMOKE_USER_ID)');
  const upd = await admin.auth.admin.updateUserById(userId, { password: PASS });
  if (upd.error) fail(`password reset: ${upd.error.message}`);
}

// 1b. free the self-mint slot — dogfood the new chit_delete_owned (mig 162) first,
//     fall back to the old admin cleanup for pending/edge states.
for (let i = 0; i < 5; i++) {
  const { data: slot } = await admin.rpc('self_mint_slot', { p_user: userId });
  if (!slot) break;
  const { error: delErr } = await admin.rpc('chit_delete_owned', { p_user: userId, p_chit: slot });
  if (!delErr) { console.log(`slot cleanup: chit_delete_owned retired ${slot}`); continue; }
  const { data: held } = await admin.from('chit_ownership')
    .select('quantity').eq('user_id', userId).eq('chit_id', slot).single();
  if ((held?.quantity ?? 0) > 0) {
    await admin.rpc('chit_grant', {
      p_user_id: userId, p_chit_id: slot, p_quantity: -held!.quantity,
      p_reason: 'platform_correction',
    });
  }
  await admin.from('moment_chits')
    .update({ is_active: false, retired_at: new Date().toISOString(), retired_reason: 'admin' })
    .eq('id', slot);
}

// 2. source clip: a local file, or a copy of an existing attached clip
let clipBlob: Blob;
let trim = { start: 0, end: 4000 };
if (SOURCE_FILE) {
  clipBlob = new Blob([await Deno.readFile(SOURCE_FILE)], { type: 'video/mp4' });
  console.log(`source clip: ${SOURCE_FILE} (${clipBlob.size} bytes)`);
} else if (SOURCE_MOMENT) {
  const { data: srcRow } = await admin.from('moments')
    .select('raw_clip_path, clip_trim_start_ms, clip_trim_end_ms')
    .eq('id', SOURCE_MOMENT).single();
  const src = (srcRow ?? fail(`source moment ${SOURCE_MOMENT} not found`)) as {
    raw_clip_path: string | null; clip_trim_start_ms: number | null; clip_trim_end_ms: number | null;
  };
  if (!src.raw_clip_path) fail(`source moment ${SOURCE_MOMENT} has no attached clip`);
  const dl = await admin.storage.from('mint-staging').download(src.raw_clip_path!);
  clipBlob = (dl.data ?? fail(`clip download: ${dl.error?.message}`)) as Blob;
  trim = { start: src.clip_trim_start_ms ?? 0, end: src.clip_trim_end_ms ?? 4000 };
  console.log(`source clip: ${src.raw_clip_path} (${clipBlob.size} bytes, trim ${trim.start}–${trim.end}ms)`);
} else {
  clipBlob = fail('set SOURCE_CLIP_FILE or SOURCE_CLIP_MOMENT_ID');
}

// 3. moment: recorded + approved + clip attached (60k engagement → tier C creature)
const { data: momentId, error: mErr } = await admin.rpc('moment_record', {
  p_owner: userId, p_platform: 'youtube', p_external_id: 'clip-trial-' + crypto.randomUUID(),
  p_url: 'https://youtube.com/watch?v=cliptrial', p_thumbnail: null, p_engagement: 60000,
  p_consent: true, p_handle: '@smoke_creator', p_title: 'clip reference trial',
});
if (mErr) fail(`moment_record: ${mErr.message}`);
const clipPath = `${userId}/${momentId}/clip.mp4`;
const up = await admin.storage.from('mint-staging')
  .upload(clipPath, clipBlob, { contentType: 'video/mp4', upsert: true });
if (up.error) fail(`clip copy upload: ${up.error.message}`);
const { error: modErr } = await admin.rpc('moment_moderate', { p_moment_id: momentId, p_approved: true });
if (modErr) fail(`moment_moderate: ${modErr.message}`);
const { error: attachErr } = await admin.rpc('moment_attach_clip', {
  p_moment_id: momentId, p_owner: userId, p_clip_path: clipPath,
  p_frame_paths: [], p_trim_start_ms: trim.start,
  p_trim_end_ms: trim.end, p_keep_audio: true, p_verdict: 'attached',
});
if (attachErr) fail(`moment_attach_clip: ${attachErr.message}`);
await admin.rpc('moment_set_clip_video_desc', {
  p_moment_id: momentId, p_owner: userId,
  p_desc: 'a man in a dark suit gestures decisively and delivers a commanding line',
});

// 4. sign in, kick the async mint
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
    moment_id: momentId, family: 'actor', chit_type: 'creature',
    timing_type: 'on_summon', name: 'Clip Trial',
    subject_desc: 'a confident man in a dark suit pointing forward mid-declaration',
  }),
});
const mint = await res.json();
if (res.status !== 202 || !mint.job_id) fail(`cinematic-mint HTTP ${res.status}: ${JSON.stringify(mint)}`);
console.log(`job accepted: ${mint.job_id} (mode=${mint.mode})`);

// 5. poll the job to a terminal state (live renders take minutes)
let job: Record<string, unknown> | null = null;
for (let i = 0; i < 90; i++) {
  await new Promise((r) => setTimeout(r, 10_000));
  const { data } = await admin.from('mint_jobs')
    .select('stage,status,error,detail,generation_id,chit_id,result').eq('id', mint.job_id).single();
  job = data;
  if (!job) continue;
  if (i % 3 === 0) console.log(`  t+${(i + 1) * 10}s stage=${job.stage} status=${job.status}`);
  if (job.status && job.status !== 'running') break;
}
if (!job) fail('job row never appeared');
console.log(`terminal: status=${job!.status} stage=${job!.stage} error=${job!.error ?? '-'} detail=${job!.detail ?? '-'}`);

// 6. the actual trial assertions live on the generation ledger (mig 163)
const genId = job!.generation_id as string | null;
if (!genId) fail(`no generation row (job error: ${job!.detail})`);
const { data: genRow } = await admin.from('cinematic_generations')
  .select('status, mode, attempt, prompt_template_version, clip_reference_used, motion_prompt, illustration_prompt, illustration_request_id, cutscene_request_id, illustration_path, mp4_path, generation_seed')
  .eq('id', genId).single();
// deno-lint-ignore no-explicit-any
const gen = (genRow ?? fail('generation row unreadable')) as any;
console.log(JSON.stringify({
  gen_status: gen.status, mode: gen.mode,
  prompt_template_version: gen.prompt_template_version,
  clip_reference_used: gen.clip_reference_used,
  illustration_request_id: gen.illustration_request_id,
  cutscene_request_id: gen.cutscene_request_id,
  seed: gen.generation_seed,
}, null, 2));
if (gen.mode === 'live') {
  if (!gen.clip_reference_used) fail('clip_reference_used should be TRUE (clip was attached + ≥2s)');
  if (gen.prompt_template_version !== 2) fail(`expected prompt template v2, got ${gen.prompt_template_version}`);
  if (!String(gen.motion_prompt ?? '').includes('reference video 1')) fail('motion_prompt missing the clip directive');
  if (String(gen.motion_prompt ?? '').includes('{CLIP_REF}')) fail('CLIP_REF slot not substituted');
}
console.log('--- motion prompt sent ---');
console.log(gen.motion_prompt);
if (gen.illustration_path) {
  console.log('card art:', admin.storage.from('battle-media').getPublicUrl(gen.illustration_path).data.publicUrl);
}
if (gen.mp4_path) {
  console.log('cutscene:', admin.storage.from('battle-media').getPublicUrl(gen.mp4_path).data.publicUrl);
}

// 7. cleanup: retire the trial chit via the new delete RPC (frees slot + releases
//    moment); media intentionally kept in battle-media for human review.
if (job!.chit_id) {
  const { error: cleanErr } = await admin.rpc('chit_delete_owned', { p_user: userId, p_chit: job!.chit_id });
  console.log(cleanErr ? `cleanup skipped: ${cleanErr.message}` : `cleanup: trial chit ${job!.chit_id} deleted, moment released`);
}

if (job!.status === 'succeeded') console.log('CLIP-REFERENCE TRIAL OK');
else if (job!.status === 'held_moderation') {
  console.log(`TRIAL GENERATED but held for review — approve with: SELECT cinematic_moderation_verdict('${genId}', true, NULL);`);
} else fail(`job ended ${job!.status}`);
