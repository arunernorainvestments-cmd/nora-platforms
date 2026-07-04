# BattleChit Minting Workflow: Architecture & Handoff

> **Repo status (2026-07-04):** ADOPTED as the governing doc for the minting pipeline's
> generation middle + seam — where it conflicts with `NORA_PLATFORMS_MINTING_MATCHCUT_SPEC.md`
> / `NORA_PLATFORMS_CINEMATIC_ENGINE_SPEC.md`, this doc wins (CLAUDE.md Hard Rules 37/39
> amended accordingly). Naming: "battle_chits" below = **`moment_chits`** in this repo
> (Hard Rule 27). §1 (selector + trimmer + staging upload) is BUILT: `/mint` flow,
> ffmpeg.wasm trim, `mint-staging` bucket, `moment-clip-attach` (migration 146).
> Agnostic plates v1 live at `assets/plates/agnostic_{start,end}_plate_v1_16x9.png`.
> §2–§4 (V2V + bridges + stitch) are the next build track; audio-dub licensing is an
> accepted OPEN issue (ship without resolving; revisit before live).

**Target Audience:** Claude Code (Agent), Frontend/Backend Developers
**Project Context:** NORA Platforms (Web App) — *Minting happens here, NORA Arena (Unity) consumes the output.*

This document outlines the architecture for the "Create Your BattleChit" workflow, allowing users to select social media videos, trim them, and process them through Segmind into seamless, cel-shaded anime match cuts for the game.

---

## 1. Frontend UI: The Media Selector & Trimmer

The user experience lives entirely on the **NORA Platforms** web app.

### A. Social Media Selection
Users tap **"Create Your BattleChit"** and are prompted to link/select media from TikTok, Instagram, or YouTube.

> **API Constraints & The "Download" Problem**
> Native APIs for TikTok, Instagram, and YouTube **strictly prohibit** and block raw video file downloads by third-party servers. 
> *   **TikTok:** No download URL provided. Embed/Share links only.
> *   **YouTube:** No download URL provided. Downloading violates ToS.
> *   **Instagram:** Provides a temporary `media_url`, but storing/processing it is legally restricted without explicit user consent.
> 
> **The Implementation Path (Metrics + Upload):**
> 1. Use the respective APIs (TikTok Display API v2, Instagram Graph API, YouTube Data API v3) to **list the user's videos and thumbnails**.
> 2. The user selects a video. The system stores this video's unique ID so it can continuously poll the API in the future to track its real-world `viewCount`, `likeCount`, etc. (This drives the card's Ascension/Tier bumps).
> 3. Because a raw file cannot be fetched via these APIs, the UI must gracefully prompt the user: *"Awesome! To use this clip, please upload it directly from your device's camera roll."*

### B. The Trimmer UI
Once the raw video file is in the browser, present a simple trimmer:
- **Constraints:** Minimum length: 1 second. Maximum length: 15 seconds.
- **Controls:** A single timeline drag-bar with start/end handles (similar to TikTok's native editor).
- **Audio:** A toggle or slider to select which portion of the original audio is preserved.
- **Output:** The frontend clips the video to the selected range and uploads this trimmed raw MP4 to the Platforms backend (Supabase Storage staging area) to begin processing.

---

## 2. Backend Pipeline: The Segmind Workflow

The backend (Node.js/Edge Functions on NORA Platforms) orchestrates the AI pipeline. Segmind uses **PixelFlow**, which allows you to build multi-node workflows visually and expose them as a single REST API endpoint.

### Phase 0: Content Moderation (Safety Gate)
> **Note:** Because users are uploading raw media from their devices, the workflow must include a moderation step before any heavy AI generation occurs.
1. **Safety Scan:** Pass the trimmed video (or its keyframes) through a Vision/Moderation API (e.g., Google Cloud Video Intelligence, AWS Rekognition, or a Segmind moderation node if available) to check for explicit, violent, or copyrighted material.
2. **Gate:** If the video fails the moderation check, reject the minting request and alert the user. If it passes, proceed to Phase 1.

### Phase 1: Context Generation
1. **Frame Extraction:** Extract the very first frame of the trimmed user video.
2. **Vision LLM Node (Segmind):** Feed the frame into a VLM (like Qwen 3 VL or Llama 3.1 Vision) to generate a descriptive text prompt (e.g., *"A person doing a backflip, confident smile"*).
3. **Style Injection:** Programmatically append the game's art direction to the prompt: `"...rendered in a vibrant cel-shaded anime style, cyberpunk arena background."`

### Phase 2: Video-to-Video Stylization (V2V)
4. **V2V Node (e.g., Wan 2.7 Video Edit):**
   - **Inputs:** Trimmed User Video + Combined Text Prompt.
   - **Output:** The user's motion converted into the anime style. We will call this the **`Core_Clip.mp4`**.

### Phase 3: The Match Cut "Seams" (Agnostic Anchor Plates)
To bridge the 3D Unity game with the `Core_Clip`, we generate two transition videos using a model like **Kling 2.6 Pro** (which supports `image_tail` conditioning). Because custom 3D characters vary, the Start/End Anchor Plates must be **character-agnostic**.

**The Agnostic Strategy:** 
- In Unity, the camera zooms completely into the glowing BattleChit card right before the cutscene starts.
- At the end of the cutscene, Unity plays an "Impact Flash" particle effect as the camera zooms back out.

5. **Intro Bridge (I2V):**
   - `image`: **Agnostic Start Plate** (A high-res, generic 2D render of the glowing BattleChit filling the screen).
   - `image_tail`: Frame 0 of `Core_Clip.mp4`.
   - **Output:** A 1-2 second transition from the glowing card morphing into the anime video. (`Intro.mp4`)

6. **Outro Bridge (I2V):**
   - `image`: Last Frame of `Core_Clip.mp4`.
   - `image_tail`: **Agnostic End Plate** (A generic blue cyber-energy "Impact Flash").
   - **Output:** A 1-2 second transition from the anime video morphing into the impact flash. (`Outro.mp4`)

### Phase 4: Stitching & Audio (FFMPEG)
7. **Concatenation:** A backend FFMPEG worker stitches the sequence:
   `Intro.mp4` + `Core_Clip.mp4` + `Outro.mp4`
8. **Audio Dubbing:** FFMPEG extracts the audio track from the *original* trimmed user video and overlays it specifically onto the `Core_Clip.mp4` segment of the final stitched video.

> **Segmind Workflows vs. FFMPEG**
> While Segmind Workflows can handle Phases 1 through 3 via API calls (`POST https://api.segmind.com/v1/{workflow-id}`), Phase 4 (precise video concatenation and targeted audio dubbing) is best handled by a dedicated FFMPEG microservice or serverless worker on your backend, as Segmind's native stitching utilities are limited.

---

## 3. Finalization & Database Handoff

Once the FFMPEG worker completes the final video:
1. **Upload Asset:** Move the final `.mp4` into the `battle-media` CDN bucket.
2. **Generate Card Art:** Use the Vision LLM (or a standard Segmind Image generation node) to create a static 2D illustration based on the video for the `art_url`.
3. **Database Insert:** Mint the card into the `battle_chits` Supabase table.
   - Set `mp4_cutscene_url` to the CDN link.
   - Set `match_cut_template_id` to the template that matches the Start/End Anchor Plates used in Phase 3.
   - Set `anchor_plate_version` (e.g., "v1.0") to ensure Unity plays it correctly.

Once written to `battle_chits`, the **NORA Arena Unity client** will automatically pull it down via Addressables and play it seamlessly during gameplay!
