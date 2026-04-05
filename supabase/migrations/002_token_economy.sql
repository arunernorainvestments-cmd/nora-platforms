-- ============================================
-- TOKEN BALANCES
-- ============================================

create table public.token_balances (
  user_id uuid references public.profiles(id) on delete cascade primary key,
  available_tokens integer not null default 0,
  lifetime_earned integer not null default 0,
  lifetime_spent integer not null default 0,
  updated_at timestamptz default now()
);

-- ============================================
-- TOKEN TRANSACTIONS
-- ============================================

create table public.token_transactions (
  id uuid default uuid_generate_v4() primary key,
  user_id uuid references public.profiles(id) on delete cascade,
  type text not null check (type in (
    'signup_bonus',
    'bet_won',
    'bet_lost',
    'promoted',
    'purchased',
    'verification_bonus'   -- platform connection reward; biometric/KYC bonuses added later
  )),
  amount integer not null,
  reference_id uuid,
  description text,
  created_at timestamptz default now()
);

-- ============================================
-- SPOTLIGHT SCORES
-- ============================================

create table public.spotlight_scores (
  user_id uuid references public.profiles(id) on delete cascade primary key,
  score numeric(12,4) not null default 0,
  tier text not null check (tier in ('on_fire', 'rising', 'watched', 'listed')),
  computed_at timestamptz default now()
);

-- ============================================
-- FAMOUS CREATORS
-- ============================================

create table public.famous_creators (
  id uuid default uuid_generate_v4() primary key,
  name text not null,
  slug text unique not null,
  bio text,
  avatar_url text,
  platform_youtube text,
  platform_tiktok text,
  platform_x text,
  platform_twitch text,
  platform_kick text,
  platform_instagram text,
  total_followers bigint not null default 0,
  is_claimed boolean not null default false,
  created_at timestamptz default now()
);

-- ============================================
-- ROW LEVEL SECURITY
-- ============================================

alter table public.token_balances enable row level security;
alter table public.token_transactions enable row level security;
alter table public.spotlight_scores enable row level security;
alter table public.famous_creators enable row level security;

-- TOKEN BALANCES: users read own row; only service role writes
create policy "Users can view own token balance"
  on public.token_balances for select using (auth.uid() = user_id);

create policy "Service role can insert token balances"
  on public.token_balances for insert with check (auth.role() = 'service_role');

create policy "Service role can update token balances"
  on public.token_balances for update using (auth.role() = 'service_role');

-- TOKEN TRANSACTIONS: users read own rows; only service role inserts
create policy "Users can view own token transactions"
  on public.token_transactions for select using (auth.uid() = user_id);

create policy "Service role can insert token transactions"
  on public.token_transactions for insert with check (auth.role() = 'service_role');

-- SPOTLIGHT SCORES: public read, service role manages writes
create policy "Spotlight scores are publicly readable"
  on public.spotlight_scores for select using (true);

create policy "Service role can manage spotlight scores"
  on public.spotlight_scores for all using (auth.role() = 'service_role');

-- FAMOUS CREATORS: public read
create policy "Famous creators are publicly readable"
  on public.famous_creators for select using (true);

-- ============================================
-- SPOTLIGHT: TIER RECOMPUTATION
-- Ranks all Platform Creators by score and assigns tiers:
--   top 3  → on_fire
--   top 10 → rising
--   top 25 → watched
--   rest   → listed
-- Called at the end of every score upsert so tiers stay
-- consistent across the full leaderboard.
-- ============================================

create or replace function public.recompute_spotlight_tiers()
returns void as $$
begin
  update public.spotlight_scores ss
  set tier = case
    when r.rnk <= 3  then 'on_fire'
    when r.rnk <= 10 then 'rising'
    when r.rnk <= 25 then 'watched'
    else 'listed'
  end
  from (
    select user_id, rank() over (order by score desc) as rnk
    from public.spotlight_scores
  ) r
  where ss.user_id = r.user_id;
end;
$$ language plpgsql security definer;

-- ============================================
-- SPOTLIGHT: SCORE COMPUTATION
-- Composite formula:
--   (tokens_bet       × 1.0 )  — total tokens wagered on this creator's markets
--   (tokens_promoted  × 1.5 )  — tokens spent promoting this creator
--   (unique_bettors   × 2.0 )  — distinct users who have ever bet on this creator
--   (24h_activity     × 1.25)  — tokens bet in the last 24 hours (recency boost)
--   (connected_platforms × 10) — active social accounts linked to their profile
--
-- Only Platform Creators (is_creator = true) are Spotlight eligible.
-- Famous Creators are excluded — they live in famous_creators, not profiles.
-- ============================================

create or replace function public.compute_spotlight_score(target_user_id uuid)
returns void as $$
declare
  v_is_creator        boolean;
  v_tokens_bet        numeric;
  v_tokens_promoted   numeric;
  v_unique_bettors    numeric;
  v_last_24h          numeric;
  v_platforms         numeric;
  v_score             numeric;
begin
  -- Only Platform Creators are Spotlight eligible
  select is_creator into v_is_creator
  from public.profiles
  where id = target_user_id;

  if v_is_creator is not true then
    return;
  end if;

  -- Total tokens bet on this creator's markets (all time)
  select coalesce(sum(b.amount), 0)
  into v_tokens_bet
  from public.bets b
  join public.markets m on b.market_id = m.id
  where m.creator_id = target_user_id
    and b.status != 'refunded';

  -- Total tokens spent promoting this creator
  -- reference_id on 'promoted' transactions points to the creator's profile id
  select coalesce(sum(tt.amount), 0)
  into v_tokens_promoted
  from public.token_transactions tt
  where tt.type = 'promoted'
    and tt.reference_id = target_user_id;

  -- Distinct users who have bet on this creator
  select coalesce(count(distinct b.user_id), 0)
  into v_unique_bettors
  from public.bets b
  join public.markets m on b.market_id = m.id
  where m.creator_id = target_user_id
    and b.status != 'refunded';

  -- Tokens bet on this creator in the last 24 hours (recency signal)
  select coalesce(sum(b.amount), 0)
  into v_last_24h
  from public.bets b
  join public.markets m on b.market_id = m.id
  where m.creator_id = target_user_id
    and b.placed_at >= now() - interval '24 hours'
    and b.status != 'refunded';

  -- Active social platforms connected
  select coalesce(count(*), 0)
  into v_platforms
  from public.social_connections sc
  where sc.user_id = target_user_id
    and sc.is_active = true;

  -- Composite score
  v_score := (v_tokens_bet      * 1.0 )
           + (v_tokens_promoted * 1.5 )
           + (v_unique_bettors  * 2.0 )
           + (v_last_24h        * 1.25)
           + (v_platforms       * 10.0);

  -- Upsert score; tier is set to 'listed' as placeholder then corrected below
  insert into public.spotlight_scores (user_id, score, tier, computed_at)
  values (target_user_id, v_score, 'listed', now())
  on conflict (user_id) do update
    set score       = excluded.score,
        computed_at = excluded.computed_at;

  -- Rerank all creators so tiers reflect the updated leaderboard
  perform public.recompute_spotlight_tiers();
end;
$$ language plpgsql security definer;

-- ============================================
-- TRIGGER: BET PLACED OR SETTLED
-- Recomputes the spotlight score for the creator
-- whose market was bet on.
-- ============================================

create or replace function public.handle_bet_score_update()
returns trigger as $$
declare
  v_creator_id uuid;
begin
  select creator_id into v_creator_id
  from public.markets
  where id = coalesce(new.market_id, old.market_id);

  if v_creator_id is not null then
    perform public.compute_spotlight_score(v_creator_id);
  end if;

  return coalesce(new, old);
end;
$$ language plpgsql security definer;

create trigger on_bet_changed
  after insert or update on public.bets
  for each row execute procedure public.handle_bet_score_update();

-- ============================================
-- TRIGGER: PROMOTION TOKEN TRANSACTION
-- Recomputes spotlight score for the promoted creator
-- when a 'promoted' token_transaction is recorded.
-- (reference_id = creator profile id)
-- ============================================

create or replace function public.handle_promotion_score_update()
returns trigger as $$
begin
  if new.type = 'promoted' and new.reference_id is not null then
    perform public.compute_spotlight_score(new.reference_id);
  end if;
  return new;
end;
$$ language plpgsql security definer;

create trigger on_token_transaction_inserted
  after insert on public.token_transactions
  for each row execute procedure public.handle_promotion_score_update();

-- ============================================
-- TRIGGER: SOCIAL CONNECTION CREATED
-- 1. Grants a one-time 25-token verification_bonus
--    for each new platform linked (guard prevents
--    re-granting if the row is deleted and re-inserted).
-- 2. Recomputes spotlight score so connected_platforms
--    weight takes effect immediately.
-- ============================================

create or replace function public.handle_social_connection_created()
returns trigger as $$
declare
  v_already_granted boolean;
begin
  -- Inactive connections earn neither bonus nor score update
  if new.is_active = false then
    return new;
  end if;

  -- One-time bonus per platform: check transaction history not the connections
  -- table, so the guard survives row deletions and re-inserts.
  select exists(
    select 1 from public.token_transactions
    where user_id   = new.user_id
      and type      = 'verification_bonus'
      and description = 'Platform connected: ' || new.platform
  ) into v_already_granted;

  if not v_already_granted then
    update public.token_balances
    set available_tokens = available_tokens + 25,
        lifetime_earned  = lifetime_earned  + 25,
        updated_at       = now()
    where user_id = new.user_id;

    insert into public.token_transactions
      (user_id, type, amount, reference_id, description)
    values
      (new.user_id, 'verification_bonus', 25, new.id,
       'Platform connected: ' || new.platform);
  end if;

  -- Recompute score so platform weight is reflected immediately
  perform public.compute_spotlight_score(new.user_id);

  return new;
end;
$$ language plpgsql security definer;

create trigger on_social_connection_created
  after insert on public.social_connections
  for each row execute procedure public.handle_social_connection_created();

-- ============================================
-- UPDATE handle_new_user() TRIGGER
-- Grants 100 signup bonus tokens on registration.
-- No spotlight row created here — score is only
-- computed once the user becomes a Platform Creator.
-- ============================================

create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, display_name, avatar_url)
  values (
    new.id,
    new.raw_user_meta_data->>'full_name',
    new.raw_user_meta_data->>'avatar_url'
  );

  insert into public.balances (user_id) values (new.id);

  insert into public.token_balances (user_id, available_tokens, lifetime_earned)
  values (new.id, 100, 100);

  insert into public.token_transactions (user_id, type, amount, description)
  values (new.id, 'signup_bonus', 100, 'Welcome bonus — 100 free tokens');

  return new;
end;
$$ language plpgsql security definer;
