-- Enable UUID extension
create extension if not exists "uuid-ossp";

-- PROFILES (extends Supabase auth.users)
create table public.profiles (
  id uuid references auth.users(id) on delete cascade primary key,
  username text unique,
  display_name text,
  avatar_url text,
  bio text,
  is_creator boolean default false,
  is_admin boolean default false,
  popularity_score numeric(5,2) default 0,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- SOCIAL CONNECTIONS (OAuth tokens stored securely server-side)
create table public.social_connections (
  id uuid default uuid_generate_v4() primary key,
  user_id uuid references public.profiles(id) on delete cascade,
  platform text not null, -- 'youtube' | 'tiktok' | 'x' | 'instagram' | 'kick' | 'pinterest'
  platform_user_id text,
  platform_username text,
  access_token text,  -- encrypted at rest via Supabase vault (Phase 2)
  refresh_token text,
  token_expires_at timestamptz,
  is_active boolean default true,
  created_at timestamptz default now(),
  unique(user_id, platform)
);

-- METRICS HISTORY (time-series popularity data)
create table public.metrics_history (
  id uuid default uuid_generate_v4() primary key,
  user_id uuid references public.profiles(id) on delete cascade,
  recorded_at timestamptz default now(),
  platform text, -- null = aggregate
  followers_count bigint default 0,
  views_count bigint default 0,
  likes_count bigint default 0,
  engagement_rate numeric(6,4) default 0,
  peak_viewers int default 0,
  search_impressions bigint default 0,
  popularity_score numeric(5,2) default 0
);

-- MARKETS
create table public.markets (
  id uuid default uuid_generate_v4() primary key,
  creator_id uuid references public.profiles(id),
  title text not null,
  description text,
  market_type text default 'popularity_change', -- extensible
  target_metric text default 'popularity_score',
  target_change_pct numeric(6,2), -- e.g. 5.00 = 5%
  timeframe text not null, -- '24h' | '7d' | '30d'
  start_at timestamptz default now(),
  end_at timestamptz not null,
  resolution_value numeric,
  status text default 'open', -- 'open' | 'closed' | 'resolved' | 'cancelled'
  yes_pool numeric(12,2) default 0,
  no_pool numeric(12,2) default 0,
  platform_fee_pct numeric(4,2) default 1.5,
  resolved_outcome boolean, -- true = YES won
  created_by uuid references public.profiles(id),
  created_at timestamptz default now()
);

-- BETS
create table public.bets (
  id uuid default uuid_generate_v4() primary key,
  market_id uuid references public.markets(id),
  user_id uuid references public.profiles(id),
  position text not null, -- 'yes' | 'no'
  amount numeric(12,2) not null,
  potential_payout numeric(12,2),
  status text default 'active', -- 'active' | 'won' | 'lost' | 'refunded'
  placed_at timestamptz default now(),
  settled_at timestamptz
);

-- BALANCES (escrow wallet)
create table public.balances (
  id uuid default uuid_generate_v4() primary key,
  user_id uuid references public.profiles(id) on delete cascade unique,
  available numeric(12,2) default 0,
  locked numeric(12,2) default 0, -- funds in active bets
  total_deposited numeric(12,2) default 0,
  total_withdrawn numeric(12,2) default 0,
  updated_at timestamptz default now()
);

-- TRANSACTIONS
create table public.transactions (
  id uuid default uuid_generate_v4() primary key,
  user_id uuid references public.profiles(id),
  type text not null, -- 'deposit' | 'withdrawal' | 'bet' | 'payout' | 'fee'
  amount numeric(12,2) not null,
  reference_id uuid, -- bet_id or stripe payment_intent_id cast to uuid
  description text,
  created_at timestamptz default now()
);

-- ============================================
-- ROW LEVEL SECURITY
-- ============================================

alter table public.profiles enable row level security;
alter table public.social_connections enable row level security;
alter table public.metrics_history enable row level security;
alter table public.markets enable row level security;
alter table public.bets enable row level security;
alter table public.balances enable row level security;
alter table public.transactions enable row level security;

-- PROFILES: public read, own write
create policy "Profiles are publicly readable"
  on public.profiles for select using (true);
create policy "Users can update own profile"
  on public.profiles for update using (auth.uid() = id);
create policy "Users can insert own profile"
  on public.profiles for insert with check (auth.uid() = id);

-- SOCIAL CONNECTIONS: private
create policy "Users can manage own connections"
  on public.social_connections for all using (auth.uid() = user_id);

-- METRICS: public read
create policy "Metrics are publicly readable"
  on public.metrics_history for select using (true);

-- MARKETS: public read, authenticated create
create policy "Markets are publicly readable"
  on public.markets for select using (true);
create policy "Authenticated users can create markets"
  on public.markets for insert with check (auth.uid() is not null);

-- BETS: own only
create policy "Users can view own bets"
  on public.bets for select using (auth.uid() = user_id);
create policy "Users can place bets"
  on public.bets for insert with check (auth.uid() = user_id);

-- BALANCES: own only
create policy "Users can view own balance"
  on public.balances for select using (auth.uid() = user_id);

-- TRANSACTIONS: own only
create policy "Users can view own transactions"
  on public.transactions for select using (auth.uid() = user_id);

-- AUTO-CREATE profile + balance on signup
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
  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();
