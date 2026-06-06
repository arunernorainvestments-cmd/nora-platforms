// ubi-assemble-voting-panel: Internal — assembles a random voting panel.
// Called by ubi-ai-evaluate (when request reaches pending_vote) and
// by process_ubi_vote_deadlines (inconclusive outcome reassembly).

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

serve(async (req) => {
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  );

  let body: { request_id: string; vote_round: number };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Invalid JSON body' }), { status: 400 });
  }

  const { request_id, vote_round } = body;
  if (!request_id || !vote_round) {
    return new Response(JSON.stringify({ error: 'request_id and vote_round required' }), { status: 400 });
  }

  try {
    await assemblePanelForRequest(request_id, vote_round, supabase);
    return new Response(JSON.stringify({ ok: true }), { status: 200 });
  } catch (e) {
    console.error('[ubi-assemble-panel] Error:', e);
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});

async function assemblePanelForRequest(
  requestId: string,
  voteRound: number,
  supabase: SupabaseClient
) {
  const { data: request } = await supabase
    .from('ubi_withdrawal_requests')
    .select('requester_user_id, amount_requested_usd_cents')
    .eq('id', requestId)
    .single();

  if (!request) throw new Error('Request not found: ' + requestId);

  const panelSize = request.amount_requested_usd_cents <= 10000 ? 11
    : request.amount_requested_usd_cents <= 50000 ? 21
    : 51;

  // Exclude requester and (for revote) all round-1 voters
  let excludedUserIds: string[] = [request.requester_user_id];
  if (voteRound === 2) {
    const { data: round1 } = await supabase
      .from('ubi_panel_assignments')
      .select('voter_user_id')
      .eq('request_id', requestId);
    excludedUserIds = [
      ...excludedUserIds,
      ...(round1?.map((a: { voter_user_id: string }) => a.voter_user_id) ?? []),
    ];
  }

  // Fisher-Yates random selection from eligible voter pool
  const { data: allVoters } = await supabase
    .from('ubi_eligible_voters')
    .select('user_id');

  const eligible = (allVoters ?? []).filter(
    (v: { user_id: string }) => !excludedUserIds.includes(v.user_id)
  );

  if (eligible.length === 0) {
    console.warn('[ubi-assemble-panel] No eligible voters for request', requestId);
    return;
  }

  // Fisher-Yates shuffle
  const shuffled = [...eligible];
  for (let i = shuffled.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
  }
  const selected = shuffled.slice(0, Math.min(panelSize, shuffled.length));

  const now = new Date();
  const closesAt = new Date(now.getTime() + 72 * 60 * 60 * 1000).toISOString();

  const { data: panel, error: panelError } = await supabase
    .from('ubi_voting_panels')
    .insert({
      request_id: requestId,
      vote_round: voteRound,
      panel_size: selected.length,
      status: 'open',
      opened_at: now.toISOString(),
      closes_at: closesAt,
    })
    .select()
    .single();

  if (panelError || !panel) {
    throw new Error('Failed to create panel: ' + (panelError?.message ?? 'unknown'));
  }

  const personalDeadline = new Date(now.getTime() + 24 * 60 * 60 * 1000).toISOString();
  await supabase.from('ubi_panel_assignments').insert(
    selected.map((v: { user_id: string }) => ({
      panel_id: panel.id,
      request_id: requestId,
      voter_user_id: v.user_id,
      assignment_status: 'pending',
      notified_at: now.toISOString(),
      personal_deadline: personalDeadline,
    }))
  );

  const newStatus = voteRound === 1 ? 'voting' : 'revote_voting';
  await supabase.from('ubi_withdrawal_requests')
    .update({ status: newStatus })
    .eq('id', requestId);

  // Send in-app notifications to each assigned voter
  for (const v of selected) {
    await supabase.from('notifications').insert({
      user_id: v.user_id,
      type: 'ubi_vote_assignment',
      title: 'Emergency Fund — Community Vote',
      body: 'You have been selected to vote on an Emergency Fund request.',
      link: `/emergency-fund/vote/${panel.id}`,
    }).catch((e: Error) => console.error('[ubi-assemble-panel] notification error:', e.message));
  }
}
