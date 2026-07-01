# Claude Code Kickoff Prompt — NORA Platforms (backend), v3 CCG pivot

You are implementing `NORA_PLATFORMS_BUILD_SPEC_v3.md` in the `nora-platforms` repo.

## Read this first
**v3 replaces the v2.x alignment specs and the 1v1 archetype-fighter model entirely.** The game is now a collectible card-battler built on minted "moments." Do not carry over the D&D-stat characters, per-archetype move-sets, or license-per-character battle eligibility — those are deprecated.

1. Read in full: `CLAUDE.md`, `ARCHIVE.md`, `PLAN.md`, `RECONCILIATION.md`, and the spec.
2. **Verify ground truth.** `ls supabase/migrations/` (ledger 066→115). Confirm what exists before changing it; `battle_chits`, `tier_ladder`, `fusion_rules`, the CCG resolver, and the ascension job are all **new**.

## The model in one paragraph
Each player has Life (30); they deck Battle Chits and spend **Aura** (auto-ramp +1/turn to 10, no land cards) to summon chit creatures (ATK+HP only, field cap 3) or cast spell-moments; win at 0 Life. Chits are minted from viral social moments, classified into an archetype **effect-family**, and assigned a **tier (F/E/D/C/B/A/S)** that is **cost-banded** (higher tier = stronger AND costlier). **Fusion** (tag-based, in-battle) combines qualifying chits for an upgraded effect. **Vibe** (shared, symmetric, market-driven) gates premium chits. Prediction markets, licensing (now premium packs), the two-currency model, and the payout split survive — the creator slice now routes to the **moment-owners** of chits played.

## Execute
- Phase by phase, in order (P0→P7). Each phase = one atomic PR with the spec's checklist as the description. Migrations only via `supabase db push`. `flutter analyze` zero issues before/after each PR. Integer USD cents. Append-only ledgers INSERT-only. Honor every **DO NOT**.

## Non-negotiable guardrails
- **Tier cost-banding is the core balance rule:** a higher tier costs more Aura — never strictly-better-for-cost. Tier scales stats AND cost together. This is what stops virality from equalling auto-win.
- **Users never set their own chit's tier/cost/stats** — the tier ladder + classification assign them.
- **Ascension** is **one-directional** (never de-rank), **definition-level** (all copies ascend together), **≤ once / 7 days per user** (API protection), and applies **between matches only** — matches snapshot chit stats at start.
- **Fusion is tag-based** (keys on family/keyword/element), authored as rule-patterns — never per-card recipes (must work for user-minted chits).
- **Combat is server-authoritative** — emit ordered `battle_events`; the client computes nothing.

## The one open product call — DECISION GATE G-MON
A real-money market is created for a match **iff both players are KYC-verified** (default); royalty routes to the moment-owners of played chits; licensed celebrity chits are premium; consent at mint, KYC at cash-out. **Build the gate; confirm the rule with the product owner before real-money go-live.**

## Live-flip prerequisites (Phase 5)
Merge `doc6-mobile-iap-confirm` (mig 115) **and** rotate `NORA_SIGNING_PRIVATE_KEY` on a secure machine before `LKN_PAYMENTS=live`.

## Cross-repo
Mirror the "Cross-repo contract" into `RECONCILIATION.md` (chit catalog + tier, CCG event stream, market gating, minting/ascension, fusion). Note the Arena repo uses a local Unity Editor via `unity-mcp` (no WebGL/headless CI).

Start with **Phase 0**. After each phase report: what changed, checklist status, `flutter analyze` / smoke-test result, any gate hit.
