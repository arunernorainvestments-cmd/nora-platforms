// ubi-ai-evaluate: Internal AI evaluation for Emergency Fund requests.
// Called by ubi-submit-request (pass 1) and ubi-upload-document (pass 2).
// The AI never makes a funding recommendation — it facilitates the process only.
// Hard Rule: ANTHROPIC_API_KEY read from env, never hardcoded.

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const ANTHROPIC_API = 'https://api.anthropic.com/v1/messages';

const AI_SYSTEM_PROMPT = `You are an intake coordinator for the N.O.R.A. Emergency Fund,
a community mutual aid pool. Your job is to help structure withdrawal requests so that
a community voting panel can make an informed decision.

Your responsibilities:
1. Evaluate whether the request falls within the fund's scope (genuine emergency needs).
2. Determine what supporting documents, if any, are appropriate to request.
3. Write a neutral, factual summary of the request for the voting panel.

Hard rules you must never violate:
- NEVER recommend that the voting panel approve or deny the request.
- NEVER include the applicant's name, location, employer, specific medical facility,
  or any other personally identifying information in the voter summary.
- Describe situations in general terms: "unexpected medical procedure" not
  "appendectomy at [Hospital Name] on [Date]".
- Be compassionate but objective. Assume good faith unless documents are inconsistent.
- If the request is outside the fund's scope (e.g., luxury purchases, business investments,
  gambling debts), set within_fund_scope to false. The request will not proceed to a vote.

Fund scope covers: medical expenses, housing emergencies (rent, eviction, repairs),
utility shutoffs, food insecurity, childcare emergencies, transportation needed for
employment, funeral/burial costs, natural disaster recovery.

Document request guidelines by category:
- medical: Explanation of Benefits, medical bill, or hospital statement
- housing: Eviction notice, rent ledger, or lease + landlord communication
- utilities: Utility shutoff notice or past-due bill
- food/childcare: No documents required for small amounts — narrative is sufficient
- transportation: Repair estimate or mechanic invoice
- funeral: Death certificate and/or funeral home invoice
- disaster: Insurance claim, official disaster declaration, or news reference
- other: Use judgment — request only what is genuinely needed

Respond ONLY in valid JSON. No preamble, no markdown.`;

interface EvaluationResult {
  within_fund_scope: boolean;
  documents_requested: Array<{ type: string; label: string; rationale: string }>;
  voter_summary: string;
  internal_assessment: string;
  documents_consistent?: boolean;
  requires_additional_docs?: Array<{ type: string; label: string; rationale: string }>;
}

serve(async (req) => {
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  );

  const anthropicKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!anthropicKey) {
    console.error('[ubi-ai-evaluate] ANTHROPIC_API_KEY not set');
    return new Response(JSON.stringify({ error: 'AI evaluation unavailable' }), { status: 503 });
  }

  let body: { request_id: string; evaluation_pass: number };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Invalid JSON body' }), { status: 400 });
  }

  const { request_id, evaluation_pass } = body;
  if (!request_id || !evaluation_pass) {
    return new Response(JSON.stringify({ error: 'request_id and evaluation_pass required' }), { status: 400 });
  }

  const { data: request } = await supabase
    .from('ubi_withdrawal_requests')
    .select('*, ubi_request_documents(*)')
    .eq('id', request_id)
    .single();

  if (!request) {
    return new Response(JSON.stringify({ error: 'Request not found' }), { status: 404 });
  }

  const userMessageContent: unknown[] = [];

  if (evaluation_pass === 1) {
    userMessageContent.push({
      type: 'text',
      text: JSON.stringify({
        task: 'initial_evaluation',
        emergency_category: request.emergency_category,
        amount_requested_usd: (request.amount_requested_usd_cents / 100).toFixed(2),
        applicant_narrative: request.request_narrative,
        instructions: `Evaluate this request. Determine if it is within scope, what documents
to request (if any), and write a neutral voter summary. Respond in JSON matching this schema:
{ within_fund_scope: boolean, documents_requested: [{type, label, rationale}],
voter_summary: string, internal_assessment: string }`,
      }),
    });
  }

  if (evaluation_pass === 2) {
    const docs: Array<{
      ai_reviewed: boolean;
      mime_type: string;
      storage_path: string;
    }> = request.ubi_request_documents ?? [];

    userMessageContent.push({
      type: 'text',
      text: `You previously requested supporting documents for this ${request.emergency_category} emergency request of $${(request.amount_requested_usd_cents / 100).toFixed(2)}. The following documents have been uploaded. Review each one and determine if they are consistent with the stated need. Write an updated neutral voter summary reflecting what the documents confirm. Respond in JSON: { documents_consistent: boolean, voter_summary: string, internal_assessment: string, requires_additional_docs: [{type, label, rationale}] }`,
    });

    for (const doc of docs) {
      if (doc.ai_reviewed) continue;

      const { data: fileData } = await supabase.storage
        .from('ubi-documents')
        .download(doc.storage_path);

      if (!fileData) continue;

      const arrayBuffer = await fileData.arrayBuffer();
      const base64 = btoa(String.fromCharCode(...new Uint8Array(arrayBuffer)));

      if (doc.mime_type === 'application/pdf') {
        userMessageContent.push({
          type: 'document',
          source: { type: 'base64', media_type: 'application/pdf', data: base64 },
        });
      } else {
        userMessageContent.push({
          type: 'image',
          source: { type: 'base64', media_type: doc.mime_type, data: base64 },
        });
      }
    }
  }

  // Hard Rule 8: handle HTTP 429 gracefully — log and skip, never throw
  const response = await fetch(ANTHROPIC_API, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': anthropicKey,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({
      model: 'claude-sonnet-4-6',
      max_tokens: 1000,
      system: AI_SYSTEM_PROMPT,
      messages: [{ role: 'user', content: userMessageContent }],
    }),
  });

  if (!response.ok) {
    const status = response.status;
    if (status === 429) {
      console.error('[ubi-ai-evaluate] Anthropic rate limit (429) — log and skip');
    } else {
      console.error('[ubi-ai-evaluate] Anthropic API error:', status);
    }
    return new Response(JSON.stringify({ error: 'AI evaluation temporarily unavailable' }), { status: 503 });
  }

  const apiData = await response.json();
  const rawText = apiData.content?.find((b: { type: string }) => b.type === 'text')?.text ?? '{}';

  let result: EvaluationResult;
  try {
    const clean = rawText.replace(/```json|```/g, '').trim();
    result = JSON.parse(clean);
  } catch {
    console.error('[ubi-ai-evaluate] Failed to parse AI response:', rawText);
    return new Response(JSON.stringify({ error: 'AI response parse error' }), { status: 500 });
  }

  await supabase.from('ubi_ai_evaluations').upsert({
    request_id,
    evaluation_pass,
    documents_requested: result.documents_requested ?? [],
    voter_summary: result.voter_summary ?? null,
    internal_assessment: result.internal_assessment ?? null,
    documents_consistent: result.documents_consistent ?? null,
    requires_additional_docs: result.requires_additional_docs ?? [],
    within_fund_scope: result.within_fund_scope ?? true,
    model_used: 'claude-sonnet-4-6',
    input_tokens: apiData.usage?.input_tokens ?? null,
    output_tokens: apiData.usage?.output_tokens ?? null,
  }, { onConflict: 'request_id,evaluation_pass' });

  if (evaluation_pass === 2) {
    await supabase.from('ubi_request_documents')
      .update({ ai_reviewed: true, ai_reviewed_at: new Date().toISOString() })
      .eq('request_id', request_id);
  }

  if (!result.within_fund_scope) {
    await supabase.from('ubi_withdrawal_requests')
      .update({ status: 'voided' })
      .eq('id', request_id);
    return new Response(JSON.stringify({ outcome: 'out_of_scope' }), { status: 200 });
  }

  const docsNeeded = (result.documents_requested?.length ?? 0) > 0 && evaluation_pass === 1;
  const additionalDocsNeeded = (result.requires_additional_docs?.length ?? 0) > 0 && evaluation_pass === 2;
  const nextStatus = docsNeeded || additionalDocsNeeded ? 'pending_documents' : 'pending_vote';

  await supabase.from('ubi_withdrawal_requests')
    .update({ status: nextStatus })
    .eq('id', request_id);

  // If ready for vote, assemble the panel
  if (nextStatus === 'pending_vote') {
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/ubi-assemble-voting-panel`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${serviceKey}`,
      },
      body: JSON.stringify({ request_id, vote_round: 1 }),
    });
  }

  return new Response(JSON.stringify({
    outcome: nextStatus,
    documents_requested: result.documents_requested ?? [],
  }), { status: 200 });
});
