# NORA Chit Effect Library — Wave 1 proposal (for balance approval)

**Status:** ✅ SHIPPED 2026-07-05 (migs 151 + 152 applied; `derive_chit_stats`, `moment-classify`
selection, and `cinematic-mint` deployed). Balance numbers below are live and tunable per season.
Generated from
`NORA_CHIT_EFFECT_DESIGN_FRAMEWORK.md` (§1 identity matrix as guardrail, §2 cycles as the
horizontal check, §9 as the row pattern), scoped to the approved Wave 1: **single-clause
only** (`complexity=1`), **3 templates per family** (each family's existing live template +
2 new), single Aura curve + Vibe gate unchanged.

Approve / adjust the **Base magnitude** numbers and the **`magnitude_scales`** decision, and
this becomes the seed migration.

---

## Decisions folded in (call these out if you disagree)

1. **`magnitude_scales boolean default true`** — a 7th additive column beyond the framework's
   six. Count/resource effects don't scale with tier (else a draw_card at S draws 8 cards). Set
   **false** for `draw_card`, `disrupt_discard`, `aura_refund`, `removal`, `taunt_grant`,
   `summon_token`; **true** for all damage/buff/debuff/heal/shield. Also retro-fixes the three
   existing count-templates (Go Viral / Heckle / Dividend).
2. **No `summon_token` templates in Wave 1** — the resolver stubs it as a no-op today (mig 128).
   Deferred to Wave 2 with compound effects.
3. **`stat_lean`** (approved): `aggressive` ≈ 75% toward ATK-max / 25% toward HP-min,
   `defensive` the inverse, `balanced` = tier midpoint (current behavior). Spell-moments ignore it.
4. Every new template obeys its family's §1 **Primary/Secondary/Rare** rows and never touches a
   **Never** cell. Cycles (§2) are woven so no effect kind lives in a single family.

**Constant in Wave 1 (omitted from the tables):** `complexity=1`, `min_tier_band=NULL`,
`family_signature=false` for every row (compound cards + signatures are Wave 2).

---

## The library — 10 families × 3

Legend: **Scales** = `magnitude_scales`. *(existing)* = the live template, unchanged except for
the `magnitude_scales` back-fill. Base magnitude is the value at `effect_power=1` (F-tier);
concrete magnitude = `round(base × tier.effect_power)` when Scales=Y.

### Athlete — P: direct_damage, buff_atk · identity: aggressive body
| Name | Timing | Effect → Target | Base | Scales | Keyword | Lean | Cycle |
|---|---|---|---|---|---|---|---|
| Adrenaline Rush *(existing)* | on_summon | buff_atk → self | 2 | Y | — | aggressive | — |
| Highlight Reel | on_summon | direct_damage → enemy_target | 2 | Y | charge | aggressive | single_target_burst |
| Second Wind | activated | heal → self | 2 | Y | — | balanced | second_wind |

### Musician — P: debuff_atk, heal · identity: crowd manipulation
| Name | Timing | Effect → Target | Base | Scales | Keyword | Lean | Cycle |
|---|---|---|---|---|---|---|---|
| Encore *(existing)* | on_summon | debuff_atk → all_enemies | 1 | Y | — | balanced | — |
| Mosh Pit | on_summon | aoe_damage → all_enemies | 1 | Y | — | balanced | crowd_control_aoe |
| Ballad | activated | heal → ally_target | 2 | Y | — | balanced | second_wind |

### Artist — P: buff_hp, buff_atk_hp · identity: build others up
| Name | Timing | Effect → Target | Base | Scales | Keyword | Lean | Cycle |
|---|---|---|---|---|---|---|---|
| Inspire *(existing)* | on_summon | buff_hp → all_allies | 1 | Y | — | balanced | — |
| Masterpiece | on_summon | buff_atk_hp → ally_target | 1 | Y | — | balanced | — |
| Muse | triggered (start_of_turn) | draw_card → self | 1 | N | — | balanced | steady_draw |

### Scientist — P: removal, debuff_atk · identity: control
| Name | Timing | Effect → Target | Base | Scales | Keyword | Lean | Cycle |
|---|---|---|---|---|---|---|---|
| Purge *(existing)* | activated | removal → enemy_target | 1 | N | — | balanced | — |
| Experiment | on_summon | debuff_hp → enemy_target | 2 | Y | — | balanced | — |
| Formula | activated | shield_grant → ally_target | 2 | Y | — | defensive | aegis |

### Comedian — P: disrupt_discard, debuff_atk · identity: disruption
| Name | Timing | Effect → Target | Base | Scales | Keyword | Lean | Cycle |
|---|---|---|---|---|---|---|---|
| Heckle *(existing)* | on_summon | disrupt_discard → enemy_target | 1 | N | — | balanced | — |
| Punchline | on_summon | aoe_damage → all_enemies | 1 | Y | — | balanced | crowd_control_aoe |
| Roast | activated | debuff_atk → enemy_target | 2 | Y | — | balanced | — |

### Influencer — P: draw_card · identity: card advantage / reach
| Name | Timing | Effect → Target | Base | Scales | Keyword | Lean | Cycle |
|---|---|---|---|---|---|---|---|
| Go Viral *(existing)* | on_summon | draw_card → self | 1 | N | — | balanced | — |
| Trending | on_summon | buff_hp → all_allies | 1 | Y | — | balanced | — |
| Clapback | activated | disrupt_discard → enemy_target | 1 | N | — | balanced | — |

### Politician — P: buff_atk, taunt_grant · identity: rally & protect
| Name | Timing | Effect → Target | Base | Scales | Keyword | Lean | Cycle |
|---|---|---|---|---|---|---|---|
| Rally *(existing)* | triggered (start_of_turn) | buff_atk → all_allies | 1 | Y | — | balanced | — |
| Take the Hit | on_summon | taunt_grant → ally_target | 1 | N | — | defensive | bodyguard |
| Filibuster | activated | aura_refund → self | 1 | N | — | balanced | — |

### Business — P: aura_refund · identity: economy / tempo
| Name | Timing | Effect → Target | Base | Scales | Keyword | Lean | Cycle |
|---|---|---|---|---|---|---|---|
| Dividend *(existing)* | on_summon | aura_refund → self | 1 | N | — | balanced | — |
| Investment | on_summon | buff_hp → self | 2 | Y | — | defensive | — |
| Acquisition | activated | draw_card → self | 1 | N | — | balanced | steady_draw |

### Gamer — P: direct_damage · identity: precision & burst
| Name | Timing | Effect → Target | Base | Scales | Keyword | Lean | Cycle |
|---|---|---|---|---|---|---|---|
| Snipe *(existing)* | activated | direct_damage → enemy_target | 2 | Y | — | aggressive | single_target_burst |
| Multi-Kill | on_summon | aoe_damage → all_enemies | 1 | Y | — | aggressive | crowd_control_aoe |
| Grind | activated | draw_card → self | 1 | N | — | balanced | steady_draw |

### Actor — P: shield_grant · identity: reactive resilience
| Name | Timing | Effect → Target | Base | Scales | Keyword | Lean | Cycle |
|---|---|---|---|---|---|---|---|
| Understudy *(existing)* | counter (when_attacked) | shield_grant → self | 1 | Y | — | defensive | aegis |
| Stunt Double | on_summon | taunt_grant → ally_target | 1 | N | — | defensive | bodyguard |
| Recovery Scene | triggered (start_of_turn) | heal → self | 2 | Y | — | balanced | second_wind |

---

## Cycle map (horizontal authoring check, §2)

| Cycle | Kind | Members |
|---|---|---|
| `single_target_burst` | direct_damage | Gamer/Snipe · Athlete/Highlight Reel *(Charge)* |
| `crowd_control_aoe` | aoe_damage | Musician/Mosh Pit · Comedian/Punchline · Gamer/Multi-Kill |
| `second_wind` | heal | Athlete/Second Wind · Musician/Ballad · Actor/Recovery Scene *(varies timing per family — intended)* |
| `bodyguard` | taunt_grant→ally | Politician/Take the Hit · Actor/Stunt Double *(Scientist intentionally excluded — anti-cycle)* |
| `steady_draw` | draw_card | Artist/Muse · Business/Acquisition · Gamer/Grind |
| `aegis` | shield_grant | Scientist/Formula · Actor/Understudy |

## Coverage after Wave 1

- **Timings:** on_summon 16 · activated 10 · triggered 3 · counter 1 (was 6/2/1/1 — lopsidedness fixed; counter stays scarce by design, it's the riskiest slot).
- **Effect kinds now used:** every kind except `summon_token` (deferred with the resolver work).
- **Previously-unused kinds now homed:** `aoe_damage`, `buff_atk_hp`, `debuff_hp`, `heal`, `taunt_grant` — each on a family whose matrix allows it.

---

## What gets wired on your approval (parallel tracks)

**A. Schema (migration 151, additive):** `cycle_key`, `grants_keywords text[]`, `complexity smallint
default 1`, `min_tier_band text`, `stat_lean text default 'balanced'`, `family_signature boolean
default false`, **`magnitude_scales boolean default true`**. Back-fill the 10 existing rows
(cycle/lean per table above; count-kinds → `magnitude_scales=false`).

**B. Derivation:** `derive_chit_stats` reads `magnitude_scales` (flat base when false) and
`stat_lean` (bias the ATK/HP point inside the tier's existing range).

**C. Selection stage:** `moment-classify` also selects `timing_type` + `effect_template_id` from
the classified family's candidate set (sim = deterministic hash; live = LLM allowlist pick) and
**persists it on the moment server-side** — cinematic-mint reads it there, never from the client
(closes the Hard-Rule-34 tamper vector). `grants_keywords` union into the chit's keywords;
`compose_chit_rules` then prints the matching rules automatically.

**D. Seed migration (152):** the 20 new templates above, once numbers are approved.
