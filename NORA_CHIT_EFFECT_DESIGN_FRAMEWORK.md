# NORA Battle Chit Design Framework — MTG × D&D Structural Import
**For Claude Code. Extends the `effect_templates`/`tier_ladder` system already built (v3 CCG spec). This is a design framework, not a phased build spec — read it fully, then use §9 (Athlete worked example) as the pattern to generate the remaining 9 families' expanded template sets for the user's balance approval, per the sequencing in §11.**

---

## 0. Why these two games, and the one hard boundary

**Magic: The Gathering** is the right donor because it is, structurally, the same problem you have: a fixed small set of resources (5 colors ≈ your archetype families) each need a *distinct mechanical identity* that scales combinatorially across thousands of cards without every card being bespoke. MTG solved this with the **color pie** (what each color is allowed to do), **cycles** (authoring horizontally across colors, not vertically within one), **rarity** (power expressed through complexity, not just numbers), and **keywords** (reusable named abilities that combine instead of requiring new templates). All four transfer directly.

**Dungeons & Dragons** contributes at the *creature-authoring* level: the **stat block** (a monster is a bundle of Traits/Actions/Reactions, not a player character), the **action economy** (a clean taxonomy of "when can this happen"), and **Challenge Rating budgeting** (a creature's power is an allocated budget, spent on offense vs. defense in different proportions at the same power level).

**⚠️ Explicit non-import, stated up front:** D&D's *ability scores and saving throws* are a player-facing stat system — exactly what your "no class edges, the chits decide the match" decision cut. Nothing below reintroduces player-level stats. Likewise, MTG's colored-mana system (multiple resource types gating what you can cast) is **not** imported — you deliberately run a single Aura curve + a symmetric Vibe gate, and that stays exactly as designed. Where an idea below could be mistaken for a third resource, I've flagged it.

---

## 1. Import A — Family Identity Matrix (from MTG's Color Pie)

**The gap it solves:** right now each family has exactly one template, so there's no stated answer to "is the 4th Athlete template on-theme?" The color pie is MTG's answer to that question for colors — an explicit permission table per color, per effect. Formalize the same thing for families.

**Structural.** Add this as a design-reference table (not necessarily a DB table — a doc Claude Code and future authors check before writing a template). Each family gets a stated **Primary** (this is core to the family, author here often), **Secondary** (occasional, reinforces identity), **Rare** (allowed once in a while for surprise), **Never** (this family should not do this — an intentional gap, exactly like MTG's "black doesn't get free lifegain" rule).

| Family | Primary | Secondary | Rare | Never |
|---|---|---|---|---|
| Athlete | direct_damage, buff_atk | aoe_damage, buff_atk_hp, taunt_grant | shield_grant, heal | draw_card, aura_refund, disrupt_discard |
| Musician | debuff_atk, heal | aoe_damage, buff_hp, disrupt_discard | buff_atk_hp | aura_refund, direct_damage, taunt_grant |
| Artist | buff_hp, buff_atk_hp | heal, draw_card | shield_grant | direct_damage, aoe_damage, disrupt_discard, aura_refund |
| Scientist | removal, debuff_atk | debuff_hp, summon_token, shield_grant | draw_card | heal, buff_atk_hp, aura_refund, taunt_grant, direct_damage, aoe_damage |
| Comedian | disrupt_discard, debuff_atk | aoe_damage, summon_token | draw_card | heal, shield_grant, taunt_grant, aura_refund, buff_atk_hp |
| Influencer | draw_card | buff_hp, disrupt_discard | aoe_damage | removal, direct_damage, shield_grant, taunt_grant, heal, aura_refund, buff_atk_hp |
| Politician | buff_atk, taunt_grant | buff_atk_hp, aura_refund, disrupt_discard | summon_token | direct_damage, aoe_damage, heal, removal |
| Business | aura_refund | buff_hp, summon_token, draw_card | shield_grant | direct_damage, aoe_damage, heal, disrupt_discard, removal, debuff_atk, debuff_hp, taunt_grant |
| Gamer | direct_damage | aoe_damage, summon_token, draw_card | shield_grant | heal, aura_refund, buff_atk_hp, taunt_grant, disrupt_discard |
| Actor | shield_grant | taunt_grant, heal | removal, buff_atk_hp | aoe_damage, disrupt_discard, aura_refund, draw_card, direct_damage |

**This is a proposal, not a mandate** — the exact cell assignments are yours to tune. What matters structurally is *having* the matrix and checking new templates against it, so families stay distinguishable as the library grows instead of converging into ten reskins of the same three effects. Note it also gives every one of the 7 previously-unused effect kinds (`aoe_damage`, `buff_atk_hp`, `debuff_hp`, `heal`, `taunt_grant`, `summon_token`, and a second home for `shield_grant`) a coherent thematic owner.

---

## 2. Import B — Cycles, Not Silos (from MTG's cycle design)

**The gap it solves:** your own notes flag "lopsided timings: 6 on_summon, 2 activated, 1 triggered, 1 counter" and "7 of 15 effect kinds unused." That's what happens when templates are authored *vertically* (fill out one family completely, then the next). MTG's fix is to author **horizontally**: pick one effect idea, and give a version of it to every family whose identity matrix (§1) allows it — with the *timing* and *flavor* varying per family, but the underlying shape shared. This one habit fixes both lopsidedness problems at once, automatically, because you're filling a row across all families instead of a column within one.

**Structural: add a `cycle_key` column to `effect_templates`** — a free-text tag grouping templates authored as one cycle. Purely organizational (helps you see gaps and lets a future balance pass touch a whole cycle at once), but real.

Four worked cycles, showing the pattern (not exhaustive — extend using §1):

| `cycle_key` | Effect kind | Members (family / template / timing) | The variance across the cycle |
|---|---|---|---|
| `single_target_burst` | direct_damage | Gamer/Snipe (activated) · Athlete/Highlight Reel (on_summon + Charge) | Gamer's version is calculated and repeatable; Athlete's is instinctive, once, and can act immediately (Charge) |
| `crowd_control_aoe` | aoe_damage | Musician/Mosh Pit (on_summon) · Comedian/Pie Fight (on_summon) | Same shape, different flavor text and VFX family |
| `second_wind` | heal | Athlete/Second Wind (activated) · Musician/Encore (on_summon) · Actor/Recovery Scene (triggered, start_of_turn) | **A cycle can vary timing per family** — that's itself part of family flavor, straight out of MTG (a cycle is sometimes instant in one color, sorcery in another) |
| `bodyguard` | taunt_grant (to an ally, not self) | Politician/Take the Hit (on_summon) · Actor/Stunt Double (on_summon, compound — see §4) | **Scientist deliberately excluded** — an intentional gap (MTG calls this an "anti-cycle": leaving a member out on purpose reinforces that family's identity by what it *doesn't* do) |

---

## 3. Import C — Keyword Grammar (from MTG's evergreen keywords + D&D's action economy)

**The gap it solves:** without a keyword layer, every new combination needs a brand-new bespoke template. MTG's actual scaling trick isn't "write more cards" — it's a small set of **orthogonal, reusable keywords** (Flying, Trample, Haste, Vigilance…) that combine with any card shape. You already have this instinct (Taunt/Charge/Shield/Stealth from the v3 spec) — this import says: lean on it harder, and treat a template as a **combination of slots**, not an atomic thing:

```
Template = Timing × Effect kind × Target × [Keyword(s)] × [Condition]
```

**Structural: add `grants_keywords text[]`** to `effect_templates` — the keyword(s) a template stamps onto the minted chit (feeds the same `derive_chit_stats`/`compose_chit_rules` threading already described). This is also a free bonus to your **fusion system** (mig 124): fusion already pattern-matches on family/keyword/element tags, so every template that grants a keyword adds surface area fusion can combine on, at no extra engineering cost.

**One new keyword candidate, D&D-flavored: `Recharge`** — an activated ability usable once, then locked for N turns. This is D&D's Legendary Action / Recharge-roll idea (a monster's big move that isn't spammable), and it's a **third gating axis that is not a new resource** — Aura still answers "can I afford it," Vibe still answers "is the crowd hyped," Recharge just answers "have I used this recently." Worth having; not load-bearing if you'd rather hold it.

**Thematic, not structural — flag for Claude Code's judgment:** renaming the `timing_type` enum values to D&D's action-economy terms (`on_summon`≈Trait, `activated`≈Action, `triggered`≈Reaction/Trait, `counter`≈Reaction) is a nice **documentation** clarification but **do not rename the live enum** — that's pure churn for a naming benefit. If it helps, keep it as an explanatory comment/mapping in design docs only.

---

## 4. Import D — Rarity-as-Complexity + Stat Lean (from MTG's rarity/vanilla test + D&D's CR budget)

**The gap it solves:** right now tier only scales *magnitude* (Snipe deals 2 at F, 16 at S) — same shape, bigger number. MTG's rarity system says power should also show up as **design richness**: commons are single-clause ("deal 3 damage"), rares combine effects ("deal 3 damage AND draw a card"). D&D's Challenge Rating does something adjacent — a monster's power budget can be **allocated** toward offense or defense, not just scaled uniformly.

**Structural: two new columns.**

- **`complexity` (smallint, default 1).** `1` = simple, single-clause effect, eligible at any tier. `2` = compound, multi-clause effect (e.g., "grant all allies +1/+1 AND grant this creature Taunt"), and **requires `min_tier_band`** to be set.
- **`min_tier_band` (nullable, references `tier_ladder.tier` ordering F<E<D<C<B<A<S).** A compound template is only in the candidate set for a chit whose *rolled* tier meets or exceeds this band. This is the direct mechanism for "an S-tier athlete could prefer a splashier template" — the bolt-on you already floated — except it's not just a *preference weight*, it's a **hard eligibility gate**, so an F-tier card is *structurally* simpler, not just numerically smaller. That's the MTG rarity feeling, achieved with two columns.
- **`stat_lean` (text enum: `aggressive` | `balanced` | `defensive`, default `balanced`; creature templates only).** Tells `derive_chit_stats` *where inside the tier's existing ATK/HP range* to land — `aggressive` skews toward the top of the ATK range and bottom of HP, `defensive` the reverse. This is the D&D CR "allocate the budget" idea, and it's fully additive: the tier ladder's ranges don't change, this just picks a point inside them instead of always defaulting to the middle.

**Critical consistency guardrail — ties to the already-locked ascension rule:** `min_tier_band` gating applies **only at mint-time template selection.** When a chit later *ascends* (weekly refresh, engagement climbs), it re-scales magnitude through its **already-assigned** template — it does **not** re-roll or upgrade to a newly-eligible compound template just because it crossed a complexity threshold. This preserves "family/effect type is fixed at mint; only magnitude scales," which you locked earlier. Don't let this framework silently violate that.

---

## 5. Schema additions — summary

All additive/nullable; none of this touches the existing 10 live templates, which simply get `complexity=1`, `min_tier_band=NULL`, `stat_lean='balanced'` by default.

| Column (on `effect_templates`) | Type | Purpose |
|---|---|---|
| `cycle_key` | text, nullable | Groups horizontally-authored templates (§2) |
| `grants_keywords` | text[], nullable | Keywords stamped onto the minted chit (§3) |
| `complexity` | smallint, default 1 | 1 = simple, 2 = compound (§4) |
| `min_tier_band` | text, nullable | Minimum tier for eligibility, compound templates only (§4) |
| `stat_lean` | text enum, default `balanced` | Where in the tier's ATK/HP range to land; creatures only (§4) |
| `family_signature` | boolean, default false | Flags a family's identity-defining mechanic (§7) |

---

## 6. Pipeline integration — exactly where this plugs in

Your existing mechanism (classify → candidate set → sim-hash or live-LLM pick → thread down) is **unchanged in shape.** This framework only enriches Step 1 and adds one field to Step 3.

**Step 1 (candidate-set query) gains two more AND-conditions**, illustrative pseudocode:

```sql
SELECT * FROM effect_templates
WHERE archetype_family = <classified family>
  AND is_active AND is_fusion = false
  AND <chit_type timing filter, unchanged>
  AND (complexity = 1 OR min_tier_band IS NULL
       OR tier_rank(min_tier_band) <= tier_rank(<rolled tier>))  -- NEW
```
(Needs a small `tier_rank()` helper mapping F<E<D<C<B<A<S to an ordinal — trivial, likely a CASE expression or a small lookup.)

**Step 2 (sim-hash / live-LLM selection)** — **unchanged.** The framework only changes which templates are *in* the candidate set; it doesn't touch how one gets picked from it. Both your deterministic hash and your LLM-allowlist classifier keep working exactly as designed.

**Step 3 (thread down via `derive_chit_stats`/`compose_chit_rules`)** gains: read `grants_keywords` → union into the chit's `keywords[]`; read `stat_lean` → bias the ATK/HP roll within the tier's existing range.

---

## 7. Family Signature Mechanics (from MTG's "set mechanic per color") — thematic, structure TBD

**Thematic, not structural.** MTG gives each color a recurring mechanic unique to it in a given set (on top of universal evergreen keywords) — it's what makes red *feel* different from white beyond "red does more damage." The equivalent here: give a few families **one recurring named mechanic** that's theirs alone, layered on top of the shared keyword grammar. Illustrative, not exhaustive — pick a few, or none, and decide the exact mechanism yourselves:

- **Musician — "Encore":** an on-summon effect that repeats once more at the start of the player's next turn (a delayed re-trigger). Real engineering lift: needs a small piece of per-chit state to track "fires again next turn."
- **Business — "Leverage":** an effect that reduces the Aura cost of the *next* card played this turn. Low engineering cost (a temporary cost-modifier flag), thematically clean (business = capital efficiency), and does **not** add a new resource — it just discounts Aura.
- **Gamer — "Combo":** effect magnitude scales with how many Gamer-family chits have been played this turn. Bigger lift — needs a per-turn counter tracked by family.
- **Actor — "Understudy" (extend the existing one):** could grow into "copy another ally's on-summon effect" — a real stretch goal (references another creature's `effect_template_id` at resolution time), flag as advanced.

**Caution carried over from §0:** none of these should grow into a *third persistent currency* alongside Aura/Vibe. "Leverage" discounts Aura; it doesn't create a new pool. If "Combo" or "Encore" need per-chit or per-turn state, that's fine (it's bookkeeping, not a resource) — just keep it that way deliberately.

---

## 8. What NOT to import (explicit, tied to decisions already locked)

| MTG/D&D idea | Why it's excluded |
|---|---|
| D&D ability scores / saving throws | Player-level stat system — directly contradicts "no class edges, the chits decide the match" |
| MTG colored mana (multi-resource costs) | You deliberately run one Aura curve + a symmetric Vibe gate — don't reintroduce resource-color identity via cost |
| Renaming `timing_type` to D&D terms | Naming-only; live enum churn isn't worth it — doc-comment mapping only, if desired |
| `min_tier_band` retroactively upgrading a chit's template on ascension | Would break the locked "template fixed at mint, only magnitude scales" rule |

---

## 9. Worked example — Athlete, expanded to 5 templates

Applying every mechanism above to one family, so the pattern is concrete before generating the other nine.

| Key / Name | Timing | Effect | Target | Base mag. | `grants_keywords` | `complexity` | `min_tier_band` | `stat_lean` | `cycle_key` | `family_signature` |
|---|---|---|---|---|---|---|---|---|---|---|
| athlete_on_summon_rush · Adrenaline Rush *(existing — unchanged)* | on_summon | buff_atk | self | 2 | — | 1 | — | aggressive | — | false |
| athlete_on_summon_highlight · Highlight Reel | on_summon | direct_damage | enemy_target | 2 | `charge` | 1 | — | aggressive | single_target_burst | false |
| athlete_activated_secondwind · Second Wind | activated | heal | self | 2 | — | 1 | — | balanced | second_wind | false |
| athlete_on_summon_captain · Team Captain | on_summon | buff_atk_hp + taunt_grant (self) | all_allies + self | 2 | `taunt` | **2** | **C** | balanced | — | **true** |
| athlete_counter_clutch · Clutch Moment | counter (when_attacked) | shield_grant + direct_damage (retaliate) | self + attacker | 3 | `shield` | **2** | **A** | aggressive | clutch_counter | false |

This gives Athlete: a burst option (Charge-enabled, cycle member), a sustain option (uses a previously-unused kind, `heal`), a compound leadership card gated to C+ (the family's signature mechanic), and a rare A+ compound counter — while fixing the "1 counter total across all families" lopsidedness by giving Athlete one too. Every mechanism in this doc is present at least once in this single family; replicate the process for the other nine using §1 as the guardrail and §2's cycles as the horizontal check.

---

## 10. Open questions left to your judgment

- Exact assignment of the 7 previously-unused effect kinds beyond what §1 proposes — the matrix is a starting point, not gospel.
- Whether to adopt `Recharge` as a keyword now or defer it.
- Which families (if any) get a signature mechanic (§7) at launch vs. fast-follow — "Leverage" (Business) is the cheapest to build; "Combo" (Gamer) and extended "Understudy" (Actor) are real lifts.
- Exact `stat_lean` bias formula (how far toward the range edge "aggressive"/"defensive" actually pushes).
- Naming conventions for new template keys/flavor text — kept consistent with the existing `family_effecttype_name` pattern above, but the actual names are yours.

---

## 11. Recommended sequencing (answering the open question from the last session)

Use this framework as the **generative rule-set**, not a replacement for your judgment: run the same process as §9 for the remaining 9 families (matrix → cycle-check → keyword/complexity/lean assignment), and bring the full proposed table back for balance approval — exactly the order you proposed ("draft an expanded set for review first, since these are your numbers to own"), except now there's a structural framework generating the draft instead of ad hoc authoring, so the result should come out consistent across families on the first pass. Wire the Step 1 query changes (§6) at the same time — they're small and don't need to wait for the full library to be approved.
