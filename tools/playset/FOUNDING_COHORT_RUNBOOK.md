# Founding Market Makers — onboarding runbook

Standard Playset spec **S4.2**. 10–25 mid-size creators, white-gloved through their
first mint **before public launch**, because their reveals *are* the launch campaign:
each mint is a live product demo posted to an audience that is already theirs.

Suggested profile: **50k–500k followers**, clip-native niches (gaming, sports
commentary, comedy). [FOUNDER] selects the list.

## Why this is rank 2 of the whole spec

The playset buys comprehension and retention; it does not spread. Spread comes from
people posting "my moment is a card now" to their own audience. A creator cohort is
that, concentrated — and it is the strongest argument for unlocking Segmind spend
early, because their reveals should be **live renders**, not placeholders.

## Per-creator checklist

1. **Invite + expectations.** One ask, in writing: post your reveal on your own
   channels at launch. Optional second ask: seed one card to the Mystery Pool when
   that gate opens (it is `mode='disabled'` today — do not promise a date).
2. **Account.** They sign up normally at noraplatforms.com. They receive the Standard
   Playset automatically, like everyone.
   - ⚠️ **Never set `is_test_account` on a cohort account.** They are real accounts and
     must appear in discovery (Hard Rule 15). The DB enforces this — a founding Market
     Maker with a test flag is rejected by a CHECK constraint — but do not fight it,
     the constraint is right.
3. **KYC.** Stripe Identity through the normal flow. Required for real-money surfaces
   later; not required to mint or to share.
4. **Social link.** OAuth-link the account whose post they will mint. This is the
   consent leg of Hard Rule 37 — there is no bypass and none is needed: they own the post.
5. **Their mint.** Normal wizard: link post → trim clip → generate → preview → finalize.
   Free. No licence is required for a creator minting **their own** post; Lane-B
   licensing only enters if the platform wants to *feature* their content beyond their
   own posting.
6. **Reveal.** The mint ends on the share sheet (a 9:16 reveal MP4 + caption + their
   referral join link). Confirm the clip renders before they post; if the composer is
   unavailable the sheet still shares link + card art — do not let them post a broken
   asset.
7. **Flag them.**
   ```sql
   SELECT public.set_founding_market_maker('<user-uuid>', TRUE);
   ```
   Service role only. This lights the cosmetic profile badge and adds them to the
   launch-day featured row on `/market`.
8. **Verify.**
   ```sql
   SELECT * FROM public.founding_market_maker_showcase(25);
   ```
   They should appear with their card. If `chit_id` is null, their mint has not
   finalized.

## What the cohort does NOT get

- No card rewards, for joining or for referrals (sybil guard — free card emission tied
  to invites is exactly what the non-tradeable starter set exists to prevent).
- No tier boost, no stat advantage, no ascension privilege. The badge is cosmetic and
  the spec says so; keep it that way or the ladder stops meaning anything.
- No exemption from moderation, at any step.

## Timing

Onboard **before** the public launch date so the featured row and the first wave of
reveals exist on day one. Live renders for this cohort are the highest-value Segmind
spend in the whole plan — [FOUNDER] gate.
