-- ============================================
-- ALTER PROFILES: user type flags + referral
-- ============================================

alter table public.profiles
  add column is_market_maker boolean default false,
  add column market_maker_opted_in_at timestamptz,
  add column pending_opt_out boolean default false,
  add column popularity_score_public boolean default false,
  add column referral_code text unique,
  add column referred_by uuid references public.profiles(id);

-- ============================================
-- NOTIFICATIONS
-- ============================================

create table public.notifications (
  id uuid default uuid_generate_v4() primary key,
  user_id uuid references public.profiles(id) on delete cascade,
  type text not null check (type in (
    'market_opened',
    'bet_won',
    'bet_lost',
    'market_closing_soon',
    'referral_bonus',
    'token_earned'
  )),
  title text not null,
  body text not null,
  reference_id uuid,
  is_read boolean default false,
  created_at timestamptz default now()
);

-- ============================================
-- ALTER MARKETS: track who opened the market
-- ============================================

alter table public.markets
  add column opened_by uuid references public.profiles(id);

-- ============================================
-- ROW LEVEL SECURITY
-- ============================================

alter table public.notifications enable row level security;

create policy "Users can read own notifications"
  on public.notifications for select using (auth.uid() = user_id);

create policy "Users can update own notifications"
  on public.notifications for update using (auth.uid() = user_id);

create policy "Service role can insert notifications"
  on public.notifications for insert with check (auth.role() = 'service_role');

-- ============================================
-- UPDATE handle_new_user() TRIGGER
-- Additions on top of migration 002:
--   1. Auto-generate a unique referral_code
--   2. If raw_user_meta_data contains 'referred_by_code', look up the
--      referrer's profile and:
--        a. Set referred_by on the new profile
--        b. Grant the referrer +25 tokens (balance + transaction)
-- ============================================

create or replace function public.handle_new_user()
returns trigger as $$
declare
  v_referral_code     text;
  v_referred_by_code  text;
  v_referrer_id       uuid;
begin
  -- Generate a unique 8-char hex referral code
  loop
    v_referral_code := lower(substring(md5(random()::text), 1, 8));
    exit when not exists (
      select 1 from public.profiles where referral_code = v_referral_code
    );
  end loop;

  -- Resolve referrer if a code was passed in metadata
  v_referred_by_code := new.raw_user_meta_data->>'referred_by_code';
  if v_referred_by_code is not null then
    select id into v_referrer_id
    from public.profiles
    where referral_code = v_referred_by_code;
  end if;

  -- Create profile
  insert into public.profiles (id, display_name, avatar_url, referral_code, referred_by)
  values (
    new.id,
    new.raw_user_meta_data->>'full_name',
    new.raw_user_meta_data->>'avatar_url',
    v_referral_code,
    v_referrer_id
  );

  -- Create fiat balance
  insert into public.balances (user_id) values (new.id);

  -- Grant signup token bonus
  insert into public.token_balances (user_id, available_tokens, lifetime_earned)
  values (new.id, 100, 100);

  insert into public.token_transactions (user_id, type, amount, description)
  values (new.id, 'signup_bonus', 100, 'Welcome bonus — 100 free tokens');

  -- Grant referrer bonus if a valid code was provided
  if v_referrer_id is not null then
    update public.token_balances
    set available_tokens = available_tokens + 25,
        lifetime_earned  = lifetime_earned  + 25,
        updated_at       = now()
    where user_id = v_referrer_id;

    insert into public.token_transactions (user_id, type, amount, reference_id, description)
    values (v_referrer_id, 'referral_bonus', 25, new.id, 'Referral bonus — new user signed up with your code');
  end if;

  return new;
end;
$$ language plpgsql security definer;
