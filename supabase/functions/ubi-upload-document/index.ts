// ubi-upload-document: Authenticated endpoint for uploading supporting documents.
// Documents are stored in the PRIVATE 'ubi-documents' Storage bucket.
// Hard Rule #2: paths/signed URLs are NEVER returned to the client.
// After upload, triggers ubi-ai-evaluate pass 2.

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const ALLOWED_MIME_TYPES = ['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];
const MAX_FILE_SIZE_BYTES = 10 * 1024 * 1024; // 10 MB

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401, headers: CORS });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  );
  const userClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } }
  );

  const { data: { user } } = await userClient.auth.getUser();
  if (!user) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401, headers: CORS });
  }

  // Parse multipart form data
  let formData: FormData;
  try {
    formData = await req.formData();
  } catch {
    return new Response(JSON.stringify({ error: 'Expected multipart form data' }), { status: 400, headers: CORS });
  }

  const requestId = formData.get('request_id') as string | null;
  const documentType = formData.get('document_type') as string | null;
  const documentLabel = formData.get('document_label') as string | null;
  const file = formData.get('file') as File | null;

  if (!requestId || !documentType || !documentLabel || !file) {
    return new Response(JSON.stringify({ error: 'request_id, document_type, document_label, and file required' }), {
      status: 400, headers: CORS,
    });
  }

  // Verify the request belongs to this user and is in pending_documents state
  const { data: request } = await supabase
    .from('ubi_withdrawal_requests')
    .select('id, status, requester_user_id')
    .eq('id', requestId)
    .eq('requester_user_id', user.id)
    .single();

  if (!request) {
    return new Response(JSON.stringify({ error: 'Request not found' }), { status: 404, headers: CORS });
  }
  if (request.status !== 'pending_documents') {
    return new Response(JSON.stringify({ error: 'Request is not awaiting documents' }), { status: 400, headers: CORS });
  }

  // Validate file
  const mimeType = file.type;
  if (!ALLOWED_MIME_TYPES.includes(mimeType)) {
    return new Response(JSON.stringify({ error: 'File type not allowed. Use PDF, JPEG, PNG, or WebP.' }), {
      status: 400, headers: CORS,
    });
  }
  if (file.size > MAX_FILE_SIZE_BYTES) {
    return new Response(JSON.stringify({ error: 'File too large. Maximum 10 MB.' }), { status: 400, headers: CORS });
  }

  // Upload to private 'ubi-documents' bucket
  // Path: {requestId}/{userId}/{timestamp}-{sanitizedFilename}
  const ext = file.name.split('.').pop() ?? 'bin';
  const storagePath = `${requestId}/${user.id}/${Date.now()}-${documentType}.${ext}`;

  const fileBuffer = await file.arrayBuffer();
  const { error: uploadError } = await supabase.storage
    .from('ubi-documents')
    .upload(storagePath, fileBuffer, {
      contentType: mimeType,
      upsert: false,
    });

  if (uploadError) {
    console.error('[ubi-upload-document] Storage upload error:', uploadError.message);
    return new Response(JSON.stringify({ error: 'Upload failed' }), { status: 500, headers: CORS });
  }

  // Record document row — storage_path is NEVER returned to the client
  const { error: insertError } = await supabase
    .from('ubi_request_documents')
    .insert({
      request_id: requestId,
      requester_user_id: user.id,
      document_type: documentType,
      document_label: documentLabel,
      storage_path: storagePath,    // internal only
      file_name: file.name,
      file_size_bytes: file.size,
      mime_type: mimeType,
    });

  if (insertError) {
    console.error('[ubi-upload-document] DB insert error:', insertError.message);
    return new Response(JSON.stringify({ error: 'Failed to record document' }), { status: 500, headers: CORS });
  }

  // Check if all requested documents have been uploaded, then trigger pass 2
  const { data: evaluation } = await supabase
    .from('ubi_ai_evaluations')
    .select('documents_requested')
    .eq('request_id', requestId)
    .eq('evaluation_pass', 1)
    .maybeSingle();

  const { data: uploadedDocs } = await supabase
    .from('ubi_request_documents')
    .select('document_type')
    .eq('request_id', requestId);

  const requestedTypes: string[] = (evaluation?.documents_requested ?? []).map(
    (d: { type: string }) => d.type
  );
  const uploadedTypes = (uploadedDocs ?? []).map((d: { document_type: string }) => d.document_type);
  const allUploaded = requestedTypes.every(t => uploadedTypes.includes(t));

  if (allUploaded) {
    // Trigger AI pass 2 (async)
    fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/ubi-ai-evaluate`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`,
      },
      body: JSON.stringify({ request_id: requestId, evaluation_pass: 2 }),
    }).catch((e: Error) => console.error('[ubi-upload-document] AI pass 2 trigger failed:', e.message));
  }

  // Return only metadata — never return storage_path or signed URLs
  return new Response(JSON.stringify({
    document_type: documentType,
    file_name: file.name,
    all_documents_uploaded: allUploaded,
  }), { status: 200, headers: CORS });
});
