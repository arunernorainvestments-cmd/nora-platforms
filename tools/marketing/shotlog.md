# shotlog — "Mint Your Moment" (draft 4)

Brief: `PROMPT_promo_video_mint_your_moment.md`
Built by: `tools/marketing/build_promo.sh` + `build_promo_16x9.sh` (pure ffmpeg, reproducible)
Date: 2026-08-03 · **29.27s** 1080×1920 · **28.93s** 1920×1080
Revision: draft 4b — hero card swapped to "Who's Gonna Carry The Boats" (founder call)

**The note was:** open on the two-player shot; use the card-throw animation as
*inspiration* but keep the two-player shot's style and quality dominant, and let that
reinvent the burst; lengthen it so the whole action is cinematic; when the card freezes,
convert into the cutscene; then card + finished art → mint wizard → vault → trade →
profile, all upscaled to marketing-ad quality; profile gets a cinematic pass; end screen.

**Deliverables:**
- `tools/marketing/out/promo_mint_your_moment_9x16.mp4`
- `tools/marketing/out/promo_mint_your_moment_16x9.mp4`
- durable copies at `battle-media/marketing/promo-mint-your-moment/`

---

## Shots

| # | In–Out (9:16) | Source | Class | Treatment | Caption |
|---|---|---|---|---|---|
| 1 | 0.00–9.70 | `opener_9x16.mp4` | **GENERATED (new)** | cover-crop to frame, unsharp, last 0.45s ramped to white. Native audio. | THIS IS NORA. (5.0–7.7s) |
| 2 | 9.38–12.98 | `552c6b30/attempt4/cutscene.mp4` (1280×720) | REAL VIDEO | in-point 2.0s (past the plate flash); out-point lands on the cutscene's OWN next flash. Native audio. | Every card carries its moment. |
| 3 | 12.66–16.26 | `card_face_boats.png` (re-rendered, 2×) + `card_art.png` (2048²) | REAL UI | `cine_ui`, panel 660, **stage = the card's own artwork** (blur 12), sweep | A real moment. A real card. |
| 4 | 15.94–19.34 | `Mint Flow.jpg` | REAL UI | `cine_ui`, panel 940, URL typed in panel space + Verify press | Take a post you own. Mint it. |
| 5 | 19.02–21.82 | `i2v_vault.mp4` | GENERATED (I2V, draft 2) | `cine_ui`, panel 1010, crop to 3 cards (5 in 16:9) | Build your deck. |
| 6 | 21.50–24.10 | `Card View.jpg` | REAL UI | `cine_ui`, panel 820, **neutral stage** (see the seed-card note), sweep | Trade it. Climb the ladder. |
| 7 | 23.78–26.38 | `Profile.jpg` | REAL UI | `cine_ui`, panel 1000 | Your platforms. Your moments. |
| 8 | 26.06–29.27 | built in ffmpeg | GENERATED (type) | #0A0A0F, staggered alpha fades, house palette | MINT YOUR MOMENT / noraplatforms.com |

## The new cold open

Draft 3's `01_burst` was raw Unity footage. Draft 4 authors the same action in the battle
street's own cel-shaded look, at 4× the length, as one continuous 10s Seedance 2.0 render
conditioned on a bookend pair:

- **first frame** — the street standoff, redrawn from `gameplay-clean.jpg` with every HUD
  element removed and the card held coiled at the hip
- **last frame** — the **house agnostic end plate** (`plates/agnostic/v1/end.png`,
  Hard Rule 39) restated in each aspect. Landing the cold open on the product's own
  impact seam is what makes the next cut a continuation instead of an edit.

Prompted as five timed beats (hold / hurl / tumble / **freeze** / detonation), because a
10s render given one sentence spends ten seconds drifting.

## Generation record (Segmind)

Images `seedream-4` (2K), motion `seedance-2.0` 1080p `bitrate_mode=high`, 10s,
`generate_audio` on.

| Artifact | Model | Seed | Request | Conditioned on |
|---|---|---|---|---|
| `9x16_openb.png` | seedream-4 | 806746134 | — | `src/gameplay-clean.jpg` |
| `9x16_closeb.png` | seedream-4 | 3320552 | — | `plates/agnostic/v1/end.png` |
| `16x9_openb.png` | seedream-4 | 1520447 | — | `src/gameplay-clean.jpg` |
| `16x9_closeb.png` | seedream-4 | 806746135 | — | `plates/agnostic/v1/end.png` |
| `opener_16x9.mp4` | seedance-2.0 | 267941123 | `3eb108b8505dfd939d807a49a8fd91e5` | the 16x9 pair |
| `opener_9x16.mp4` | seedance-2.0 | 605596137 | `6129220784c4b8a4960909f60e04b5d1` | the 9x16 pair |

All parked at `battle-media/marketing/promo-mint-your-moment/opener/` — never re-buy.

**Spend this draft:** 8 seedream-4 images (4 kept, 4 rejected on the reviewer checklist —
see below) + 3 seedance-2.0 1080p 10s renders (one of them wasted, see the aspect finding).
Segmind exposes no balance endpoint; **confirm actual spend on the dashboard.**

## Two findings worth keeping

1. **Seedance `aspect_ratio` defaults to 16:9 and does NOT infer from the conditioning
   frames.** The first vertical submit — 1152×2048 first frame, 1152×2048 last frame —
   came back 1920×1080 landscape, a wasted 10s 1080p render. The shared client
   (`_shared/segmind.ts`) never sends the field because the mint path is 16:9 by
   definition, so `generate_opener.ts` posts its own body rather than widening a
   mint-critical function for a marketing need.
2. **`seedream-4` takes `image_input` + `size`/`aspect_ratio`, not `image_urls` +
   `width`/`height`.** With the shared client's spelling the reference image was silently
   ignored (the model invented a different alley and a different rival) and every frame
   came back 2048×2048 square. Same workaround, same reason. **Worth a look on the mint
   path** — if `generateIllustration`'s `referenceImageUrl` is being dropped there too,
   card art is not seeing its post thumbnail.

## Rejected on the reviewer checklist (G-IP)

The first rival design came back as an unmistakable red-and-gold superhero suit — glowing
chest disc, face-shaped mask. Cut, and the cast block rewritten to specify the rival by
what it must *not* have (no chest light, no gold, no mask features, no cape). Faces are
kept hidden throughout for the same reason: a clearly rendered face is a likeness question
the spot does not need to open.

## The hero-card swap (draft 4b)

Founder call: `Who's Gonna Carry The Boats` replaces `You're Fired` as the card the film
follows. Live chit `7d7457d2-3c96-47a9-b326-66bd9d901076` (moment `552c6b30`, attempt 4,
NORA-0228, Tier A, athlete, aura 8). It touches three beats — the cutscene, the card face
and the stage art — and both build scripts now hold the card in four `HERO_*` variables so
the next swap is a one-line edit rather than an archaeology exercise.

**The card face had to be re-rendered.** `assets/Card View.jpg` is a detail screenshot of
*You're Fired* specifically; there is no equivalent capture for this chit and the app can't
be driven headlessly here. `make_card_face.sh` therefore composites the real screenshot's
chrome (at 2×) with the 2048px artwork master and the live `moment_chits` column values,
following the layout rules in `card_face.dart` — family-accent hexagon (athlete `#FF5A1F`),
`_readableOn` letter colour, the type-line and footer formats. It is a re-render of real
data, not an invention, and it comes out **sharper** than the beat it replaces because the
art no longer arrives via a 320px region of a JPEG. If `card_face.dart` changes, that
script is what goes stale.

**One truth problem, handled.** This chit is `is_generic = true, seed_source = 'platform'`
— an operator-seed house card. Hard Rules 41/43 mean a generic card can **never** be
listed, traded, bartered, staked, collected or ascended. Staging the Sell / Ascension rail
on *its* artwork would advertise something the product structurally refuses for that exact
card, which fails QC gate item 5 (truth). The trade beat therefore keeps the real rail — it
is true of consent-minted cards, which is what the film is selling — on the neutral stage,
with no hero art behind it. `You're Fired` had no such problem: it is `is_generic = false`,
minted from a YouTube post, which is why its detail page shows those buttons at all.

**Worth a decision:** if the founder wants the film's hero card to also be its trade
example, the fix is to re-mint this moment through the normal consent path rather than the
operator seed lane, and rebuild shot 6 on its art.

## Audio

**No music** (§5). Native clip audio on shots 1 and 2 — the opener's generated track is
broadband and low-frequency (spectral flatness 0.34, energy at 38–81 Hz): rain, the throw,
the detonation. Nothing tonal, so the beeps cut in draft 3 stay gone. Room tone plus four
whooshes, a riser and one low impact are synthesized in the build script itself, from
`anoisesrc` — so a rebuild on a clean machine sounds identical, instead of depending on a
scratch directory that no longer exists.

## Build bug found and fixed

The mint beat typed `https` and then stopped. It looked like a slow animation; it was a
parse failure — an unescaped `:` in a `drawtext` `text=` **silently truncates the argument
at the first colon** rather than erroring. A URL is nothing but drawtext metacharacters.
Both build scripts now escape `\ : ' %` before interpolating, and cap the typed string's
length so it still fits the field at a legible size.

Also fixed: `blend=all_mode=screen` on `yuv420p` screens the **chroma** planes too, which
is not a highlight — it dragged every product beat toward saturated magenta. Both blends
in `cine.sh` now run in `gbrp`.

## QC gate (§7)

- [x] No UI screenshot through a generative model — shots 3/4/6/7 are ffmpeg compositing only
- [x] Card video not scaled up from a low-res copy — the 1280×720 `battle-media` original
- [x] No dev menu, no `@handle` placeholder, no HUD anywhere (the opener is authored clean)
- [x] `Who's Gonna Carry The Boats` **approved by the founder 2026-08-03** and promoted to hero card — the draft-1 exclusion existed only for want of that approval
- [x] Unfinished character rig excluded (founder call 2026-08-02)
- [x] G-IP: no real people, no third-party characters or branding; rival redesigned (above)
- [x] No appreciation/investment language — "Trade it" is the ceiling
- [x] No music; clip audio + noise SFX only; −15.2 / −15.8 LUFS; 29.3s ≤ 35s
- [ ] **Human review + `--approve` not run; nothing is published**
- [ ] LRA 21 LU is wide by design (loud cold open, quiet product half) — platforms normalise
- [ ] Segmind spend unconfirmed (no balance endpoint)
- [ ] The vault beat still rides the draft-2 I2V render; a fresh one would match the new
      opener's fidelity better, but it is 2.8s behind a caption and did not justify the spend
