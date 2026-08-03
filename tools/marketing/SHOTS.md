# Shot names — "Mint Your Moment"

Each shot is an independent file. Reordering the film means reordering this list —
the crops, captions and audio all travel with their shot.

**9:16 shots:** `tools/marketing/out/cuts/<name>.mp4`
**16:9 shots:** `tools/marketing/out/cuts16/<name>.mp4`

| # | Name | Length | What's on screen | Caption |
|---|---|---|---|---|
| 1 | `01_burst` | 2.27s | Card hovers at the ramen-shop door in slow motion → white-flash speed snap → scale punch → the summon burst blooms. Original game audio. | *(none — cold open)* |
| 2 | `02_street` | 2.40s | The cyberpunk battle street, alive: rain, neon flicker, drifting steam, wet reflections. | THIS IS NORA. |
| 3 | `03_mint` | 2.60s | The mint wizard, step 1 of 5. A TikTok URL types itself into the field with a blinking caret, then the *Verify my post* button lights. | Take a post you own… |
| 4 | `04_card` | 2.60s | The finished card — art, tier, rules text, "Minted from @…", serial. Slow push-in. | Mint it into a card. |
| 5 | `05_cutscene` | 3.40s | The card's own summon cutscene playing. **This is the audio you liked.** | Every card carries its moment. |
| 6 | `06_vault` | 2.40s | The Vault — five illustrated cards, tier-coloured glows pulsing, deck panel. | Build your deck. |
| 7 | `07_lobby` | 2.40s | The arena lobby, spotlights sweeping, the fighter on the ring. | Play it in the Arena. |
| 8 | `08_trade` | 2.30s | The card's sell row — *Sell for 100 tokens*, *Share this card*, *Open an ascension market*. | Trade it. Climb the ladder. |
| 9 | `09_profile` | 2.30s | Your profile — *Create Your BattleChit*, badges, Market Maker link. | Your platforms. Your moments. |
| 10 | `10_end` | 3.20s | End card: N.O.R.A. PLATFORMS / MINT YOUR MOMENT / noraplatforms.com | *(the card itself)* |

## How to ask for a reorder

Just give me the order by name or number, e.g.
`1, 5, 3, 4, 6, 7, 2, 8, 9, 10` — or "move the cutscene right after the cold open."

Two things move automatically when the order changes:
- **Cross-dissolve offsets** are recomputed from the new running order.
- **Clip audio** (shots 1 and 5) is re-anchored to wherever those shots land.

Two things are worth a thought when reordering:
- **`10_end` should stay last** — it is the only shot with no picture behind it.
- **`01_burst` is built as a cold open** (starts mid-air, no caption). If it moves out of
  first position it will want a caption, and whatever takes first position will want the
  cold-open treatment instead.

## Transitions currently in use

| Between | Type |
|---|---|
| 1 → 2, 3 → 4, 5 → 6, 7 → 8, 9 → 10 | cross-dissolve |
| 2 → 3, 6 → 7, 8 → 9 | slide-left (gives the piece a consistent travel) |
| 4 → 5 | **white flash** — the card ignites into its own moment |

## Audio events

| Time | Sound | Source |
|---|---|---|
| 0.80s | the throw's real audio, from the speed snap | `Chit Throw.mp4` |
| 1.95s | whoosh | synthesized |
| 8.59s | **the cutscene audio you liked** | `66c370f4/cutscene.mp4` |
| 11.67s, 13.75s | whoosh | synthesized |
| 18.69s | riser into the end card | synthesized |
| 19.79s | low hit on the logo | synthesized |

**Removed on your note:** the two 2100 Hz ticks (were at 4.03s and 17.81s) and the
2350/3140 Hz shimmer (was at 6.31s). Those three were the only sine-based sounds in the
mix — the beeps. Everything left is noise-based or real clip audio.
