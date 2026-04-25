-- Migration 022: Waitlist table
-- Documents the waitlist table that was created directly in the SQL Editor
-- before the migration history was established. Safe to run on a fresh schema;
-- the IF NOT EXISTS guards make it idempotent on the live DB.

CREATE TABLE IF NOT EXISTS public.waitlist (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email       text NOT NULL,
  created_at  timestamptz DEFAULT now(),
  source      text,
  approved_at timestamptz,
  CONSTRAINT waitlist_email_key UNIQUE (email)
);

ALTER TABLE public.waitlist ENABLE ROW LEVEL SECURITY;

-- Anyone (including logged-out visitors) can submit their email.
-- No SELECT policy — the anon role cannot read rows (count query returns 0
-- for unauthenticated users, which is intentional; the UI uses a hardcoded
-- floor while organic signups are low).
CREATE POLICY allow_anon_insert ON public.waitlist
  FOR INSERT
  WITH CHECK (true);
