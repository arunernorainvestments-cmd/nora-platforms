# Shot names — "Mint Your Moment" (draft 4)

Each shot is an independent file. Reordering the film means reordering this list —
the crops, captions and audio all travel with their shot.

**9:16 shots:** `tools/marketing/out/cuts/<name>.mp4`
**16:9 shots:** `tools/marketing/out/cuts16/<name>.mp4`

| # | Name | Length | What's on screen | Caption |
|---|---|---|---|---|
| 1 | `01_open` | 9.70s / 9.35s | **The cold open.** The rain-soaked ramen street: the teal fighter and the crimson rival face off, the card is drawn and **hurled**, it tumbles across the street, **snaps to a dead stop** frozen mid-air while the rain keeps falling, energy rings gather, and the whole street detonates into white. One continuous generated shot, native clip audio. | THIS IS NORA. *(late, over the freeze)* |
| 2 | `02_cutscene` | 3.60s | **"Who's Gonna Carry The Boats"** — the card's own summon cutscene: the athlete under the bar, fire behind him. Native audio. | Every card carries its moment. |
| 3 | `03_card` | 3.60s | The finished card (NORA-0228, A-Tier athlete) standing inside its own 2048px artwork, specular sweep across the face. | A real moment. A real card. |
| 4 | `04_mint` | 3.40s | The mint wizard, step 1 of 5. A TikTok URL types itself into the field with a blinking caret, then *Verify my post* lights. | Take a post you own. Mint it. |
| 5 | `05_vault` | 2.80s | The Vault — tier-coloured card glows pulsing, the Active Deck panel. | Build your deck. |
| 6 | `06_trade` | 2.60s | The card's action rail — *Sell for 100 tokens*, *Open an ascension market* — lit on the neutral stage (see below). | Trade it. Climb the ladder. |
| 7 | `07_profile` | 2.60s | Your profile — *Create Your BattleChit*, badges. | Your platforms. Your moments. |
| 8 | `08_end` | 3.20s | End card: N.O.R.A. PLATFORMS / MINT YOUR MOMENT / noraplatforms.com | *(the card itself)* |

Total **29.27s** (9:16) · **28.93s** (16:9).

## What draft 4 changed

- **The two-fighter street is now the opener, and its look reinvents the throw.** Draft 3
  opened on 2.27s of raw Unity capture of a card being thrown — soft 3D, a dev menu at
  frame right, an @handle placeholder — while the best-looking frame in the film sat two
  shots later in the rendered battle street. Draft 4 authors the throw *in that street's
  style* (`generate_opener.ts`) and gives the action **9.7s instead of 2.27s**, so it
  plays as a shot rather than a glitch: hold → throw → tumble → **freeze** → detonation.
- **The freeze converts into the cutscene.** The opener resolves onto the house impact
  plate — the same cyber-flash every minted cutscene is bracketed by (Hard Rule 39) — and
  the film cuts through white on it, so the card's own cutscene is a continuation of the
  burst rather than a new shot.
- **The product beats were rebuilt as lit product panels** (`cine.sh`): stage wash, bloom
  halo, floor reflection, specular sweep, dolly, grain. Draft 3 showed them as flat
  screenshots on a blurred copy of themselves.
- **The arena-lobby beat is gone.** The cold open now *is* the arena; re-establishing it
  two thirds of the way in only slowed the run.

## The hero card

The film shows ONE chit across shots 2 and 3, plus its artwork as the stage behind them.
As of 2026-08-03 that is **"Who's Gonna Carry The Boats"** (chit `7d7457d2`, moment
`552c6b30`, attempt 4, NORA-0228, A-Tier athlete), swapped in on the founder's call — which
also lifted the QC-gate exclusion this asset had carried since draft 1.

Swapping it again is four lines at the top of each build script (`HERO_CUT`, `HERO_SS`,
`HERO_ART`, `HERO_FACE`). If the new card has no detail screenshot in `assets/`, rebuild
the face with `make_card_face.sh` first — see that file's header.

**The trade beat deliberately does NOT use the hero card's artwork.** This one is a
platform seed card (`is_generic`, `seed_source='platform'`), and Hard Rules 41/43 mean a
generic card can never be listed, traded or ascended. The Sell/Ascend rail is true of
consent-minted cards — what the film is selling — so it plays on the neutral stage rather
than appearing to advertise a trade the product would refuse.

## How to ask for a reorder

Just give me the order by name or number, e.g.
`1, 3, 2, 4, 5, 6, 7, 8` — or "move the card beat before the cutscene."

Two things move automatically when the order changes:
- **Cross-dissolve offsets** are recomputed from the new running order.
- **Clip audio** (shots 1 and 2) is re-anchored to wherever those shots land.

Two things are worth a thought when reordering:
- **`08_end` should stay last** — it is the only shot with no picture behind it.
- **`01_open` is built as a cold open** (its caption arrives at 5s, not at 0). If it moves
  out of first position it wants an early caption, and whatever takes first position wants
  the cold-open treatment instead.
- **`01_open` → `02_cutscene` is the white flash.** They are a pair; splitting them costs
  the film its best cut.

## Transitions currently in use

| Between | Type |
|---|---|
| 1 → 2 | **white flash** — the detonation blows out and the cutscene is already running under it |
| 2 → 3, 4 → 5, 6 → 7, 7 → 8 | cross-dissolve |
| 3 → 4, 5 → 6 | slide-left (gives the product half a consistent travel) |

## Audio

No music (§5 — trend audio is layered at post time). Two native clip tracks plus a
noise-based bed; nothing tonal, so the three sine cues cut in draft 3 stay gone.

| Time (9:16) | Sound | Source |
|---|---|---|
| 0.00–9.70s | rain, the throw, the detonation | native audio of `opener_9x16.mp4` |
| 9.38–12.98s | the cutscene's own track | native audio of `552c6b30/attempt4/cutscene.mp4` |
| 12.66s → end | room tone, faded in | synthesized (pink noise, low-passed) |
| 12.66 / 15.94 / 19.02 / 21.50s | whoosh on the cut | synthesized |
| 24.91s | riser into the end card | synthesized |
| 26.06s | low impact on the logo | synthesized |
