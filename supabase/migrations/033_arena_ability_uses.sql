-- Migration 033: Per-match ability cooldown tracking
-- Each row = one successful ability trigger. Cooldown checks query this table.
-- Also serves as the full audit log for "who triggered what when".

CREATE TABLE public.arena_ability_uses (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id     uuid        NOT NULL REFERENCES public.arena_matches(id),
  user_id      uuid        NOT NULL REFERENCES public.profiles(id),
  ability_id   text        NOT NULL REFERENCES public.arena_abilities(id),
  target_id    uuid        NOT NULL REFERENCES public.profiles(id),
  triggered_at timestamptz NOT NULL DEFAULT now()
);

-- Primary cooldown lookup: most recent use of a given ability by a user in a match
CREATE INDEX arena_ability_uses_cooldown_idx
  ON public.arena_ability_uses (match_id, user_id, ability_id, triggered_at DESC);

ALTER TABLE public.arena_ability_uses ENABLE ROW LEVEL SECURITY;

CREATE POLICY "arena_ability_uses: authenticated read"
  ON public.arena_ability_uses FOR SELECT TO authenticated USING (true);
