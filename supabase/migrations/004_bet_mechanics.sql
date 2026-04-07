-- ============================================
-- MIGRATION 004: Bet mechanics & market maker triggers
-- ============================================

-- ============================================
-- FIX: add missing types to token_transactions check constraint
-- Migration 002 omitted 'referral_bonus' (used by migration 003) and
-- we now add 'bet_placed' for bets.
-- ============================================

alter table public.token_transactions
  drop constraint token_transactions_type_check;

alter table public.token_transactions
  add constraint token_transactions_type_check check (type in (
    'signup_bonus',
    'bet_placed',
    'bet_won',
    'bet_lost',
    'promoted',
    'purchased',
    'verification_bonus',
    'referral_bonus'
  ));

-- ============================================
-- TRIGGER: UPDATE MARKET POOL SIZES ON BET INSERT
-- Runs as security definer so it can update markets regardless of RLS.
-- The markets table has no client-side update policy, so pool size
-- updates are handled exclusively via this trigger.
-- ============================================

create or replace function public.handle_bet_pool_update()
returns trigger as $$
begin
  if new.position = 'yes' then
    update public.markets
       set yes_pool = yes_pool + new.amount
     where id = new.market_id;
  elsif new.position = 'no' then
    update public.markets
       set no_pool = no_pool + new.amount
     where id = new.market_id;
  end if;
  return new;
end;
$$ language plpgsql security definer;

create trigger on_bet_inserted_update_pools
  after insert on public.bets
  for each row execute procedure public.handle_bet_pool_update();

-- ============================================
-- TRIGGER: DEDUCT TOKENS ON BET INSERT
-- Deducts from token_balances and records a bet_placed transaction.
-- Raises an exception if the user has insufficient tokens — this causes
-- the entire INSERT (including the bet row) to be rolled back.
-- ============================================

create or replace function public.handle_bet_token_deduction()
returns trigger as $$
begin
  -- Deduct tokens; fails the transaction if balance is insufficient
  update public.token_balances
     set available_tokens = available_tokens - new.amount::integer,
         lifetime_spent   = lifetime_spent   + new.amount::integer,
         updated_at       = now()
   where user_id          = new.user_id
     and available_tokens >= new.amount::integer;

  if not found then
    raise exception 'Insufficient token balance';
  end if;

  -- Record the spend
  insert into public.token_transactions (user_id, type, amount, reference_id, description)
  values (
    new.user_id,
    'bet_placed',
    new.amount::integer,
    new.id,
    'Bet placed on market'
  );

  return new;
end;
$$ language plpgsql security definer;

create trigger on_bet_inserted_deduct_tokens
  after insert on public.bets
  for each row execute procedure public.handle_bet_token_deduction();

-- ============================================
-- TRIGGER: NOTIFY MARKET MAKER WHEN A BET IS PLACED ON THEIR MARKET
-- Does not notify if the creator bets on their own market.
-- ============================================

create or replace function public.handle_bet_notify_creator()
returns trigger as $$
declare
  v_creator_id  uuid;
  v_timeframe   text;
  v_bettor_name text;
begin
  select creator_id, timeframe
    into v_creator_id, v_timeframe
    from public.markets
   where id = new.market_id;

  -- Skip if the creator is betting on their own market
  if v_creator_id = new.user_id then
    return new;
  end if;

  select coalesce(username, 'someone')
    into v_bettor_name
    from public.profiles
   where id = new.user_id;

  insert into public.notifications (user_id, type, title, body, reference_id)
  values (
    v_creator_id,
    'market_opened',
    'New market on your profile',
    '@' || v_bettor_name || ' opened a ' || v_timeframe || ' market on your popularity',
    new.market_id
  );

  return new;
end;
$$ language plpgsql security definer;

create trigger on_bet_inserted_notify_creator
  after insert on public.bets
  for each row execute procedure public.handle_bet_notify_creator();

-- ============================================
-- TODO: migration 004 should add a public read policy for the
-- social_connections table that exposes the `platform` column only.
-- PostgreSQL RLS is row-level, so true column-level restriction requires
-- a security-definer view or function. A minimal approach:
--
--   create or replace view public.social_connections_public
--     security_invoker = false  -- PostgreSQL 15+ required
--   as
--     select user_id, platform
--       from public.social_connections
--      where is_active = true;
--
--   grant select on public.social_connections_public to anon, authenticated;
--
-- Until this is implemented the public profile screen shows no connected
-- platforms for other users (the existing try/catch handles this gracefully).
-- ============================================
