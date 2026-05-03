# Arena Testing Guide

Reference for every dev testing session. Follow the Pre-Session Checklist first,
then use the Diagnostic Queries and Known Issues sections as needed.

---

## Architecture — what runs automatically

| Job | Schedule | What it does |
|-----|----------|--------------|
| `dev-test-match-maintainer` | every 2 min | Creates a test match if none are active. Only fires when no test match is in `pre_match` or `live` state. No-ops otherwise. |
| `arena-tick` | every 1 min | Calls `arena_tick_fast_loop()` procedure — 6 ticks at 10s intervals with COMMIT between each tick. Flips `pre_match → live`, advances scores, resolves at 5 min. |
| `dev-bot-backer` | every 1 min | Places 2–4 random backs (5–25 tokens, 55/45 p1 bias) on every live test match. Tops up test account balances before backing. |
| `arena-matchmaker` | every 5 min | Runs real matchmaking. On weekends (Fri 19:00 – Sun 23:59 UTC) enters Round 3 logic — returns empty if no bracket exists. |
| `resolve-markets` | every 15 min | Settles prediction markets (unrelated to Arena). |
| `main-character-check` | every hour | Evaluates the #1 heat badge. |
| `sync-platform-metrics` | every 5 min | Syncs YouTube/Twitch/X/Spotify data (null-named cron job, jobid 9). |

**Match lifecycle (dev):** `dev-test-match-maintainer` creates match → within 10s the tick flips it live → bots place backs every minute → tick resolves at 5 minutes → up to 2-minute gap before next match is created.

**Weekend note:** `arena-matchmaker` RPC returns empty Fri–Sun (Round 3 window, no test bracket). The Flutter "Find a Match" fallback still works — it queries for any live match directly. If no match exists, wait up to 2 minutes or run the manual commands below.

---

## Pre-Session Checklist

Run these in the Supabase SQL editor before testing.

**1. Verify all cron jobs are active:**
```sql
SELECT jobname, schedule, active FROM cron.job ORDER BY jobname;
```
Expected jobs: `arena-matchmaker`, `arena-monday-rollover`, `arena-tick`,
`dev-bot-backer`, `dev-test-match-maintainer`, `main-character-check`,
`resolve-markets`, plus one null-named job (sync-platform-metrics).

**2. Check recent cron health:**
```sql
SELECT jobid, status, start_time, return_message
FROM cron.job_run_details
ORDER BY start_time DESC LIMIT 15;
```
`arena-tick` (jobid 19) should show `CALL` as return message and `succeeded` status.
`dev-bot-backer` (jobid 18) should show `1 row` and `succeeded`.

**3. Check match states:**
```sql
SELECT state, COUNT(*) FROM arena_matches GROUP BY state;
```
Expect at least 1 `live` or `pre_match` match. If only `resolved`:

**4. Force-create a fresh match immediately:**
```sql
SELECT dev_maintain_test_match();
SELECT process_arena_tick();
```
The second call flips it live instantly. You have 5 minutes.

**5. Verify abilities are in the DB:**
```sql
SELECT archetype, COUNT(*) as total,
       COUNT(*) FILTER (WHERE ability_type != 'passive') as triggerable
FROM arena_abilities
GROUP BY archetype ORDER BY archetype;
```
Expected: 10 archetypes, each with 4 triggerable abilities (1 passive excluded).

**6. Check your token balance:**
```sql
SELECT available_tokens, lifetime_earned
FROM token_balances
WHERE user_id = auth.uid();
```
You need tokens to Back and Trigger. If low, ask Adam to top up via the wallet.

---

## Diagnostic Queries

**Who is in the current live match?**
```sql
SELECT am.id, am.state, am.player_1_archetype, am.actual_start,
       p1.username AS p1, p2.username AS p2
FROM arena_matches am
JOIN profiles p1 ON p1.id = am.player_1_id
JOIN profiles p2 ON p2.id = am.player_2_id
WHERE am.state IN ('pre_match', 'live')
ORDER BY am.created_at DESC LIMIT 3;
```

**What is the current score?**
```sql
SELECT match_id, tick, score_p1, score_p2, flow_rate_p1, flow_rate_p2,
       total_pool_p1, total_pool_p2
FROM arena_state
WHERE match_id = (
  SELECT id FROM arena_matches WHERE state = 'live' ORDER BY created_at DESC LIMIT 1
);
```

**Are bots backing?**
```sql
SELECT COUNT(*), SUM(amount), MAX(created_at)
FROM arena_events
WHERE match_id = (
  SELECT id FROM arena_matches WHERE state = 'live' ORDER BY created_at DESC LIMIT 1
)
AND event_type = 'back';
```

**Is the tick loop running correctly?**
```sql
SELECT status, start_time, end_time, return_message
FROM cron.job_run_details
WHERE jobid = 19
ORDER BY start_time DESC LIMIT 5;
```
Should see `CALL` return message and `succeeded` status. If `running` for >2 minutes, the loop may be stuck.

**What abilities exist for a specific archetype?**
```sql
SELECT id, ability_type, display_name, token_cost, cooldown_seconds
FROM arena_abilities
WHERE archetype = 'healthcare'  -- change archetype as needed (lowercase)
ORDER BY ability_type;
```

---

## Known Issues & Fixes

### Abilities show "No abilities available"
**Cause:** `abilityConfigProvider` is a FutureProvider that runs once at app startup,
before auth is restored. Pre-auth, it fetches 0 rows from `arena_abilities` and caches
the empty result for the session.

**Fix:** Hard refresh the browser — **Ctrl+Shift+R** (Windows/Linux) or **Cmd+Shift+R** (Mac).
This clears the Riverpod cache and re-fetches abilities. The RLS policy now allows public
reads so abilities load regardless of auth timing.

**Verify in DB:** `SELECT COUNT(*) FROM arena_abilities;` — should be 50.

---

### Betting returns "Match has ended" error
**Cause:** Match resolved in the ~1 second between the UI rendering the Back button
(via Realtime stream) and the RPC call reaching the DB.

**Fix:** This is handled gracefully — the error shows "Match has ended" and the UI
snaps to the resolved state. Wait for the next match (≤2 minutes).

---

### Betting times out (error 57014 — statement timeout)
**Cause:** If `arena_tick_fast_loop` was a FUNCTION (old version), it held row locks
for 57 seconds in a single transaction, blocking `arena_back`.

**Current state:** Fixed — `arena_tick_fast_loop` is now a PROCEDURE with COMMIT
between each tick. Row locks are released every 10 seconds.

**Verify the fix is applied:**
```sql
SELECT routine_type FROM information_schema.routines
WHERE routine_name = 'arena_tick_fast_loop';
```
Should return `PROCEDURE`. If `FUNCTION`, re-run the procedure migration.

---

### Page refresh at /arena/:matchId redirects to /home
**Cause:** The old `routerProvider` used `ref.watch` on auth state, causing a new
GoRouter to be created on every auth state change. The new router briefly landed at
`initialLocation: '/'` and the redirect sent it to `/home`.

**Current state:** Fixed — `routerProvider` now uses `ref.listen` + `refreshListenable`
so the router instance is never recreated. Page refresh preserves the match URL.

---

### "Find a Match" returns nothing on weekends
**Cause:** `arena_matchmake` RPC is in Round 3 mode Friday 19:00 – Sunday 23:59 UTC.
With no test bracket, it returns empty. The Flutter fallback finds any live/pre_match
match, but if none exist at that moment, it returns null.

**Fix:** Run manually:
```sql
SELECT dev_maintain_test_match();
SELECT process_arena_tick();
```
Then tap "Find a Match" — the fallback will find the fresh match.

---

### Scores not changing / match feels frozen
**Cause A:** `arena-tick` cron is stuck or failed. Check `cron.job_run_details` for errors.

**Cause B:** The match has no backing events so BaseFlow is near zero.
Bots should be adding backing every minute. Verify:
```sql
SELECT COUNT(*) FROM arena_events
WHERE match_id = (SELECT id FROM arena_matches WHERE state = 'live' ORDER BY created_at DESC LIMIT 1);
```

**Cause C:** Tick is running but `process_arena_tick()` has a silent error for this match.
Run manually and check: `SELECT process_arena_tick();`

---

### Test match not being created automatically
**Cause:** `dev-test-match-maintainer` only creates a match when NO test match is in
`pre_match` or `live` state. If a match is already active, it no-ops (this is correct).

**Gap:** After a match resolves, up to 2 minutes pass before the next match is created.

**Fix:** Run `SELECT dev_maintain_test_match(); SELECT process_arena_tick();` to skip the wait.

---

## Test Account Reference

20 test creators seeded (migration 051), 2 per archetype:

| Archetype | Player 1 | Player 2 |
|-----------|----------|----------|
| Athlete | test_athlete_basketball_1 | test_athlete_football_1 |
| Musician | test_musician_dj_1 | test_musician_singer_1 |
| Healthcare | test_healthcare_doctor_1 | test_healthcare_nurse_1 |
| Performer | test_performer_comedian_1 | test_performer_dancer_1 |
| Gamer | test_gamer_streamer_1 | test_gamer_competitive_1 |
| Influencer | test_influencer_fitness_1 | test_influencer_travel_1 |
| Educator | test_educator_teacher_1 | test_educator_author_1 |
| Politician | test_politician_congress_1 | test_politician_governor_1 |
| Religion | test_religion_pastor_1 | test_religion_imam_1 |
| Business | test_business_ceo_1 | test_business_investor_1 |

UUID pattern: `10000000-0000-0000-0000-000000000001` through `…000020`.

To top up a test account's token balance:
```sql
UPDATE token_balances SET available_tokens = 1000
WHERE user_id = (SELECT id FROM profiles WHERE username = 'test_athlete_basketball_1');
```

---

## Pre-Launch Cleanup (before July 4, 2026)

Remove all dev tooling before go-live:
```sql
SELECT cron.unschedule('dev-test-match-maintainer');
SELECT cron.unschedule('dev-bot-backer');
DROP FUNCTION IF EXISTS public.dev_maintain_test_match();
DROP FUNCTION IF EXISTS public.dev_arena_back(uuid, uuid, uuid, int);
DROP PROCEDURE IF EXISTS public.arena_tick_fast_loop();
-- Restore arena-tick to call process_arena_tick() directly at appropriate interval
```

Also truncate Arena tables and re-run full reset per CLAUDE.md pre-launch checklist.
