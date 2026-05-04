// supabase/functions/hot-topic-reset-week/index.ts
// Runs Monday 7 AM ET (11:00 UTC) via pg_cron. Also callable manually for testing.
// Initializes a new week's scores at 1,000 points for all active celebs.
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': 'https://noraplatforms.com',
  'Access-Control-Allow-Headers': 'content-type, authorization',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

function getIsoWeekId(date: Date): string {
  const d = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
  const dayNum = d.getUTCDay() || 7;
  d.setUTCDate(d.getUTCDate() + 4 - dayNum);
  const yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
  const weekNum = Math.ceil((((d.getTime() - yearStart.getTime()) / 86400000) + 1) / 7);
  return `${d.getUTCFullYear()}-${weekNum.toString().padStart(2, '0')}`;
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });

  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ error: 'Server misconfigured' }, 500);
  }

  const db = createClient(supabaseUrl, serviceRoleKey);
  const weekId = getIsoWeekId(new Date());

  // Initialize weekly scores (ON CONFLICT DO NOTHING — safe to re-run)
  const { data: initResult, error: initError } = await db.rpc('initialize_hot_topic_week', {
    p_week_id: weekId,
  });

  if (initError) {
    return jsonResponse({ error: 'Failed to initialize week', detail: initError.message }, 500);
  }

  // Fetch all celebs to insert reset history rows
  const { data: celebs } = await db
    .from('celebs')
    .select('id')
    .eq('active', true);

  if (celebs && celebs.length > 0) {
    const now = new Date().toISOString();
    await db.from('celeb_score_history').insert(
      (celebs as Array<{ id: string }>).map((c) => ({
        week_id: weekId,
        celeb_id: c.id,
        tier: 'Neutral',
        delta: 0,
        story_volume: 0,
        reason_text: 'Weekly reset',
        scoring_window: null,
        scored_at: now,
      })),
    );
  }

  return jsonResponse({
    week_id: weekId,
    rows_initialized: initResult ?? 0,
  });
});
