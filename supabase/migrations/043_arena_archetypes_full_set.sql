-- Migration 043: Seed all 9 remaining archetypes
-- Phase C: Musician, Healthcare, Performer, Gamer, Influencer,
--           Educator, Politician, Religion, Business
--
-- Design decisions (flagged items):
--   performer:crowd_reaction passive — deterministic sin(tick*0.7)*0.1 noise, NOT true random.
--     Chosen over seeded randomness for auditability and reproducibility. The tick loop
--     re-injects the value each tick using the match tick counter.
--   performer:spotlight_steal — two effects from one trigger. Primary effect stored normally;
--     secondary effect stored in metadata.secondary_effect. arena_trigger() v2 reads this
--     and pushes a second effect entry. No schema extension needed.
--   performer:standing_ovation — ramping multiplier stored as metadata.ramp. arena_trigger()
--     uses modifier_value as the start; tick loop interpolates between ramp.start and ramp.end
--     based on (now() - effect_pushed_at) / duration.
--   healthcare:resuscitate — not a standard modifier. Uses metadata.special_action = 'reset_baseline'.
--     arena_trigger() v2 handles it by snapping flow_rate_p1/p2 to their average at trigger time.
--   religion:prayer — same ramping pattern as standing_ovation.
--   business:monopoly — uses new flow_rate_ceiling modifier (7th allowed type). Ceiling value
--     is computed at trigger time from current opponent flow rate and stored in metadata.ceiling_value.
--   politician:debate — uses metadata.locks_abilities = true. arena_trigger() v2 checks this
--     before allowing any trigger. target='self' is sufficient since lockout check is global.
--   religion:revival — uses metadata.special_action = 'revival'. arena_trigger() v2 reads
--     arena_state.expired_effects (added in migration 045) to re-activate the most recent effect.
--   politician:power_move — uses metadata.special_action = 'subtract_opponent_flow'.
--     arena_trigger() v2 deducts 50% of opponent's current flow_rate directly.
--   religion:convert — uses metadata.special_action = 'convert_flow'.
--     arena_trigger() v2 transfers 5% of opponent's flow_rate to self.
--   gamer:combo — simplified to ability_effectiveness × 1.1 for 6s. True per-user
--     combo stack tracking deferred to Phase D.
--   influencer:break_the_algorithm — flow_rate_multiplier × 3.0 only; per-user flow cap
--     doubling deferred to Phase D.
--   educator:framework — ability_effectiveness × 1.05 + metadata.dampens_jitter = true.
--     Tick loop reads this flag when computing performer crowd_reaction amplitude.
--   business:acquisition — implemented as opponent_efficiency × 0.85 (sustained 15% flow
--     diversion) for 12s. Simpler than tracking per-tick transfer.
--   gamer:apm_scaling passive — computed each tick from count of all arena_events targeting
--     the Gamer player's side in the past 30s. Adds DB round-trip per tick per match; acceptable
--     at current scale. Phase D can cache via arena_state metadata if needed.
--   influencer:network_effect passive — computed each tick from distinct user_ids backing
--     this player in the full match history. Same DB round-trip caveat.
--   religion:faith passive — simplified time-ramp (not per-contribution time_held weighting).
--     Value ramps from 1.0 to 1.1 over 5 minutes (up to +10% at match end).
--   business:leverage passive — metadata.decay_factor_override = 0.95. Tick loop uses this
--     instead of the default c_flow_factor (0.9) when accumulating back events for this side.

-- ── Extend modifier CHECK to add flow_rate_ceiling ────────────────────────────

ALTER TABLE public.arena_abilities
  DROP CONSTRAINT IF EXISTS arena_abilities_modifier_check;

ALTER TABLE public.arena_abilities
  ADD CONSTRAINT arena_abilities_modifier_check CHECK (
    modifier IN (
      'flow_rate_multiplier',
      'heat_influence_multiplier',
      'ability_effectiveness',
      'opponent_efficiency',
      'momentum_window',
      'suppression_level',
      'flow_rate_ceiling'
    )
  );

-- ── MUSICIAN ──────────────────────────────────────────────────────────────────
-- Identity: wave amplifier, sustained influence.
-- replay_value passive makes all effects for the Musician side last 25% longer.
-- arena_trigger() v2 reads the passive from active_effects when computing expires_at.

INSERT INTO public.arena_abilities
  (id, archetype, ability_type, display_name, description, icon,
   cooldown_seconds, duration_seconds, token_cost, target, modifier, modifier_value,
   trigger_window, metadata)
VALUES
  (
    'musician:replay_value', 'musician', 'passive', 'Replay Value',
    '+25% ability effectiveness; all effects on this side last 25% longer',
    'replay',
    0, 0, 0, 'self', 'ability_effectiveness', 1.25,
    NULL, '{"duration_multiplier": 1.25}'::jsonb
  ),
  (
    'musician:drop', 'musician', 'core', 'The Drop',
    '3s momentum window — triggers MomentumSpike scoring bonus',
    'music_note',
    30, 3, 25, 'self', 'momentum_window', 1.0,
    NULL, '{}'::jsonb
  ),
  (
    'musician:hook', 'musician', 'core', 'Hook',
    '+30% heat influence for 12s — amplifies Heat Score contribution to ArenaScore',
    'whatshot',
    45, 12, 25, 'self', 'heat_influence_multiplier', 1.3,
    NULL, '{}'::jsonb
  ),
  (
    'musician:collab', 'musician', 'signature', 'Collab',
    'Opponent''s flow rate −15% for 15s (redirect 15% of their audience momentum)',
    'handshake',
    180, 15, 100, 'opponent', 'flow_rate_multiplier', 0.85,
    NULL, '{}'::jsonb
  ),
  (
    'musician:hit_record', 'musician', 'ultimate', 'Hit Record',
    '+100% flow rate for 10s — the breakout moment',
    'album',
    999999, 10, 500, 'self', 'flow_rate_multiplier', 2.0,
    NULL, '{}'::jsonb
  );

-- ── HEALTHCARE ────────────────────────────────────────────────────────────────
-- Identity: stabilizer, recovery.
-- stability passive reduces incoming suppression by 30% (via metadata.suppression_resistance).
-- Tick loop reads this flag after summing suppression effects and multiplies by (1 - 0.30).
-- stabilize temporarily zeroes suppression entirely (metadata.suppression_immunity = true).
-- resuscitate uses special_action = reset_baseline — handled in arena_trigger() v2.
-- critical_intervention uses momentum_window = 0.0 on opponent (suppresses momentum flags).

INSERT INTO public.arena_abilities
  (id, archetype, ability_type, display_name, description, icon,
   cooldown_seconds, duration_seconds, token_cost, target, modifier, modifier_value,
   trigger_window, metadata)
VALUES
  (
    'healthcare:stability', 'healthcare', 'passive', 'Stability',
    'Reduces incoming suppression effects by 30%',
    'health_and_safety',
    0, 0, 0, 'self', 'suppression_level', 0.0,
    NULL, '{"suppression_resistance": 0.3}'::jsonb
  ),
  (
    'healthcare:stabilize', 'healthcare', 'core', 'Stabilize',
    'Suppression immunity for 10s — all incoming suppression is nullified',
    'shield',
    60, 10, 25, 'self', 'suppression_level', 0.0,
    NULL, '{"suppression_immunity": true}'::jsonb
  ),
  (
    'healthcare:recovery', 'healthcare', 'core', 'Recovery',
    '+50% flow rate for 5s — rapid response burst',
    'favorite',
    60, 5, 25, 'self', 'flow_rate_multiplier', 1.5,
    NULL, '{}'::jsonb
  ),
  (
    'healthcare:critical_intervention', 'healthcare', 'signature', 'Critical Intervention',
    'Prevents opponent momentum spikes for 12s',
    'emergency',
    240, 12, 100, 'opponent', 'momentum_window', 0.0,
    NULL, '{"suppresses_momentum": true}'::jsonb
  ),
  (
    'healthcare:resuscitate', 'healthcare', 'ultimate', 'Resuscitate',
    'Snaps both sides to 50/50 flow rate — resets the match balance instantly',
    'medical_services',
    999999, 1, 500, 'self', 'flow_rate_multiplier', 1.0,
    NULL, '{"special_action": "reset_baseline"}'::jsonb
  );

-- ── PERFORMER ─────────────────────────────────────────────────────────────────
-- Identity: chaos, volatility, audience-driven spikes.
-- crowd_reaction passive — deterministic ±10% noise each tick using sin(tick * 0.7).
--   Re-injected each tick. Not truly random; uses match tick counter for auditability.
-- spotlight_steal — two effects from one trigger (primary: opponent debuff, secondary: self buff).
--   metadata.secondary_effect is read by arena_trigger() v2 to push a second effect.
-- standing_ovation — ramps from 1.5 to 2.5 over 10s.
--   metadata.ramp is interpolated by the tick loop based on effect age.

INSERT INTO public.arena_abilities
  (id, archetype, ability_type, display_name, description, icon,
   cooldown_seconds, duration_seconds, token_cost, target, modifier, modifier_value,
   trigger_window, metadata)
VALUES
  (
    'performer:crowd_reaction', 'performer', 'passive', 'Crowd Reaction',
    '±10% flow rate jitter per tick cycle (deterministic sin-wave, not random)',
    'theater_comedy',
    0, 0, 0, 'self', 'flow_rate_multiplier', 1.0,
    NULL, '{"jitter_amplitude": 0.1, "jitter_frequency": 0.7}'::jsonb
  ),
  (
    'performer:punchline', 'performer', 'core', 'Punchline',
    '+40% flow rate for 4s — instant crowd burst',
    'sentiment_very_satisfied',
    30, 4, 25, 'self', 'flow_rate_multiplier', 1.4,
    NULL, '{}'::jsonb
  ),
  (
    'performer:spotlight_steal', 'performer', 'core', 'Spotlight Steal',
    'Opponent −30% heat influence AND self +20% heat influence for 8s',
    'highlight',
    45, 8, 25, 'opponent', 'heat_influence_multiplier', 0.7,
    NULL, '{"secondary_effect": {"modifier": "heat_influence_multiplier", "value": 1.2, "target": "self"}}'::jsonb
  ),
  (
    'performer:viral_moment', 'performer', 'signature', 'Viral Moment',
    '6s momentum window — audience engagement triggers MomentumSpike',
    'trending_up',
    180, 6, 100, 'self', 'momentum_window', 1.0,
    NULL, '{}'::jsonb
  ),
  (
    'performer:standing_ovation', 'performer', 'ultimate', 'Standing Ovation',
    'Flow rate ramps from +50% to +150% over 10s (logarithmic climb)',
    'celebration',
    999999, 10, 500, 'self', 'flow_rate_multiplier', 1.5,
    NULL, '{"ramp": {"start": 1.5, "end": 2.5}}'::jsonb
  );

-- ── GAMER ─────────────────────────────────────────────────────────────────────
-- Identity: timing precision, high-skill amplification.
-- apm_scaling passive — dynamic; computed each tick from recent actions targeting
--   this player's side in the past 30s. Value = 1 + min(count * 0.05, 0.5).
-- combo — simplified to ability_effectiveness × 1.1 for 6s (Phase D: true combo tracking).
-- tilt — debuffs opponent's ability effectiveness.
-- perfect_play — ultimate doubles all ability effects for 5s.

INSERT INTO public.arena_abilities
  (id, archetype, ability_type, display_name, description, icon,
   cooldown_seconds, duration_seconds, token_cost, target, modifier, modifier_value,
   trigger_window, metadata)
VALUES
  (
    'gamer:apm_scaling', 'gamer', 'passive', 'APM Scaling',
    '+5% ability effectiveness per recent action (past 30s), capped at +50%',
    'speed',
    0, 0, 0, 'self', 'ability_effectiveness', 1.0,
    NULL, '{"dynamic_passive": "apm_scaling", "per_action_bonus": 0.05, "cap": 0.5}'::jsonb
  ),
  (
    'gamer:combo', 'gamer', 'core', 'Combo',
    '+10% ability effectiveness for 6s (simplified — Phase D adds true stack tracking)',
    'gamepad',
    45, 6, 25, 'self', 'ability_effectiveness', 1.1,
    NULL, '{}'::jsonb
  ),
  (
    'gamer:tilt', 'gamer', 'core', 'Tilt',
    'Opponent −25% ability effectiveness for 10s — disrupts their ability synergy',
    'sports_esports',
    45, 10, 25, 'opponent', 'ability_effectiveness', 0.75,
    NULL, '{}'::jsonb
  ),
  (
    'gamer:power_spike', 'gamer', 'signature', 'Power Spike',
    '+80% flow rate for 8s — peak performance window',
    'bolt',
    180, 8, 100, 'self', 'flow_rate_multiplier', 1.8,
    NULL, '{}'::jsonb
  ),
  (
    'gamer:perfect_play', 'gamer', 'ultimate', 'Perfect Play',
    '+100% ability effectiveness for 5s — all triggered abilities are doubled',
    'stars',
    999999, 5, 500, 'self', 'ability_effectiveness', 2.0,
    NULL, '{}'::jsonb
  );

-- ── INFLUENCER ────────────────────────────────────────────────────────────────
-- Identity: network effects, audience scaling.
-- network_effect passive — dynamic; computed each tick from distinct user_ids
--   in this match's back events for this side. Value = 1 + min(distinct * 0.005, 0.30).
-- trend — value computed at trigger time from distinct backers in last 60s / 5 (clusters).
--   arena_trigger() v2 reads arena_events and computes; stores result as effect value.
-- viral_loop — at trigger time, sums the last 30s of back event values for this side,
--   applies 30% as a flow multiplier boost. Computed in arena_trigger() v2.
-- break_the_algorithm — flow_rate_multiplier × 3.0 only; per-user cap doubling = Phase D.

INSERT INTO public.arena_abilities
  (id, archetype, ability_type, display_name, description, icon,
   cooldown_seconds, duration_seconds, token_cost, target, modifier, modifier_value,
   trigger_window, metadata)
VALUES
  (
    'influencer:network_effect', 'influencer', 'passive', 'Network Effect',
    '+0.5% flow rate per unique backer this match, capped at +30%',
    'group',
    0, 0, 0, 'self', 'flow_rate_multiplier', 1.0,
    NULL, '{"dynamic_passive": "network_effect", "per_user_bonus": 0.005, "cap": 0.30}'::jsonb
  ),
  (
    'influencer:trend', 'influencer', 'core', 'Trend',
    'Flow rate boost based on active user clusters (distinct backers / 5) for 12s',
    'trending_up',
    45, 12, 25, 'self', 'flow_rate_multiplier', 1.25,
    NULL, '{"dynamic_at_trigger": "trend_clusters", "cluster_divisor": 5, "cluster_bonus": 0.1}'::jsonb
  ),
  (
    'influencer:call_to_action', 'influencer', 'core', 'Call to Action',
    '+30% flow rate for 8s — direct audience rally',
    'campaign',
    45, 8, 25, 'self', 'flow_rate_multiplier', 1.3,
    NULL, '{}'::jsonb
  ),
  (
    'influencer:viral_loop', 'influencer', 'signature', 'Viral Loop',
    'Recycles 30% of recent 30s back momentum into a 15s flow boost',
    'autorenew',
    180, 15, 100, 'self', 'flow_rate_multiplier', 1.3,
    NULL, '{"dynamic_at_trigger": "viral_loop", "recycle_pct": 0.30, "recycle_window_secs": 30}'::jsonb
  ),
  (
    'influencer:break_the_algorithm', 'influencer', 'ultimate', 'Break the Algorithm',
    '+200% flow rate for 10s (per-user cap doubling in Phase D)',
    'bolt',
    999999, 10, 500, 'self', 'flow_rate_multiplier', 3.0,
    NULL, '{}'::jsonb
  );

-- ── EDUCATOR ─────────────────────────────────────────────────────────────────
-- Identity: efficiency, optimization.
-- efficiency passive — +15% flow rate multiplier (models 15% more value per back action).
-- optimize — token cost discount 20% for ability triggers while active (checked in arena_trigger v2).
-- explain — +10% ability effectiveness for all triggers on this side.
-- framework — ability_effectiveness × 1.05 + metadata.dampens_jitter flag.
--   Tick loop halves performer crowd_reaction jitter amplitude when this effect is active.
-- masterclass — +100% flow rate for 10s (models "2× efficient backs").

INSERT INTO public.arena_abilities
  (id, archetype, ability_type, display_name, description, icon,
   cooldown_seconds, duration_seconds, token_cost, target, modifier, modifier_value,
   trigger_window, metadata)
VALUES
  (
    'educator:efficiency', 'educator', 'passive', 'Efficiency',
    '+15% flow rate — all backing contributions are 15% more effective',
    'school',
    0, 0, 0, 'self', 'flow_rate_multiplier', 1.15,
    NULL, '{}'::jsonb
  ),
  (
    'educator:optimize', 'educator', 'core', 'Optimize',
    'Ability costs −20% for users backing this side for 10s',
    'tune',
    45, 10, 25, 'self', 'ability_effectiveness', 1.0,
    NULL, '{"ability_cost_discount": 0.20}'::jsonb
  ),
  (
    'educator:explain', 'educator', 'core', 'Explain',
    '+10% ability effectiveness for all triggers on this side for 10s',
    'lightbulb',
    45, 10, 25, 'self', 'ability_effectiveness', 1.1,
    NULL, '{}'::jsonb
  ),
  (
    'educator:framework', 'educator', 'signature', 'Framework',
    '+5% ability effectiveness + dampens opponent jitter effects by 50% for 15s',
    'architecture',
    180, 15, 100, 'self', 'ability_effectiveness', 1.05,
    NULL, '{"dampens_jitter": true, "jitter_dampen_factor": 0.5}'::jsonb
  ),
  (
    'educator:masterclass', 'educator', 'ultimate', 'Masterclass',
    '+100% flow rate for 10s — peak teaching moment',
    'workspace_premium',
    999999, 10, 500, 'self', 'flow_rate_multiplier', 2.0,
    NULL, '{}'::jsonb
  );

-- ── POLITICIAN ────────────────────────────────────────────────────────────────
-- Identity: control, suppression.
-- influence passive — +10% ability effectiveness (suppression abilities hit harder).
-- debate — locks ability triggers for both sides for 12s (only Backs allowed).
--   metadata.locks_abilities = true checked in arena_trigger() v2 before any Trigger.
--   target='self' is sufficient; lockout check in arena_trigger() scans ALL active effects.
-- power_move — special_action = subtract_opponent_flow. arena_trigger() v2 reads
--   opponent's current flow_rate and deducts 50% directly at trigger time.

INSERT INTO public.arena_abilities
  (id, archetype, ability_type, display_name, description, icon,
   cooldown_seconds, duration_seconds, token_cost, target, modifier, modifier_value,
   trigger_window, metadata)
VALUES
  (
    'politician:influence', 'politician', 'passive', 'Influence',
    '+10% ability effectiveness — all effects hit harder',
    'how_to_vote',
    0, 0, 0, 'self', 'ability_effectiveness', 1.1,
    NULL, '{}'::jsonb
  ),
  (
    'politician:spin', 'politician', 'core', 'Spin',
    'Opponent −25% flow rate for 10s — disrupts their momentum narrative',
    'rotate_right',
    45, 10, 25, 'opponent', 'flow_rate_multiplier', 0.75,
    NULL, '{}'::jsonb
  ),
  (
    'politician:rally', 'politician', 'core', 'Rally',
    '+30% flow rate for 10s — mobilize the base',
    'campaign',
    45, 10, 25, 'self', 'flow_rate_multiplier', 1.3,
    NULL, '{}'::jsonb
  ),
  (
    'politician:debate', 'politician', 'signature', 'Debate',
    'Locks all ability triggers for BOTH sides for 12s — only Back actions allowed',
    'record_voice_over',
    240, 12, 100, 'self', 'ability_effectiveness', 1.0,
    NULL, '{"locks_abilities": true}'::jsonb
  ),
  (
    'politician:power_move', 'politician', 'ultimate', 'Power Move',
    'Instantly removes 50% of opponent''s accumulated flow rate',
    'gavel',
    999999, 1, 500, 'opponent', 'flow_rate_multiplier', 1.0,
    NULL, '{"special_action": "subtract_opponent_flow", "subtract_pct": 0.5}'::jsonb
  );

-- ── RELIGION ─────────────────────────────────────────────────────────────────
-- Identity: delayed payoff, faith scaling.
-- faith passive — time-based ramp; re-injected each tick. Value = 1 + min(elapsed/300 * 0.1, 0.1).
--   Up to +10% flow rate at match end (simplified from per-contribution time_held weighting).
-- prayer — ramping effect; metadata.ramp read by tick loop to interpolate value.
-- convert — special_action = convert_flow. arena_trigger() v2 transfers 5% of opponent's
--   current flow_rate to this side at trigger time.
-- revival — special_action = revival. arena_trigger() v2 reads arena_state.expired_effects
--   (added in migration 045) and re-pushes the most recent effect with 50% duration.
-- miracle — deterministic "random" swing: sin(tick * 2.7) maps to [0.5, 3.0].
--   Value computed at trigger time in arena_trigger() v2 using current match tick.

INSERT INTO public.arena_abilities
  (id, archetype, ability_type, display_name, description, icon,
   cooldown_seconds, duration_seconds, token_cost, target, modifier, modifier_value,
   trigger_window, metadata)
VALUES
  (
    'religion:faith', 'religion', 'passive', 'Faith',
    'Flow rate grows with match duration — up to +10% at 5 minutes',
    'church',
    0, 0, 0, 'self', 'flow_rate_multiplier', 1.0,
    NULL, '{"time_ramp": true, "ramp_per_300s": 0.1}'::jsonb
  ),
  (
    'religion:prayer', 'religion', 'core', 'Prayer',
    'Flow rate ramps from baseline to +50% over 10s',
    'self_improvement',
    30, 10, 25, 'self', 'flow_rate_multiplier', 1.0,
    NULL, '{"ramp": {"start": 1.0, "end": 1.5}}'::jsonb
  ),
  (
    'religion:convert', 'religion', 'core', 'Convert',
    'Transfers 5% of opponent''s current flow rate to your side instantly',
    'swap_horiz',
    60, 1, 25, 'opponent', 'flow_rate_multiplier', 1.0,
    NULL, '{"special_action": "convert_flow", "transfer_pct": 0.05}'::jsonb
  ),
  (
    'religion:revival', 'religion', 'signature', 'Revival',
    'Re-activates the most recently expired effect on your side with 50% duration',
    'restore',
    180, 1, 100, 'self', 'flow_rate_multiplier', 1.0,
    NULL, '{"special_action": "revival"}'::jsonb
  ),
  (
    'religion:miracle', 'religion', 'ultimate', 'Miracle',
    'Deterministic swing: flow rate ×0.5 to ×3.0 for 5s (computed from match tick)',
    'auto_awesome',
    999999, 5, 500, 'self', 'flow_rate_multiplier', 1.0,
    NULL, '{"special_action": "miracle", "range_min": 0.5, "range_max": 3.0}'::jsonb
  );

-- ── BUSINESS ─────────────────────────────────────────────────────────────────
-- Identity: capital efficiency, compounding.
-- leverage passive — decay_factor_override = 0.95. Tick loop uses this instead of
--   default 0.9 when computing per-action diminishing returns for this side.
-- invest — scheduled effect: activates 15s after trigger. arena_trigger() v2 stores
--   activates_at = now() + 15s in the effect JSON. Tick loop skips effects where
--   now() < activates_at.
-- cut_costs — 30% token cost discount (stronger/shorter than educator:optimize).
-- acquisition — opponent_efficiency × 0.85 for 12s (sustained 15% flow diversion).
--   Note: cleaner than tracking per-tick transfer across both state rows.
-- monopoly — flow_rate_ceiling modifier (7th allowed type). Ceiling value is read from
--   opponent's current flow_rate at trigger time by arena_trigger() v2 and stored in
--   effect metadata. Tick loop clamps opponent's new flow accumulation to this ceiling.

INSERT INTO public.arena_abilities
  (id, archetype, ability_type, display_name, description, icon,
   cooldown_seconds, duration_seconds, token_cost, target, modifier, modifier_value,
   trigger_window, metadata)
VALUES
  (
    'business:leverage', 'business', 'passive', 'Leverage',
    'Gentler diminishing returns on backs — large investments scale better',
    'trending_up',
    0, 0, 0, 'self', 'flow_rate_multiplier', 1.0,
    NULL, '{"decay_factor_override": 0.95}'::jsonb
  ),
  (
    'business:invest', 'business', 'core', 'Invest',
    '+50% flow rate — activates 15s after trigger, lasts 5s (delayed ROI)',
    'savings',
    60, 5, 25, 'self', 'flow_rate_multiplier', 1.5,
    NULL, '{"scheduled_delay_secs": 15}'::jsonb
  ),
  (
    'business:cut_costs', 'business', 'core', 'Cut Costs',
    'Ability costs −30% for users backing this side for 10s',
    'content_cut',
    60, 10, 25, 'self', 'ability_effectiveness', 1.0,
    NULL, '{"ability_cost_discount": 0.30}'::jsonb
  ),
  (
    'business:acquisition', 'business', 'signature', 'Acquisition',
    'Opponent −15% efficiency for 12s (absorbs 15% of their output flow)',
    'corporate_fare',
    180, 12, 100, 'opponent', 'opponent_efficiency', 0.85,
    NULL, '{}'::jsonb
  ),
  (
    'business:monopoly', 'business', 'ultimate', 'Monopoly',
    'Caps opponent''s flow rate at its current value for 8s — no further growth',
    'block',
    999999, 8, 500, 'opponent', 'flow_rate_ceiling', 1.0,
    NULL, '{"special_action": "monopoly_ceiling"}'::jsonb
  );
