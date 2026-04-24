import { createClient } from '@supabase/supabase-js'

export const SUPABASE_URL = 'https://cceisywxwhgljdpisjrl.supabase.co'
export const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNjZWlzeXd4d2hnbGpkcGlzanJsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzUzMzc3MzMsImV4cCI6MjA5MDkxMzczM30.feu_2g5erRI3eah0OotjdD5uxB9hjfJJu-f5CmwI-Pw'

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY)

export async function sbFetch(path) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
    },
  })
  if (!res.ok) return []
  return res.json()
}

export async function sbFetchAuth(path, session) {
  const token = session?.access_token ?? SUPABASE_ANON_KEY
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${token}`,
    },
  })
  if (!res.ok) return null
  return res.json()
}
