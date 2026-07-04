# Vendored: ffmpeg.wasm (single-threaded UMD build)

Used by the BattleChit minting trimmer (`web/js/nora_trim.js`) to cut/normalize the
user's camera-roll clip in the browser before upload (Minting_Workflow.md §1B).

| File | Package | Version | License |
|---|---|---|---|
| `ffmpeg.js`, `814.ffmpeg.js` | `@ffmpeg/ffmpeg` | 0.12.15 | MIT |
| `core/ffmpeg-core.js`, `core/ffmpeg-core.wasm` | `@ffmpeg/core` | 0.12.10 | GPL-2.0-or-later (FFmpeg build incl. libx264) |

Unmodified redistribution of the published npm artifacts. Source:
- https://github.com/ffmpegwasm/ffmpeg.wasm (wrapper + core build scripts)
- https://ffmpeg.org / https://www.videolan.org/developers/x264.html

The single-threaded core is used deliberately: it needs no SharedArrayBuffer, so the
site does not have to ship COOP/COEP headers. Do not swap in `core-mt` without
auditing every cross-origin resource the app loads.

To upgrade: download the new npm tarballs, copy `dist/umd/*` (not `esm`), update this
table and the version pin note in `nora_trim.js` if the API changed.
