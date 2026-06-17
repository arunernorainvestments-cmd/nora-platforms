// supabase/functions/lkn-partner-apply/index.ts
//
// N.O.R.A. Partners Portal intake. Management/labels/legal reps apply to act on
// behalf of talent. Public endpoint — deploy with --no-verify-jwt.
// Documents are uploaded separately to the private 'lkn-partner-docs' bucket;
// the caller passes the resulting storage paths here.
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

const REP_TYPES = new Set(['management', 'label', 'legal', 'publicist', 'studio', 'agency', 'other']);

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  try {
    let body: {
      company_name?: string;
      representative_name?: string;
      representative_email?: string;
      representative_phone?: string;
      company_website?: string;
      talent_names?: string[];
      representation_type?: string;
      document_storage_paths?: string[];
    };
    try { body = await req.json(); } catch { return json({ error: 'Invalid JSON body' }, 400); }

    const company = (body.company_name ?? '').trim();
    const repName = (body.representative_name ?? '').trim();
    const repEmail = (body.representative_email ?? '').trim();
    const talent = (body.talent_names ?? []).map((t) => String(t).trim()).filter(Boolean);

    if (!company || !repName || !repEmail) {
      return json({ error: 'company_name, representative_name and representative_email are required' }, 400);
    }
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(repEmail)) {
      return json({ error: 'representative_email is not a valid email' }, 400);
    }
    if (talent.length < 1) return json({ error: 'list at least one talent name' }, 400);
    if (!body.representation_type || !REP_TYPES.has(body.representation_type)) {
      return json({ error: 'invalid representation_type' }, 400);
    }

    const service = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: partner, error } = await service.from('lkn_partners').insert({
      company_name: company,
      representative_name: repName,
      representative_email: repEmail,
      representative_phone: body.representative_phone ?? null,
      company_website: body.company_website ?? null,
      talent_names: talent,
      representation_type: body.representation_type,
      document_storage_paths: body.document_storage_paths ?? [],
      status: 'submitted',
    }).select('id').single();
    if (error || !partner) {
      console.error('lkn-partner-apply insert error:', JSON.stringify(error));
      return json({ error: 'Could not submit application' }, 500);
    }

    return json({
      application_id: partner.id,
      status: 'submitted',
      expected_review_days: 5,
      message: 'Application received. N.O.R.A. will review within 5 business days.',
    }, 201);
  } catch (err) {
    console.error('lkn-partner-apply error:', err);
    return json({ error: 'Internal server error' }, 500);
  }
});
