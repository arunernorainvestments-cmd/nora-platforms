-- Migration 008: Post Phase 4 fixes
-- 1. Add 'purchased' to token_transactions type constraint
-- 2. Fix increment_token_balance to also update lifetime_earned

-- Fix token_transactions type constraint to include 'purchased'
ALTER TABLE public.token_transactions
DROP CONSTRAINT token_transactions_type_check;

ALTER TABLE public.token_transactions
ADD CONSTRAINT token_transactions_type_check
CHECK (type IN ('signup_bonus', 'bet_placed', 'bet_won', 'bet_lost', 'promoted', 'purchased', 'verification_bonus', 'referral_bonus'));

-- Fix increment_token_balance to also increment lifetime_earned
CREATE OR REPLACE FUNCTION public.increment_token_balance(p_user_id UUID, p_amount INTEGER)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  UPDATE public.token_balances
  SET available_tokens = available_tokens + p_amount,
      lifetime_earned = lifetime_earned + p_amount
  WHERE user_id = p_user_id;
$$;
