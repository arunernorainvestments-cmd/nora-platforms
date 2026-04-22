-- Migration 021: Beta Approval System
-- Adds manual admin approval gate before any signed-up user can access the app.
-- Also adds approved_at to waitlist so the trigger can auto-approve invited emails.

-- ── 1. Waitlist: track which emails have been admin-approved ─────────────────
ALTER TABLE waitlist
  ADD COLUMN IF NOT EXISTS approved_at timestamptz;

-- ── 2. Profiles: approval flag (default false — must be explicitly granted) ──
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS is_approved boolean NOT NULL DEFAULT false;

-- ── 3. Update handle_new_user() trigger ──────────────────────────────────────
-- If the new user's email is in the waitlist with approved_at set,
-- create their profile already approved. Otherwise they land in pending state.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger AS $$
DECLARE
  v_referral_code     text;
  v_referred_by_code  text;
  v_referrer_id       uuid;
  v_is_approved       boolean;
BEGIN
  -- Generate a unique 8-char hex referral code
  LOOP
    v_referral_code := lower(substring(md5(random()::text), 1, 8));
    EXIT WHEN NOT EXISTS (
      SELECT 1 FROM public.profiles WHERE referral_code = v_referral_code
    );
  END LOOP;

  -- Resolve referrer if a code was passed in metadata
  v_referred_by_code := new.raw_user_meta_data->>'referred_by_code';
  IF v_referred_by_code IS NOT NULL THEN
    SELECT id INTO v_referrer_id
    FROM public.profiles
    WHERE referral_code = v_referred_by_code;
  END IF;

  -- Check if this email was pre-approved on the waitlist
  SELECT (approved_at IS NOT NULL) INTO v_is_approved
  FROM public.waitlist
  WHERE email = lower(new.email)
  LIMIT 1;

  v_is_approved := COALESCE(v_is_approved, false);

  -- Create profile
  INSERT INTO public.profiles (id, display_name, avatar_url, referral_code, referred_by, is_approved)
  VALUES (
    new.id,
    new.raw_user_meta_data->>'full_name',
    new.raw_user_meta_data->>'avatar_url',
    v_referral_code,
    v_referrer_id,
    v_is_approved
  );

  -- Create fiat balance
  INSERT INTO public.balances (user_id) VALUES (new.id);

  -- Grant signup token bonus (held until approved — tokens exist but app is inaccessible)
  INSERT INTO public.token_balances (user_id, available_tokens, lifetime_earned)
  VALUES (new.id, 100, 100);

  INSERT INTO public.token_transactions (user_id, type, amount, description)
  VALUES (new.id, 'signup_bonus', 100, 'Welcome bonus — 100 free tokens');

  -- Grant referrer bonus if a valid code was provided
  IF v_referrer_id IS NOT NULL THEN
    UPDATE public.token_balances
    SET available_tokens = available_tokens + 25,
        lifetime_earned  = lifetime_earned  + 25,
        updated_at       = now()
    WHERE user_id = v_referrer_id;

    INSERT INTO public.token_transactions (user_id, type, amount, reference_id, description)
    VALUES (v_referrer_id, 'referral_bonus', 25, new.id, 'Referral bonus — new user signed up with your code');
  END IF;

  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 4. Convenience function: approve a beta user by email ────────────────────
-- Usage: SELECT approve_beta_user('user@example.com');
-- This stamps the waitlist row AND approves the profile if they already signed up.
CREATE OR REPLACE FUNCTION public.approve_beta_user(p_email text)
RETURNS text AS $$
DECLARE
  v_profile_id uuid;
  v_result     text;
BEGIN
  p_email := lower(trim(p_email));

  -- Mark approved in waitlist (upsert the approved_at timestamp)
  UPDATE public.waitlist
  SET approved_at = now()
  WHERE email = p_email;

  -- If they already have an account, approve their profile immediately
  SELECT au.id INTO v_profile_id
  FROM auth.users au
  WHERE lower(au.email) = p_email
  LIMIT 1;

  IF v_profile_id IS NOT NULL THEN
    UPDATE public.profiles
    SET is_approved = true
    WHERE id = v_profile_id;
    v_result := 'approved — waitlist stamped and profile unlocked for ' || p_email;
  ELSE
    v_result := 'waitlist stamped — profile will be auto-approved when ' || p_email || ' signs up';
  END IF;

  RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
