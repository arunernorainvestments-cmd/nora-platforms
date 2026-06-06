// supabase/functions/celebrity-integration-seed/index.ts
// One-time admin function. Gate with x-admin-key header = ADMIN_SEED_KEY env var.
// Deploy with --no-verify-jwt. Run ONCE after migration 087 lands.
//
// For each celeb without is_integrated = TRUE:
//   1. Create Supabase auth user (fake managed email, random password, no login path)
//   2. Insert profiles row (is_celeb=TRUE, managed_by_platform=TRUE)
//   3. Mark celebs.is_integrated = TRUE
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': 'https://noraplatforms.com',
  'Access-Control-Allow-Headers': 'content-type, x-admin-key',
  'Content-Type': 'application/json',
};

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS });
  }

  // Admin-key gate
  const adminKey = req.headers.get('x-admin-key');
  if (adminKey !== Deno.env.get('ADMIN_SEED_KEY') || !adminKey) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401,
      headers: CORS,
    });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  // Load all celebs not yet integrated
  const { data: celebs, error: celebsErr } = await supabase
    .from('celebs')
    .select('id, name, slug')
    .eq('is_integrated', false);

  if (celebsErr) throw celebsErr;
  if (!celebs || celebs.length === 0) {
    return new Response(JSON.stringify({ seeded: 0, message: 'All celebs already integrated' }), {
      status: 200,
      headers: CORS,
    });
  }

  const results: Array<{ celeb_id: string; profile_id: string; status: string }> = [];

  for (const celeb of celebs) {
    try {
      const managedEmail = `celeb-${celeb.id}@managed.noraplatforms.com`;

      // Create auth user (service role bypasses email confirmation)
      const { data: authData, error: authErr } = await supabase.auth.admin.createUser({
        email: managedEmail,
        password: crypto.randomUUID() + crypto.randomUUID(), // random, never used
        email_confirm: true,
      });

      if (authErr || !authData.user) {
        console.error(`[seed] auth create failed for celeb ${celeb.id}:`, authErr?.message);
        results.push({ celeb_id: celeb.id, profile_id: '', status: 'auth_failed' });
        continue;
      }

      const userId = authData.user.id;

      // Insert profile
      const { error: profileErr } = await supabase.from('profiles').upsert({
        id: userId,
        username: celeb.slug ?? `celeb_${celeb.id.slice(0, 8)}`,
        display_name: celeb.name,
        is_celeb: true,
        celeb_id: celeb.id,
        managed_by_platform: true,
        is_market_maker: true,
        pending_opt_out: false,
        is_approved: true,
      }, { onConflict: 'id' });

      if (profileErr) {
        console.error(`[seed] profile upsert failed for celeb ${celeb.id}:`, profileErr.message);
        results.push({ celeb_id: celeb.id, profile_id: userId, status: 'profile_failed' });
        continue;
      }

      // Link celeb → profile + mark integrated
      const { error: celebUpdateErr } = await supabase
        .from('celebs')
        .update({ profile_id: userId, is_integrated: true })
        .eq('id', celeb.id);

      if (celebUpdateErr) {
        console.error(`[seed] celebs update failed for ${celeb.id}:`, celebUpdateErr.message);
        results.push({ celeb_id: celeb.id, profile_id: userId, status: 'celebs_update_failed' });
        continue;
      }

      results.push({ celeb_id: celeb.id, profile_id: userId, status: 'ok' });
      console.log(`[seed] celeb ${celeb.name} (${celeb.id}) → profile ${userId}`);
    } catch (e) {
      console.error(`[seed] unexpected error for celeb ${celeb.id}:`, e);
      results.push({ celeb_id: celeb.id, profile_id: '', status: 'error' });
    }
  }

  const seeded = results.filter((r) => r.status === 'ok').length;
  return new Response(JSON.stringify({ seeded, total: celebs.length, results }), {
    status: 200,
    headers: CORS,
  });
});
