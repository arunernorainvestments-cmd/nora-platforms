-- Migration 056: Arena abilities — allow public (anon) reads
--
-- arena_abilities is static game config (ability names, costs, effects).
-- The previous policy restricted reads to the 'authenticated' role, which
-- caused the Flutter abilityConfigProvider (FutureProvider that runs once at
-- app startup before auth is restored) to receive 0 rows. The empty result
-- was cached for the session, leaving the ability picker blank even after login.
--
-- Abilities contain no user data — public read is correct.

DROP POLICY IF EXISTS "arena_abilities: authenticated read" ON public.arena_abilities;

CREATE POLICY "arena_abilities: public read"
  ON public.arena_abilities FOR SELECT USING (true);
