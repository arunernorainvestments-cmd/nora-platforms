-- Migration 011: Add 'refund' to token_transactions type constraint
-- Already applied directly in Supabase SQL Editor

ALTER TABLE public.token_transactions
DROP CONSTRAINT IF EXISTS token_transactions_type_check;

ALTER TABLE public.token_transactions
ADD CONSTRAINT token_transactions_type_check
CHECK (type IN (
  'signup_bonus', 'bet_placed', 'bet_won', 'bet_lost',
  'promoted', 'purchased', 'verification_bonus',
  'referral_bonus', 'refund'
));
