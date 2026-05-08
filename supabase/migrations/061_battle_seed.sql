-- Migration 061: Battle Mode Phase A — Seed Data
-- Maps, type effectiveness chart (100 rows), ability definitions (50 rows),
-- and Rive animation key reference table.

-- ============================================================
-- 1. Maps
-- ============================================================
INSERT INTO battle_maps (name, description, affinity_archetypes, background_rive_key)
VALUES
  ('The Stadium',
   'A roaring sports arena under floodlights.',
   ARRAY['athlete','gamer'],
   'map_stadium'),
  ('Concert Hall',
   'A grand performance stage with dramatic lighting.',
   ARRAY['musician','actor'],
   'map_concert_hall'),
  ('The Boardroom',
   'A high-stakes corporate war room.',
   ARRAY['business','politician'],
   'map_boardroom'),
  ('Comedy Club',
   'A sold-out underground comedy venue.',
   ARRAY['comedian','influencer'],
   'map_comedy_club'),
  ('The Gallery',
   'A prestigious art gallery opening night.',
   ARRAY['artist','musician'],
   'map_gallery'),
  ('Research Lab',
   'A cutting-edge technology laboratory.',
   ARRAY['scientist','gamer'],
   'map_research_lab'),
  ('Social HQ',
   'A buzzing influencer content studio.',
   ARRAY['influencer','business'],
   'map_social_hq'),
  ('The Arena Stage',
   'A neutral battleground. No home advantage.',
   ARRAY[]::TEXT[],
   'map_arena_stage')
ON CONFLICT (name) DO NOTHING;

-- ============================================================
-- 2. Type effectiveness chart (full 10×10 = 100 rows)
-- ============================================================
-- Archetypes: athlete, musician, business, comedian, artist,
--             gamer, influencer, scientist, politician, actor
-- Conflict resolutions applied:
--   1. Athlete vs Influencer  → Influencer wins (athlete 0.5 vs influencer)
--   2. Comedian vs Politician → Comedian wins (comedian 1.5 vs politician)
--   3. Comedian vs Influencer → Influencer wins (comedian 0.5 vs influencer)
--   4. Gamer vs Scientist     → Scientist wins (gamer 0.5 vs scientist)
-- Rebalance at any time via UPDATE — no code changes required.
-- To add a new archetype: INSERT rows for new_type vs all existing types (both directions).

INSERT INTO battle_type_chart (attacker_type, defender_type, multiplier)
VALUES
  -- ATHLETE attacking
  ('athlete','athlete',    1.00),
  ('athlete','musician',   0.50),
  ('athlete','business',   1.00),
  ('athlete','comedian',   1.00),
  ('athlete','artist',     1.50),
  ('athlete','gamer',      1.50),
  ('athlete','influencer', 0.50),
  ('athlete','scientist',  1.00),
  ('athlete','politician', 1.00),
  ('athlete','actor',      0.50),
  -- MUSICIAN attacking
  ('musician','athlete',    1.50),
  ('musician','musician',   1.00),
  ('musician','business',   0.50),
  ('musician','comedian',   1.50),
  ('musician','artist',     0.50),
  ('musician','gamer',      1.00),
  ('musician','influencer', 1.00),
  ('musician','scientist',  0.50),
  ('musician','politician', 1.50),
  ('musician','actor',      1.00),
  -- BUSINESS attacking
  ('business','athlete',    1.00),
  ('business','musician',   1.50),
  ('business','business',   1.00),
  ('business','comedian',   1.00),
  ('business','artist',     1.50),
  ('business','gamer',      0.50),
  ('business','influencer', 1.00),
  ('business','scientist',  1.50),
  ('business','politician', 0.50),
  ('business','actor',      1.00),
  -- COMEDIAN attacking
  ('comedian','athlete',    1.00),
  ('comedian','musician',   0.50),
  ('comedian','business',   1.00),
  ('comedian','comedian',   1.00),
  ('comedian','artist',     1.00),
  ('comedian','gamer',      1.00),
  ('comedian','influencer', 0.50),
  ('comedian','scientist',  1.00),
  ('comedian','politician', 1.50),
  ('comedian','actor',      1.50),
  -- ARTIST attacking
  ('artist','athlete',    0.50),
  ('artist','musician',   1.50),
  ('artist','business',   0.50),
  ('artist','comedian',   1.00),
  ('artist','artist',     1.00),
  ('artist','gamer',      1.50),
  ('artist','influencer', 1.50),
  ('artist','scientist',  0.50),
  ('artist','politician', 1.00),
  ('artist','actor',      1.00),
  -- GAMER attacking
  ('gamer','athlete',    0.50),
  ('gamer','musician',   1.00),
  ('gamer','business',   1.50),
  ('gamer','comedian',   1.00),
  ('gamer','artist',     0.50),
  ('gamer','gamer',      1.00),
  ('gamer','influencer', 1.00),
  ('gamer','scientist',  0.50),
  ('gamer','politician', 1.50),
  ('gamer','actor',      1.00),
  -- INFLUENCER attacking
  ('influencer','athlete',    1.50),
  ('influencer','musician',   1.00),
  ('influencer','business',   1.00),
  ('influencer','comedian',   1.50),
  ('influencer','artist',     0.50),
  ('influencer','gamer',      1.00),
  ('influencer','influencer', 1.00),
  ('influencer','scientist',  1.00),
  ('influencer','politician', 0.50),
  ('influencer','actor',      1.50),
  -- SCIENTIST attacking
  ('scientist','athlete',    1.00),
  ('scientist','musician',   1.50),
  ('scientist','business',   0.50),
  ('scientist','comedian',   1.00),
  ('scientist','artist',     1.50),
  ('scientist','gamer',      1.50),
  ('scientist','influencer', 1.00),
  ('scientist','scientist',  1.00),
  ('scientist','politician', 1.00),
  ('scientist','actor',      0.50),
  -- POLITICIAN attacking
  ('politician','athlete',    1.00),
  ('politician','musician',   0.50),
  ('politician','business',   1.50),
  ('politician','comedian',   0.50),
  ('politician','artist',     1.00),
  ('politician','gamer',      0.50),
  ('politician','influencer', 1.50),
  ('politician','scientist',  1.00),
  ('politician','politician', 1.00),
  ('politician','actor',      0.50),
  -- ACTOR attacking
  ('actor','athlete',    1.50),
  ('actor','musician',   1.00),
  ('actor','business',   1.00),
  ('actor','comedian',   0.50),
  ('actor','artist',     1.00),
  ('actor','gamer',      1.00),
  ('actor','influencer', 0.50),
  ('actor','scientist',  1.50),
  ('actor','politician', 1.50),
  ('actor','actor',      1.00)
ON CONFLICT (attacker_type, defender_type) DO NOTHING;

-- ============================================================
-- 3. Ability definitions (5 per archetype = 50 total)
-- ============================================================
-- Speed stats by archetype (determines turn order within a round):
--   athlete: 90, gamer: 85, influencer: 75, actor: 70, comedian: 65,
--   musician: 60, artist: 55, scientist: 50, business: 45, politician: 40
-- AP regenerates 5 per turn automatically.
-- Ultimate requires momentum = 100 AND ap_cost paid; resets momentum to 0 after use.
-- All damage values are Phase A placeholders — balance tuned in Phase D
-- using battle_match_telemetry data.

INSERT INTO battle_abilities
  (archetype, name, description, ability_slot, ap_cost, requires_momentum,
   base_damage, speed_priority, effect_type, effect_value, effect_target,
   is_ultimate, rive_animation_key)
VALUES
  -- ── ATHLETE (speed: 90) ─────────────────────────────────────────────────────
  ('athlete', 'Sprint Strike',
   'A lightning-fast burst attack.',
   1, 5, FALSE, 20, 1, 'damage', 0, 'opponent', FALSE, 'athlete_sprint_strike'),
  ('athlete', 'Power Slam',
   'A devastating physical impact.',
   2, 10, FALSE, 35, 0, 'damage', 0, 'opponent', FALSE, 'athlete_power_slam'),
  ('athlete', 'Second Wind',
   'Recovers stamina and boosts speed next turn.',
   3, 15, FALSE, 0, 0, 'heal', 25, 'self', FALSE, 'athlete_second_wind'),
  ('athlete', 'Championship Drive',
   'Peak performance — unstoppable force.',
   4, 25, FALSE, 60, 0, 'damage', 0, 'opponent', FALSE, 'athlete_championship_drive'),
  ('athlete', 'Gold Medal Moment',
   'Inspires the entire team with champion energy.',
   5, 40, TRUE, 100, 0, 'momentum_boost', 20, 'all_allies', TRUE, 'athlete_ultimate'),

  -- ── MUSICIAN (speed: 60) ────────────────────────────────────────────────────
  ('musician', 'Rhythm Hit',
   'A sharp percussive strike.',
   1, 5, FALSE, 20, 0, 'damage', 0, 'opponent', FALSE, 'musician_rhythm_hit'),
  ('musician', 'Drop the Beat',
   'Heavy bass overwhelms the opponent.',
   2, 10, FALSE, 35, 0, 'damage', 0, 'opponent', FALSE, 'musician_drop_the_beat'),
  ('musician', 'Crowd Hype',
   'Channels audience energy to an ally.',
   3, 15, FALSE, 0, 0, 'momentum_boost', 30, 'ally', FALSE, 'musician_crowd_hype'),
  ('musician', 'Bass Drop',
   'A sonic shockwave at full volume.',
   4, 25, FALSE, 60, 0, 'damage', 0, 'opponent', FALSE, 'musician_bass_drop'),
  ('musician', 'Encore',
   'Repeats the last ability used for free.',
   5, 40, TRUE, 80, 0, 'special', 0, 'self', TRUE, 'musician_ultimate'),

  -- ── BUSINESS (speed: 45) ────────────────────────────────────────────────────
  ('business', 'Cold Call',
   'An aggressive opening move.',
   1, 5, FALSE, 20, 0, 'damage', 0, 'opponent', FALSE, 'business_cold_call'),
  ('business', 'Hostile Takeover',
   'Seizes control with ruthless efficiency.',
   2, 10, FALSE, 35, 0, 'damage', 0, 'opponent', FALSE, 'business_hostile_takeover'),
  ('business', 'Leverage',
   'Drains opponent AP — disrupts their strategy.',
   3, 15, FALSE, 0, 0, 'drain_ap', 15, 'opponent', FALSE, 'business_leverage'),
  ('business', 'Market Crash',
   'Systemic damage — unavoidable.',
   4, 25, FALSE, 60, 0, 'damage', 0, 'opponent', FALSE, 'business_market_crash'),
  ('business', 'Corporate Raid',
   'Devastating financial strike, drains opponent AP.',
   5, 40, TRUE, 100, 0, 'drain_ap', 30, 'opponent', TRUE, 'business_ultimate'),

  -- ── COMEDIAN (speed: 65) ────────────────────────────────────────────────────
  ('comedian', 'Punchline',
   'A quick wit strike catches them off guard.',
   1, 5, FALSE, 20, 0, 'damage', 0, 'opponent', FALSE, 'comedian_punchline'),
  ('comedian', 'Roast',
   'Public humiliation — hits harder than expected.',
   2, 10, FALSE, 35, 0, 'damage', 0, 'opponent', FALSE, 'comedian_roast'),
  ('comedian', 'Crowd Control',
   'Rattles the opponent — slows their next move.',
   3, 15, FALSE, 0, 0, 'debuff', -15, 'opponent', FALSE, 'comedian_crowd_control'),
  ('comedian', 'Comedy Bomb',
   'The whole crowd turns against the opponent.',
   4, 25, FALSE, 60, 0, 'damage', 0, 'opponent', FALSE, 'comedian_comedy_bomb'),
  ('comedian', 'Standing Ovation',
   'The crowd crushes all opposition momentum.',
   5, 40, TRUE, 100, 0, 'momentum_boost', -20, 'all_opponents', TRUE, 'comedian_ultimate'),

  -- ── ARTIST (speed: 55) ──────────────────────────────────────────────────────
  ('artist', 'Sketch Attack',
   'A sharp creative strike.',
   1, 5, FALSE, 20, 0, 'damage', 0, 'opponent', FALSE, 'artist_sketch_attack'),
  ('artist', 'Masterpiece',
   'A carefully crafted blow — precise and powerful.',
   2, 10, FALSE, 35, 0, 'damage', 0, 'opponent', FALSE, 'artist_masterpiece'),
  ('artist', 'Muse',
   'Draws inspiration — heals and builds momentum.',
   3, 15, FALSE, 0, 0, 'heal', 20, 'self', FALSE, 'artist_muse'),
  ('artist', 'Gallery Opening',
   'A sweeping creative force.',
   4, 25, FALSE, 60, 0, 'damage', 0, 'opponent', FALSE, 'artist_gallery_opening'),
  ('artist', 'Magnum Opus',
   'A masterwork attack — ignores type resistance.',
   5, 40, TRUE, 100, 0, 'special', 0, 'opponent', TRUE, 'artist_ultimate'),

  -- ── GAMER (speed: 85) ───────────────────────────────────────────────────────
  ('gamer', 'Quick Attack',
   'First-strike advantage — always moves early.',
   1, 5, FALSE, 20, 1, 'damage', 0, 'opponent', FALSE, 'gamer_quick_attack'),
  ('gamer', 'Combo Strike',
   'Chained hits from practiced hands.',
   2, 10, FALSE, 35, 0, 'damage', 0, 'opponent', FALSE, 'gamer_combo_strike'),
  ('gamer', 'Save State',
   'Shields against the next hit below 30 damage.',
   3, 15, FALSE, 0, 0, 'special', 30, 'self', FALSE, 'gamer_save_state'),
  ('gamer', 'Final Boss Move',
   'The ultimate execution — no errors.',
   4, 25, FALSE, 60, 0, 'damage', 0, 'opponent', FALSE, 'gamer_final_boss_move'),
  ('gamer', 'GG EZ',
   'Devastates and steals AP from the opponent.',
   5, 40, TRUE, 100, 0, 'drain_ap', 20, 'opponent', TRUE, 'gamer_ultimate'),

  -- ── INFLUENCER (speed: 75) ──────────────────────────────────────────────────
  ('influencer', 'Viral Clip',
   'A quick moment that hits everywhere.',
   1, 5, FALSE, 20, 0, 'damage', 0, 'opponent', FALSE, 'influencer_viral_clip'),
  ('influencer', 'Brand Deal',
   'Polished and professional — deceptively powerful.',
   2, 10, FALSE, 35, 0, 'damage', 0, 'opponent', FALSE, 'influencer_brand_deal'),
  ('influencer', 'Going Live',
   'Channels live audience energy into momentum.',
   3, 15, FALSE, 0, 0, 'momentum_boost', 40, 'self', FALSE, 'influencer_going_live'),
  ('influencer', 'Cancel Campaign',
   'Turns the crowd against them — devastating.',
   4, 25, FALSE, 60, 0, 'damage', 0, 'opponent', FALSE, 'influencer_cancel_campaign'),
  ('influencer', '#1 Trending',
   'Forces opponent to use their weakest move next turn.',
   5, 40, TRUE, 100, 0, 'special', 0, 'opponent', TRUE, 'influencer_ultimate'),

  -- ── SCIENTIST (speed: 50) ───────────────────────────────────────────────────
  ('scientist', 'Data Analysis',
   'A calculated strike based on opponent patterns.',
   1, 5, FALSE, 20, 0, 'damage', 0, 'opponent', FALSE, 'scientist_data_analysis'),
  ('scientist', 'Experiment',
   'Tests a new approach — reliable damage output.',
   2, 10, FALSE, 35, 0, 'damage', 0, 'opponent', FALSE, 'scientist_experiment'),
  ('scientist', 'Hypothesis',
   'Previews the opponent next move type.',
   3, 15, FALSE, 0, 0, 'special', 0, 'opponent', FALSE, 'scientist_hypothesis'),
  ('scientist', 'Breakthrough',
   'A paradigm-shifting attack.',
   4, 25, FALSE, 60, 0, 'damage', 0, 'opponent', FALSE, 'scientist_breakthrough'),
  ('scientist', 'Paradigm Shift',
   'Reverses type effectiveness for this character next turn.',
   5, 40, TRUE, 100, 0, 'special', 0, 'self', TRUE, 'scientist_ultimate'),

  -- ── POLITICIAN (speed: 40) ──────────────────────────────────────────────────
  ('politician', 'Talking Point',
   'A rehearsed strike — surprisingly effective.',
   1, 5, FALSE, 20, 0, 'damage', 0, 'opponent', FALSE, 'politician_talking_point'),
  ('politician', 'Filibuster',
   'Relentless pressure — hard to counter.',
   2, 10, FALSE, 35, 0, 'damage', 0, 'opponent', FALSE, 'politician_filibuster'),
  ('politician', 'Executive Order',
   'Forces the opponent to forfeit their next action.',
   3, 15, FALSE, 0, 0, 'force_skip', 1, 'opponent', FALSE, 'politician_executive_order'),
  ('politician', 'Landslide',
   'An overwhelming wave of political force.',
   4, 25, FALSE, 60, 0, 'damage', 0, 'opponent', FALSE, 'politician_landslide'),
  ('politician', 'Campaign Promise',
   'Heals the entire team — rallies the base.',
   5, 40, TRUE, 100, 0, 'heal', 30, 'all_allies', TRUE, 'politician_ultimate'),

  -- ── ACTOR (speed: 70) ───────────────────────────────────────────────────────
  ('actor', 'Scene Steal',
   'Grabs the spotlight — sharp and unexpected.',
   1, 5, FALSE, 20, 0, 'damage', 0, 'opponent', FALSE, 'actor_scene_steal'),
  ('actor', 'Method Acting',
   'Deeply committed — takes the opponent by surprise.',
   2, 10, FALSE, 35, 0, 'damage', 0, 'opponent', FALSE, 'actor_method_acting'),
  ('actor', 'Director Cut',
   'Copies and immediately uses the opponent last ability.',
   3, 15, FALSE, 0, 0, 'copy_last', 0, 'opponent', FALSE, 'actor_directors_cut'),
  ('actor', 'Blockbuster',
   'An explosive performance — maximum impact.',
   4, 25, FALSE, 60, 0, 'damage', 0, 'opponent', FALSE, 'actor_blockbuster'),
  ('actor', 'Award Season',
   'Next ability this match deals double damage.',
   5, 40, TRUE, 100, 0, 'special', 2, 'self', TRUE, 'actor_ultimate')
ON CONFLICT (archetype, ability_slot) DO NOTHING;

-- ============================================================
-- 4. Rive animation key reference table
-- ============================================================
-- Populate from battle_abilities so Flutter controller can look up keys at match load.
-- RIVE HOOK: Phase C ConsumerWidget reads this at match init to pre-load animation states.
INSERT INTO battle_rive_animation_keys
  (ability_id, rive_animation_key, animation_duration_ms, requires_target)
SELECT
  id,
  rive_animation_key,
  1000,
  TRUE
FROM battle_abilities
WHERE rive_animation_key IS NOT NULL
ON CONFLICT (ability_id) DO NOTHING;
