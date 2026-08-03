# Marketing pipeline (Standard Playset spec — Phase S3)

Generation scripts + the human gate that stands between a render and a post.
Backend: migration 183 (`marketing_spots`, `marketing_generations`, budget cap).

---

# ⚑ WHERE THE PROMO STANDS — "Mint Your Moment", draft 4b (2026-08-03)

**Read this first if you are picking the promo back up.** Detail lives in
[`SHOTS.md`](SHOTS.md) (the running order, how to reorder it) and
[`shotlog.md`](shotlog.md) (every source, seed, request id, finding and QC line).

## Watch it

Public, no login — `battle-media` is a public bucket, so these links are effectively
distribution. Hard-refresh if you opened an earlier draft; the filenames don't change.

- 9:16 · 29.27s · −15.1 LUFS —
  `https://cceisywxwhgljdpisjrl.supabase.co/storage/v1/object/public/battle-media/marketing/promo-mint-your-moment/promo_mint_your_moment_9x16.mp4`
- 16:9 · 28.93s · −15.6 LUFS —
  `https://cceisywxwhgljdpisjrl.supabase.co/storage/v1/object/public/battle-media/marketing/promo-mint-your-moment/promo_mint_your_moment_16x9.mp4`

## What draft 4 did

1. **The cold open is a new, authored shot.** Draft 3 opened on 2.27s of raw Unity
   capture of a card being thrown (soft 3D, dev menu, `@handle` placeholder). Founder
   call: make the *rendered battle street* the opener and let its style and quality
   reinvent the throw. So the throw is generated now, in that street's look, at **9.7s
   instead of 2.27s** — hold → hurl → tumble → **freeze** → detonation.
2. **The freeze converts into the cutscene.** The opener's last frame is conditioned on
   the **house agnostic end plate** (Hard Rule 39) — the same impact flash every minted
   cutscene is bracketed by — so the white cut into the card's own cutscene is a
   continuation of the burst, not an edit.
3. **New running order**, per the founder: open → cutscene → card + finished art → mint
   wizard → Vault → trade → profile → end card. **The arena-lobby beat was dropped** (the
   cold open now *is* the arena).
4. **Product beats rebuilt to ad quality** via [`cine.sh`](cine.sh): each is a lit panel
   on a stage — accent wash, bloom halo off the UI's own neon, floor reflection, specular
   sweep, dolly, grain. All pure ffmpeg; **no UI ever goes through a generative model**.
5. **4b: the hero card was swapped** to "Who's Gonna Carry The Boats" (chit `7d7457d2`,
   NORA-0228, A-Tier athlete), replacing "You're Fired".

## Rebuild

```
SRC=<workdir> bash tools/marketing/build_promo.sh        # 9:16, ~8 min
SRC=<workdir> bash tools/marketing/build_promo_16x9.sh   # 16:9, ~11 min
```

`SRC` needs `renders/opener_{9x16,16x9}.mp4`, `renders/i2v_vault.mp4`, `cuts/boats.mp4`,
`src/boats_art.png`. **All of it is parked in `battle-media`** under
`marketing/promo-mint-your-moment/` (`opener/`, `renders/`) and
`moments/552c6b30-…/` — a render is bought once, ever. Never re-buy to rebuild.

Swapping the hero card again = the four `HERO_*` lines at the top of both build scripts,
plus [`make_card_face.sh`](make_card_face.sh) if the new card has no detail screenshot in
`assets/`.

## ⚠ OPEN — decisions and unfinished business

- [ ] **Nothing is published.** `marketing_spot_publish` refuses without an approved
      render carrying a named human `reviewed_by`. That gate is schema, not process.
- [ ] **Founder decision — the trade beat.** The hero card is a *platform seed* card
      (`is_generic`, `seed_source='platform'`), and Hard Rules 41/43 mean a generic card
      can never be listed, traded or ascended. So shot 6 plays the real Sell/Ascension
      rail on a **neutral stage**, not on the hero card's art — staging it on that art
      would advertise something the product refuses for that exact card. To make the hero
      card the trade example too, re-mint that moment through the normal consent path
      instead of the operator seed lane, then rebuild shot 6 on its art.
- [ ] **Segmind spend unconfirmed** — 8 images + 3 video renders this draft. There is no
      balance endpoint; check the dashboard.
- [ ] **Possible mint-path bug, found here, NOT fixed** — `_shared/segmind.ts` sends
      `image_urls` + `width`/`height` to seedream-4, which wants `image_input` +
      `size`/`aspect_ratio`. Unknown params are accepted and silently discarded, so the
      reference image may be being dropped on the mint path too — meaning card art would
      never see its post thumbnail. Marketing worked around it on its own side (founder
      call 2026-08-02: the dependency runs one way). Worth checking properly.
- [ ] The Vault beat still rides the draft-2 I2V render; a fresh one would match the new
      opener's fidelity, but it is 2.8s behind a caption and didn't justify the spend.

---

## The loop

```
deno run --allow-net --allow-env tools/marketing/generate_spot.ts                 # list the slate
… --render=transformation-hero                                                    # sim render (free)
CINEMATIC_MODE=live SEGMIND_API_KEY=… … --render=transformation-hero --confirm-spend
… --approve=<generation-id> --reviewer="Name"     # or --reject=… --note="why"
… --publish=transformation-hero                    # refuses without an approved render
```

`SUPABASE_URL` + `SERVICE_KEY` (service role) on every call.

## Human review is a gate, not a habit

`marketing_spot_publish` RAISEs unless the spot has a render with
`status='approved'` **and** a named `reviewed_by`. There is no auto-approve path and
no way to publish around it. Per the spec's §0.5 finding, slop does not merely
underperform — it suppresses sharing, so an unreviewed asset is worse than no asset.

**Reviewer checklist** (answer all five *before* `--approve`):

1. **Craft.** Does it read as authored — house cel-shaded identity, deliberate timing —
   or as generic AI stock? If you hesitate, reject.
2. **G-IP.** Any real, identifiable person? Any third-party character, logo, game
   footage, or recognisable existing video? → cut, or route through the `lkn_*`
   licensing rail. Lane A means original characters and settings, always.
3. **Minor safety.** Absolute. Any ambiguity → reject, do not "fix in the edit".
4. **Claims.** No promise of value, appreciation, resale, or income. (The DB blocks the
   obvious words in spot copy; it cannot police what a voiceover implies — you can.)
5. **Truth.** Everything shown is something the product actually does today.

**Owner:** name one person and keep it in `reviewed_by`. [FOUNDER] — spec §4 Q13.

## Budget

`marketing_budget_config.cap_cents` starts at **0**: no live spend is authorised until
[FOUNDER] raises it. `marketing_generation_record` refuses the render that would breach
the cap, so the guard sits in front of the money, not in a report afterwards.

Per-render estimates live in `COST_CENTS` in `generate_spot.ts` (fast 25¢ / standard
120¢ — placeholders). Calibrate them from the `tools/cinematic/trial_*.ts` micro-trials
before committing to a slate size (spec §4 Q12).

## Channel plan (spec §S3)

| Channel | Role |
|---|---|
| TikTok · IG Reels · YT Shorts | primary tri-post, same 9:16 asset |
| X | clips + card-art stills (collector audience) |
| Facebook Reels | older collector demo |
| Discord | community home — organic, not ads; table stakes for a card game |
| Reddit | earnest dev-log posts in gaming/TCG subs; ads read as slop there |
| Twitch | post-launch: creator battles with their own minted cards |

## Scheduled beats

- **`gamer-drop-nov19`** — prepped now, posts **2026-11-19** (GTA VI launch window).
  Original open-world-chaos register only: original city, original characters, no
  third-party game footage or branding, ever.
- **`founding-cohort`** — built from the Founding Market Makers' own mint reveals
  (Phase S4.2). Their clips, their audiences; the platform only assembles.

## What this pipeline is not

It does not post anything. Publishing marks state and hands you the asset URL; a
human posts it to the channel. That is deliberate — the last step before an audience
sees something stays a person's decision.
