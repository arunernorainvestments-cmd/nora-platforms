// supabase/functions/mint-cancel/index.ts
// The mint wizard "Cancel / discard" path (Preview step). A chit exists as soon as
// generation completes (cinematic_complete_mint), but stays is_active=FALSE until the
// user previews + finalizes (Hard Rule 39). That pending chit OCCUPIES the one
// self_mint_slot, so backing out must actually retire it — not just navigate away, or
// the next mint is stuck behind the swap-confirm flow.
//
// POST { chit_id, allow_finalized? }
//   1. chit_discard_pending (mig 150): owner + not-finalized + not-retired → soft-retire,
//      zero holdings (append-only ledger), purge decks, free the slot. Returns moment_id.
//      With allow_finalized: true (the collection "Delete card" action), the guard set
//      is chit_delete_owned (mig 162) instead — minter-only, no foreign copies, not
//      wagered/listed — and it also RELEASES the source moment for a clean re-mint.
//   2. delete the chit's battle-media (card art + all cutscene attempts).
//
// Without allow_finalized, a FINALIZED chit is refused here (the RPC raises).
// Deployed --no-verify-jwt (ES256 project); auth via supabase.auth.getUser().

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': 'https://noraplatforms.com',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { status: 200, headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) return json({ error: 'Unauthorized' }, 401);
  const anon = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!);
  const { data: { user }, error: authError } = await anon.auth.getUser(authHeader.replace('Bearer ', ''));
  if (authError || !user) return json({ error: 'Unauthorized' }, 401);

  let body: { chit_id?: string; allow_finalized?: boolean };
  try { body = await req.json(); } catch { return json({ error: 'Invalid JSON body' }, 400); }
  const chitId = body.chit_id?.trim();
  if (!chitId) return json({ error: 'Missing required field: chit_id' }, 400);

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  // ── 1. retire the chit (all ownership/state guards enforced in the RPC) ───────────
  const rpc = body.allow_finalized === true ? 'chit_delete_owned' : 'chit_discard_pending';
  const { data: momentId, error: discardErr } = await db.rpc(rpc, {
    p_user: user.id, p_chit: chitId,
  });
  if (discardErr) {
    // The RPC raises for a guarded/foreign/unknown chit — surface as a 409, not 500.
    return json({ error: 'not_discardable', detail: discardErr.message }, 409);
  }

  // ── 2. delete the chit's battle-media (best-effort; the chit is already retired) ──
  let mediaDeleted = 0;
  if (momentId) {
    try { mediaDeleted = await deleteMomentMedia(db, momentId as string); }
    catch (err) { console.warn('mint-cancel: media cleanup failed (chit already retired):', err); }
  }

  return json({ ok: true, discarded_chit_id: chitId, media_deleted: mediaDeleted });
});

// Remove every battle-media object under moments/<momentId> (card art + all cutscene
// attempts). Mirrors deleteMomentMedia in cinematic-mint. Storage list() marks folders
// with a null id.
async function deleteMomentMedia(
  db: { storage: ReturnType<typeof createClient>['storage'] }, momentId: string,
): Promise<number> {
  const root = `moments/${momentId}`;
  const files: string[] = [];
  const { data: entries } = await db.storage.from('battle-media').list(root, { limit: 100 });
  for (const e of entries ?? []) {
    if (e.id) files.push(`${root}/${e.name}`);
    else {
      const { data: sub } = await db.storage.from('battle-media').list(`${root}/${e.name}`, { limit: 100 });
      for (const s of sub ?? []) if (s.id) files.push(`${root}/${e.name}/${s.name}`);
    }
  }
  if (files.length > 0) {
    const { error } = await db.storage.from('battle-media').remove(files);
    if (error) throw new Error(error.message);
  }
  return files.length;
}
