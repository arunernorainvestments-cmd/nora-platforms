-- 167: stash the user's chosen card name on the generation ledger (POC gap 2).
-- The name only ever lived in the cinematic-mint request body, so any resume that
-- re-entered the wizard (held-for-review, parked render, closed tab) re-seeded the
-- Review step from the classifier's suggested_name and the chosen name was lost.
-- cinematic-mint writes it at ledger time; moment-ingest surfaces it to the wizard
-- as the resume draft. Display-only draft state — the chit's real name is set at
-- completion (cinematic_complete_mint p_name), never read back from here.
ALTER TABLE public.cinematic_generations
  ADD COLUMN IF NOT EXISTS requested_name TEXT;
