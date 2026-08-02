# shotlog — "Mint Your Moment" (draft 1)

Brief: `PROMPT_promo_video_mint_your_moment.md`
Built by: `tools/marketing/build_promo.sh` (pure ffmpeg assembly, reproducible)
Date: 2026-08-02 · Duration **26.57s** · 1080×1920 · −13.2 LUFS integrated

**Deliverable:** `tools/marketing/out/promo_mint_your_moment_9x16.mp4`
**Durable copy:** `battle-media/marketing/promo-mint-your-moment/promo_mint_your_moment_9x16.mp4`

---

## Shots

| # | In–Out | Source | Class | Treatment | Caption |
|---|---|---|---|---|---|
| 1 | 0.0–2.0 | `Chit Throw.mp4` @9.55s | REAL VIDEO | crop 373×664 @x434 → 1080×1920 lanczos + unsharp. Full-bleed. Original audio. | — |
| 2 | 2.0–4.4 | `i2v_street.mp4` | GENERATED (I2V) | crop 820×462 @300,150 → fill. Trimmed at 2.4s, before HUD drift. | THIS IS NORA. |
| 3 | 4.4–7.2 | `cap_mint.png` (3× live capture) | REAL UI | crop 1660×1180 @1090,660 + 1.10× push-in → fill | Take a post you own… |
| 4 | 7.2–9.8 | `Card View.jpg` | REAL UI | crop 366×552 @60,6 + 1.13× push-in → fill(940) | Mint it into a card. |
| 5 | 9.8–13.4 | `66c370f4/cutscene.mp4` (1280×720, battle-media) | REAL VIDEO | @1.2s, 3.6s → fill. Native audio kept, faded. | Every card carries its moment. |
| 6 | 13.4–16.0 | `i2v_vault.mp4` | GENERATED (I2V) | @0.3s, crop 740×470 @24,130 → fill | Build your deck. |
| 7 | 16.0–18.6 | `i2v_lobby.mp4` | GENERATED (I2V) | @0.4s, crop 790×580 @70,120 → fill. **Right challenge panel cropped OUT** (§1 garbled text). | Play it in the Arena. |
| 8 | 18.6–21.0 | `Card View.jpg` | REAL UI | crop 452×132 @16,752 (sell / ascension row) → fill | Trade it. Climb the ladder. |
| 9 | 21.0–23.4 | `cap_profile.png` (3× live capture) | REAL UI | crop 1960×1120 @940,850 → fill | Your platforms. Your moments. |
| 10 | 23.4–26.57 | built in ffmpeg | GENERATED (type) | #0A0A0F, staggered alpha fades, house palette | MINT YOUR MOMENT / noraplatforms.com |

## Generation record (Segmind)

Model `seedance-2.0-fast`, 720p, 5s, `generate_audio:false`, v2 async queue.
Prompts verbatim from brief §3 ("preserve the artwork exactly", no content invention).

| Shot | request_id | seed | source image |
|---|---|---|---|
| street | `90be35ee1ac6a7a33a217e870edf5ae3` | 711661434 | `src/gameplay-format.jpg` |
| vault | `3bf932bdeb36fe92e3129e7c6ef25d66` | 1703996838 | `src/the-vault.jpg` |
| lobby | `7dd98e9ee4bb0cc210c0a15004a790ea` | 278778046 | `src/main-lobby-screen.jpg` |

All three parked at `battle-media/marketing/promo-mint-your-moment/renders/` — never re-buy.

**Spend:** 3 fast-tier I2V renders + 1 accidental `kling-image2video` probe call (empty-body test
that the model accepted; connection timed out at 25s). Segmind gives no balance endpoint —
**confirm actual spend against $36.89 on the dashboard.**

## Audio

**No music** (§5 — founder layers trend audio at post time). Native clip audio on shots 1 and 5.
SFX **synthesized in ffmpeg** (`tools/marketing/out/`-adjacent, from `sine`/`anoisesrc` + envelopes)
— cleared by construction, nothing licensed or ripped. Events: impact @0.06s, whoosh @2.0/13.4/16.0,
tick @4.4/21.0, shimmer @7.2, riser @22.3, impact @23.5. `loudnorm I=-14` then limiter.

## QC gate (§7)

- [x] No UI screenshot through a generative model — shots 3/4/8/9 are ffmpeg crop+zoom only
- [x] Card video not full-screen-scaled from low-res — used the 1280×720 `battle-media` original, not the 386×226 copy
- [x] Lobby's garbled "Daily Challenges" panel cropped out of every framing
- [x] `Who's Gonna Carry The Boats` **excluded** (brief default; no founder approval logged)
- [x] Unfinished character rig excluded (founder call 2026-08-02) — no rig footage in the cut
- [x] No appreciation/investment language — "Trade it" is the ceiling
- [x] No music; clip audio + SFX only; −13.2 LUFS; 26.57s ≤ 35s
- [ ] **Shot 2 still shows a partial `@handle` placeholder at frame right** — needs a tighter crop
- [ ] 16:9 master not yet built
- [ ] Human review + `--approve` not yet run (nothing is published)

## Known issues for draft 2

1. **Shot 2** — `@handle` placeholder clips frame right. Tighten crop to `760×428 @360,170`.
2. **Shot 5** — the in-point at 1.2s lands on a pale transition frame; try @1.9s.
3. **Shot 3** — wizard body copy is legible but small; consider cropping to the step-rail + URL
   field only and letting the caption carry the explanation.
4. **Pacing** — shots average 2.6s. For TikTok, 1.8–2.2s with harder cuts would hold better.
5. **16:9 master** — needs its own framings (sources are natively 16:9, so no `fill` bed).
