# Marketing pipeline (Standard Playset spec — Phase S3)

Generation scripts + the human gate that stands between a render and a post.
Backend: migration 183 (`marketing_spots`, `marketing_generations`, budget cap).

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
