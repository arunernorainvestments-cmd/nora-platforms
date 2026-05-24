# Infrastructure Reference — Edge Functions, pg_cron, Routing

## Edge Functions (all deployed --no-verify-jwt)

### Markets & Core
oauth-initiate | oauth-callback | disconnect-platform
sync-platform-metrics (single fn, never split)
resolve-markets | apply-promotion | evaluate-challenges
compute-spotlight (returns {champions, top_movers})
create-checkout-session | stripe-webhook

### Arena
arena-matchmaker | arena-monday-rollover
arena-tick-warmer (keep-alive, 30s pg_cron)
arena-dev-force-match | arena-dev-simulator | arena-dev-reset (ALLOW_DEV_TOOLS=true gated)

### Hot Topic
hot-topic-fetch-and-score | hot-topic-reset-week
hot-topic-resolve-week | hot-topic-place-bet

### Battle
battle-tick-warmer (keep-alive, 30s pg_cron)
process_battle_turn() is PL/pgSQL via pg_cron — not an edge function

## pg_cron Jobs
main-character-check (hourly)
arena-matchmaker (5min) | process_arena_tick (3s) | arena-tick-warmer (30s)
arena-monday-rollover (Monday 00:00 UTC)
hot-topic-morning (11:00 UTC) | hot-topic-evening (22:00 UTC)
hot-topic-weekly-reset (Monday 11:00 UTC)
hot-topic-resolve (Saturday 00:00 UTC)
battle-turn-processor (3s) | battle-cleanup (10min) | battle-presence-check (60s) | battle-tick-warmer (30s)

NOTE: arena-tick-warmer and battle-tick-warmer require app.service_role_key set:
  ALTER DATABASE postgres SET app.service_role_key TO 'your-key';

## Routing
/ LaunchScreen (countdown + waitlist)
/w/:token LaunchScreen with referral token
/home HomeScreen (Shell)
/markets | /markets/:id Markets | MarketDetail
/mybets | /profile | /wallet | /dashboard | /challenges (auth)
/news CelebrityHeatScreen
/hot-topic HotTopicScreen
/arena ArenaLobbyScreen (auth)
/arena/:matchId ArenaMatchScreen (auth)
/battle BattleLobbyScreen (auth)
/battle/:matchId BattleMatchScreen (auth)
/u/:username PublicProfileScreen (public)
