// supabase/functions/nora-arena-api-token-balance/index.ts
//
// doc6 mobile-API convenience endpoint: the authenticated user's current token
// balance for Arena betting. Thin read over token_balances. Auth is the Supabase
// session JWT (same account as web). Deploy WITH jwt verification.
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'GET') return json({ error: 'Method not allowed' }, 405);

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

    // RLS already scopes token_balances to the caller; the session client is enough.
    const { data, error } = await supabase
      .from('token_balances')
      .select('available_tokens, lifetime_earned, lifetime_spent')
      .eq('user_id', user.id)
      .maybeSingle();
    if (error) {
      console.error('nora-arena-api-token-balance lookup error:', JSON.stringify(error));
      return json({ error: 'lookup_failed' }, 500);
    }

    return json({
      nora_id: user.id,
      available_tokens: data?.available_tokens ?? 0,
      lifetime_earned: data?.lifetime_earned ?? 0,
      lifetime_spent: data?.lifetime_spent ?? 0,
    }, 200);
  } catch (err) {
    console.error('nora-arena-api-token-balance error:', err);
    return json({ error: 'Internal server error' }, 500);
  }
});
