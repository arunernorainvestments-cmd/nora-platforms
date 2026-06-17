// supabase/functions/lkn-revoke-license/index.ts
//
// The licensor revokes (or suspends) a license they granted.
// Only a status change is performed — the agreement stays append-only (Hard Rule
// 29; the DB guard trigger blocks any change to immutable fields). The public
// registry sync trigger reflects the new status automatically.
//
// Honors the template's revocation_type:
//   'irrevocable'    → cannot revoke
//   'for_cause'      → requires a reason
//   'at_will_30_days'→ allowed; effective in 30 days (recorded in the event note)
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': 'https://noraplatforms.com',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return json({ error: 'Missing authorization header' }, 401);

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) return json({ error: 'Unauthorized' }, 401);

    const service = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    let body: { license_id?: string; reason?: string; action?: string };
    try { body = await req.json(); } catch { return json({ error: 'Invalid JSON body' }, 400); }
    if (!body.license_id) return json({ error: 'license_id is required' }, 400);
    const action = body.action === 'suspend' ? 'suspend' : 'revoke';

    const { data: ag } = await service
      .from('lkn_agreements')
      .select('id, license_id, licensor_user_id, status, terms_snapshot')
      .eq('license_id', body.license_id)
      .maybeSingle();
    if (!ag) return json({ error: 'license not found' }, 404);
    if (ag.licensor_user_id !== user.id) return json({ error: 'only the licensor may revoke' }, 403);
    if (ag.status !== 'active' && ag.status !== 'suspended') {
      return json({ error: `cannot ${action} a ${ag.status} license` }, 409);
    }

    // deno-lint-ignore no-explicit-any
    const revType = (ag.terms_snapshot as any)?.revocation_type ?? 'for_cause';
    if (action === 'revoke') {
      if (revType === 'irrevocable') {
        return json({ error: 'license is irrevocable' }, 403);
      }
      if (revType === 'for_cause' && !(body.reason ?? '').trim()) {
        return json({ error: 'a reason is required to revoke a for-cause license' }, 400);
      }
    }

    const newStatus = action === 'suspend' ? 'suspended' : 'revoked';
    const { error: updErr } = await service
      .from('lkn_agreements')
      .update({
        status: newStatus,
        revoked_at: action === 'revoke' ? new Date().toISOString() : null,
        revoked_reason: action === 'revoke' ? (body.reason ?? null) : null,
      })
      .eq('id', ag.id);
    if (updErr) {
      console.error('lkn-revoke-license update error:', JSON.stringify(updErr));
      return json({ error: 'Could not update license status' }, 500);
    }

    const note = revType === 'at_will_30_days' && action === 'revoke'
      ? 'at-will: effective in 30 days'
      : (body.reason ?? null);
    await service.from('lkn_agreement_events').insert({
      agreement_id: ag.id,
      event_type: action === 'suspend' ? 'suspended' : 'revoked',
      actor_user_id: user.id,
      notes: note,
    });

    return json({ license_id: ag.license_id, status: newStatus }, 200);
  } catch (err) {
    console.error('lkn-revoke-license error:', err);
    return json({ error: 'Internal server error' }, 500);
  }
});
