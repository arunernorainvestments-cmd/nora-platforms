// supabase/functions/record-invite-send/index.ts
//
// Called when an authenticated user copies or shares their invite link.
// Awards 10 tokens per send, capped at 5 rewarded sends per calendar day (UTC).
// Returns: { awarded: bool, tokens_earned: number, sends_today: number, sends_remaining: number }
//
// Authentication: User JWT required (Flutter client).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const TOKENS_PER_SEND = 10;
const MAX_DAILY_SENDS  = 5;

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  const supabaseUrl     = Deno.env.get('SUPABASE_URL')!;
  const anonKey         = Deno.env.get('SUPABASE_ANON_KEY')!;
  const serviceRoleKey  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const authHeader      = req.headers.get('Authorization') ?? '';

  // Verify the user JWT and extract user id
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authErr } = await userClient.auth.getUser();
  if (authErr || !user) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  const db = createClient(supabaseUrl, serviceRoleKey);
  const userId = user.id;

  try {
    // Skip test accounts
    const { data: profile } = await db
      .from('profiles')
      .select('is_test_account')
      .eq('id', userId)
      .maybeSingle();

    if (profile?.is_test_account) {
      return ok({ awarded: false, tokens_earned: 0, sends_today: 0, sends_remaining: MAX_DAILY_SENDS });
    }

    // Count rewarded sends for today (UTC calendar day)
    const todayStart = new Date();
    todayStart.setUTCHours(0, 0, 0, 0);

    const { count: sendsToday } = await db
      .from('invite_link_sends')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', userId)
      .gte('sent_at', todayStart.toISOString());

    const currentCount = sendsToday ?? 0;
    const canAward = currentCount < MAX_DAILY_SENDS;

    if (!canAward) {
      return ok({
        awarded:          false,
        tokens_earned:    0,
        sends_today:      currentCount,
        sends_remaining:  0,
      });
    }

    // Record the send
    await db.from('invite_link_sends').insert({
      user_id:        userId,
      tokens_awarded: TOKENS_PER_SEND,
    });

    // Award tokens
    const { error: creditErr } = await db.rpc('increment_token_balance', {
      p_user_id: userId,
      p_amount:  TOKENS_PER_SEND,
    });
    if (creditErr) {
      console.error('Token award failed:', creditErr);
      return new Response(JSON.stringify({ error: 'Token award failed' }), {
        status: 500, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    await db.from('token_transactions').insert({
      user_id:      userId,
      type:         'invite_send_reward',
      amount:       TOKENS_PER_SEND,
      description:  'Invite link shared',
    });

    const newCount = currentCount + 1;
    return ok({
      awarded:         true,
      tokens_earned:   TOKENS_PER_SEND,
      sends_today:     newCount,
      sends_remaining: Math.max(0, MAX_DAILY_SENDS - newCount),
    });
  } catch (err) {
    console.error('record-invite-send error:', err);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }
});

function ok(data: Record<string, unknown>): Response {
  return new Response(JSON.stringify({ success: true, ...data }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}
