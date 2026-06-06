// supabase/functions/poll-vote/index.ts
// Public endpoint — deploy with --no-verify-jwt.
// Anti-abuse: IP rate-limit (3/poll), device fingerprint rate-limit (5/poll),
// silent flagging (vote recorded with weight=0, no rejection shown to client).
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { crypto } from 'https://deno.land/std@0.168.0/crypto/mod.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, x-fingerprint',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

async function sha256hex(text: string): Promise<string> {
  const enc = new TextEncoder();
  const buf = await crypto.subtle.digest('SHA-256', enc.encode(text));
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const body = await req.json().catch(() => ({}));
  const { poll_id, poll_option_id, fingerprint } = body as {
    poll_id?: string;
    poll_option_id?: string;
    fingerprint?: string;
  };

  if (!poll_id || !poll_option_id) {
    return new Response(JSON.stringify({ error: 'Missing required fields' }), {
      status: 400,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // ── Verify poll is open ───────────────────────────────────────────────────
  const { data: poll } = await supabase
    .from('weekly_polls')
    .select('id, status, closes_at')
    .eq('id', poll_id)
    .single();

  if (!poll || poll.status !== 'open' || new Date(poll.closes_at) < new Date()) {
    return new Response(JSON.stringify({ error: 'Poll is not open' }), {
      status: 400,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // ── Identity detection ────────────────────────────────────────────────────
  const authHeader = req.headers.get('Authorization');
  let voterUserId: string | null = null;
  let voteWeight = 0.3;

  if (authHeader) {
    const token = authHeader.replace('Bearer ', '');
    const { data: { user } } = await supabase.auth.getUser(token);
    if (user) {
      voterUserId = user.id;
      voteWeight = 1.0;
    }
  }

  // ── Fingerprinting ────────────────────────────────────────────────────────
  const rawIp =
    req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ||
    req.headers.get('cf-connecting-ip') ||
    'unknown';

  const [ipHash, userAgentHash] = await Promise.all([
    sha256hex(rawIp),
    sha256hex(req.headers.get('user-agent') || ''),
  ]);

  const deviceFingerprint: string | null = fingerprint || null;

  // ── Registered user: one vote per poll ───────────────────────────────────
  if (voterUserId) {
    const { data: existing } = await supabase
      .from('poll_votes')
      .select('id')
      .eq('poll_id', poll_id)
      .eq('voter_user_id', voterUserId)
      .maybeSingle();

    if (existing) {
      return new Response(JSON.stringify({ error: 'Already voted in this poll' }), {
        status: 409,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }
  }

  // ── Anonymous: IP rate-limit (max 3 per poll) ─────────────────────────────
  if (!voterUserId) {
    const { count } = await supabase
      .from('poll_votes')
      .select('id', { count: 'exact', head: true })
      .eq('poll_id', poll_id)
      .eq('ip_hash', ipHash)
      .eq('is_flagged', false);

    if ((count ?? 0) >= 3) {
      // Silent accept — don't reveal the limit
      await supabase.from('poll_votes').insert({
        poll_id,
        poll_option_id,
        voter_user_id: null,
        ip_hash: ipHash,
        device_fingerprint: deviceFingerprint,
        user_agent_hash: userAgentHash,
        vote_weight: 0.0,
        is_flagged: true,
        flag_reason: 'ip_rate_limit',
      });
      return new Response(JSON.stringify({ success: true, weight: 0 }), {
        status: 200,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }
  }

  // ── Device fingerprint spike-detection (max 5 per poll) ──────────────────
  let isFlagged = false;
  let flagReason: string | null = null;

  if (deviceFingerprint) {
    const { count: fpCount } = await supabase
      .from('poll_votes')
      .select('id', { count: 'exact', head: true })
      .eq('poll_id', poll_id)
      .eq('device_fingerprint', deviceFingerprint)
      .eq('is_flagged', false);

    if ((fpCount ?? 0) >= 5) {
      isFlagged = true;
      flagReason = 'device_fingerprint_rate_limit';
      voteWeight = 0.0;
    }
  }

  // ── Insert vote ───────────────────────────────────────────────────────────
  const { error: insertError } = await supabase.from('poll_votes').insert({
    poll_id,
    poll_option_id,
    voter_user_id: voterUserId,
    ip_hash: ipHash,
    device_fingerprint: deviceFingerprint,
    user_agent_hash: userAgentHash,
    vote_weight: voteWeight,
    is_flagged: isFlagged,
    flag_reason: flagReason,
  });

  if (insertError) {
    if (insertError.code === '23505') {
      return new Response(JSON.stringify({ error: 'Already voted' }), {
        status: 409,
        headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }
    console.error('[poll-vote] insert error:', insertError);
    return new Response(JSON.stringify({ error: 'Vote failed' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // ── Update running totals (only for non-flagged, non-zero-weight votes) ───
  if (!isFlagged && voteWeight > 0) {
    await supabase.rpc('increment_poll_option_votes', {
      p_option_id: poll_option_id,
      p_weight: voteWeight,
    });
  }

  return new Response(JSON.stringify({ success: true, weight: voteWeight }), {
    status: 200,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
});
