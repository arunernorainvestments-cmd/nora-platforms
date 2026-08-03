# PROMPT FOR CLAUDE CODE — NORA Platforms Launch Promo Video ("Mint Your Moment")

You are building a social-media promo video for NORA Platforms from supplied assets, using the Segmind API (you are connected) for generative motion and ffmpeg (locally or via the `nora-stitch` Cloud Run worker) for assembly. Read this entire brief before generating anything. Where this brief says VERIFY, check the repo/asset before proceeding.

---

## 0. Mission

One video, ~30 seconds, no voiceover, that tells this arc through motion + on-screen captions:
**hook (battle action) → your real post becomes a playable card → the card fights in the arena → champions & the marketplace → CTA: mint your moment.**

Deliverables:
- `promo_mint_your_moment_9x16.mp4` — 1080×1920, ≤35s, primary (TikTok/Reels/Shorts).
- `promo_mint_your_moment_16x9.mp4` — 1920×1080 master (YouTube/X/site).
- A `shotlog.md` recording per-shot: source asset, Segmind model + seed + prompt (if generated), ffmpeg filters used.

---

## 1. Asset manifest & per-asset handling rules

| Asset | What it is | Class | Handling |
|---|---|---|---|
| `Chit_Throw.mp4` (1182×664, 14.7s, 30fps, has audio) | In-game card-throw action; the transition frames match-cut into card art | REAL VIDEO | Trim to best 2.5–4s action beat(s). Keep original audio for the hook. Center-crop for 9:16. |
| `You_re_Fired.mp4` (386×226, 6.6s, audio) | Minted card cutscene (original anime character) | REAL VIDEO, LOW-RES | **Do not scale full-screen.** See §2 low-res decision tree. HERO CARD for the promo. |
| `Who_s_Gonna_Carry_The_Boats.mp4` (374×228, 8.1s, audio) | Minted card cutscene | REAL VIDEO, LOW-RES, **IP-FLAGGED** | Depicts a recognizable real person / associated catchphrase. **Excluded from the edit by default.** Include ONLY if the founder explicitly approves marketing use (record approval in shotlog). Same low-res rules if approved. |
| `Gameplay_format.jpg` (battle street, cyberpunk, Crowd Vibe bar, cards at bottom) | Illustrated concept art | CONCEPT ART | Segmind I2V allowed (§3). Contains stylized/garbled signage — frame so no garbled text is legible at rest. |
| `Main_Lobby_Screen.jpg` (arena lobby, character, Daily Challenges panel) | Illustrated concept art | CONCEPT ART | Segmind I2V allowed. **Garbled text on the right panel ("Completer match challenge", "Every bony challenge") — crop that panel OUT of every framing.** |
| `The_Vault.jpg` (card collection + Active Deck) | Illustrated concept art | CONCEPT ART | Segmind I2V allowed; keep card-name text small/out of focus (some names garbled). |
| `Nora_Front_Page.jpg`, `Profile.jpg`, `Mint_Flow.jpg`, `BattleChits.jpg`, `Decks.jpg`, `Card_View.jpg` | REAL product UI screenshots | REAL UI | **NEVER pass through any generative model.** ffmpeg `zoompan`/crop/slide only — UI must stay pixel-crisp. This is a hard rule: generative motion warps text, and warped UI reads as fake product. |

**The contrast is intentional:** real UI = crisp and literal; concept art = alive with generated motion. Do not blur that line.

---

## 2. Low-res card-video decision tree (apply in order)
1. **VERIFY** whether higher-resolution originals of the two card cutscenes exist in the `battle-media` bucket (search by chit; these look like downscaled exports). If found, use those.
2. Else, present the cutscene **diegetically**: composite the video INSIDE the card frame of the `Card_View.jpg` UI (the "how this card looks when summoned" panel), occupying ≤45% of frame height. Honest, on-product, and hides the resolution.
3. Only if (1) fails and (2) reads poorly: upscale 2× via a Segmind upscaler node (e.g. ESRGAN-class; VERIFY availability in the connected account), then re-check for upscaler artifacts before use. If artifacts are visible, fall back to (2).

---

## 3. Segmind usage (concept art → living shots)
- Model: an image-to-video node with strong source fidelity (Kling-class I2V or Seedance I2V — VERIFY which are enabled on the account; prefer whatever `tools/cinematic/trial_*.ts` already validated). Draft on the fast/cheap tier; final on standard.
- Per-shot durations 3–5s generated, trimmed to 2–3s in the edit. 16:9 generation for the 16:9 master; crop for 9:16 (generate 9:16 natively only if the model preserves the source composition).
- **Prompt discipline (motion only, zero content invention).** Template:
  - *Battle street:* "Subtle cinematic motion on this exact illustration: steady rainfall, neon signs flicker softly, steam drifts from vents, puddle reflections shimmer, very slow push-in toward the ramen shop. No new objects, no characters moving position, no text changes, preserve the artwork exactly."
  - *Lobby:* "Subtle motion: arena spotlights sweep slowly, crowd silhouettes sway, holographic ring under the character pulses, gentle slow push-in on the character. No new elements, no text changes." (Frame excludes the right-side challenge panel.)
  - *Vault:* "Subtle motion: card frames glow and pulse gently by tier color, faint hex-grid background shimmer, extremely slow lateral drift. No new elements, no text changes."
- Fixed seed per shot, recorded in `shotlog.md`. If a generation warps faces/text/geometry, re-run same seed with a tightened constraint clause — never ship a warped frame.
- **Cost gate:** before finals, report estimated render count × cost from the trial-script pricing and pause for approval if total exceeds prior micro-trial norms.

---

## 4. Shot list (9:16 primary; timings are targets, ±0.5s)

| # | Time | Source | Direction | Caption (overlay) |
|---|---|---|---|---|
| 1 | 0.0–2.5 | `Chit_Throw.mp4` (best throw beat, original audio UP) | Cold open mid-action; cut on the throw's impact frame | — |
| 2 | 2.5–5.0 | Gameplay concept (Segmind I2V) | Living battle street, slow push-in; Crowd Vibe bar visible top | "THIS IS NORA." |
| 3 | 5.0–7.5 | `Nora_Front_Page.jpg` → `Mint_Flow.jpg` (zoompan) | Quick crisp slide to mint step 1; slow zoom onto the URL field | "Take a post you own…" |
| 4 | 7.5–10.5 | `Mint_Flow.jpg` → `Card_View.jpg` (zoompan + a fast light-sweep transition via ffmpeg, not generative) | The reveal: card fills frame; serial + "Minted from @…" row gets a beat of hold | "…and mint it into a BattleChit." |
| 5 | 10.5–14.5 | `You_re_Fired.mp4` per §2 (diegetic in card frame preferred), its audio ducked-up briefly | The card's own cutscene plays | "Every card carries its moment." |
| 6 | 14.5–17.0 | `BattleChits.jpg` grid (lateral zoompan) → `Decks.jpg` or Vault concept (I2V) | Collection breadth → deck building | "Build your deck." |
| 7 | 17.0–20.5 | `Chit_Throw.mp4` second beat (the match-cut into card art) + 1s of Gameplay concept | The throw → card match-cut is the wow mechanic; let it land clean | "Play it in the Arena." |
| 8 | 20.5–24.0 | `Card_View.jpg` bottom ("Sell for 100 tokens" / ascension market row, zoompan) → `Nora_Front_Page.jpg` Arena Champions panel | The economy + status beat | "Trade it. Climb the ladder." |
| 9 | 24.0–27.0 | `Profile.jpg` connect-accounts section (crisp zoompan) | Multi-platform: YouTube/TikTok/IG/Twitch badges visible | "Your platforms. Your moments." |
| 10 | 27.0–30.0 | End card (build in ffmpeg: dark bg #0A0A0F, NORA wordmark, house accents #6C63FF/#03DAC6) | Logo settle + URL | "MINT YOUR MOMENT → noraplatforms.com" |

16:9 master: same sequence, native framings (no crops on UI shots; concept shots generated 16:9).

---

## 5. Audio (NO MUSIC — founder adds music natively at post time)
- **Do not add any music bed or song.** The export ships music-free so trend audio can be layered per-platform at posting.
- **Original clip audio stays:** shots 1 and 7 (`Chit_Throw.mp4`) and shot 5 (the card cutscene) keep their native audio.
- **Sound effects are allowed and encouraged where they coincide with on-screen events** (royalty-free/owned SFX only — VERIFY a cleared SFX source; never rip from commercial media): a whoosh + impact on the shot-1 throw and the shot-7 match-cut, a soft UI tick on the mint-flow zooms, a shimmer/"card materialize" hit on the shot-4 reveal, a subtle riser into the shot-10 end card, and a clean final hit on the logo settle.
- Keep the SFX layer sparse — accents on moments, not a continuous bed. Normalize so clip audio and SFX sit at consistent loudness; leave generous silence between accents (the silence is intentional headroom for the music added later).

## 6. Captions/type
- One type family, white, subtle #03DAC6 accent; ≤5 words per caption; on ≤2 lines; safe-zone insets for TikTok/Reels UI (top 12%, bottom 18% clear).
- Captions are burned in (no VO exists — they carry the narrative).

## 7. QC gate (anti-slop — every item must pass before export)
- [ ] No legible garbled text anywhere in any frame (pause every concept shot and read it).
- [ ] No UI screenshot passed through a generative model; UI text pixel-crisp at 100%.
- [ ] Card videos never full-screen-scaled from the low-res sources.
- [ ] No real person's likeness/catchphrase unless founder approval is logged (`Who_s_Gonna_Carry_The_Boats.mp4` excluded by default).
- [ ] No appreciation/investment language in captions (banned: worth, value goes up, invest, returns — "Trade it" is the ceiling).
- [ ] Both aspect exports play clean start-to-finish; **no music anywhere in the mix** — only clip audio + event SFX at consistent loudness; total ≤35s.
- [ ] `shotlog.md` complete (models, seeds, prompts, trims, approvals).

## 8. Process
Assemble a full **draft** first using fast-tier generations + rough cuts → export a draft 9:16 for human review → apply notes → final-tier renders only for approved shots → final exports. Do not spend final-tier render budget before draft approval.
