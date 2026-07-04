# NORA stitch worker

Cloud Run ffmpeg microservice for the minting pipeline (Minting_Workflow.md §4):
concatenates intro-bridge + stylized core + outro-bridge, overlays the ORIGINAL
clip audio under the core segment only, trims 5s Kling bridges to bridge length,
and extracts frames used to condition the bridge generations.

Zero npm dependencies. Auth via `X-Stitch-Secret` header. Results are uploaded
directly to Supabase Storage (never returned as provider URLs).

## Deploy (one command, builds remotely — no local Docker needed)

```bash
gcloud run deploy nora-stitch \
  --source workers/stitch \
  --project <PROJECT_ID> \
  --region us-east1 \
  --allow-unauthenticated \
  --memory 2Gi --cpu 2 --timeout 300 --max-instances 3 --min-instances 0 \
  --set-env-vars SUPABASE_URL=https://cceisywxwhgljdpisjrl.supabase.co \
  --set-secrets STITCH_SECRET=nora-stitch-secret:latest,SUPABASE_SERVICE_ROLE_KEY=nora-supabase-service-key:latest
```

`--allow-unauthenticated` is safe-ish because every request requires the shared
secret; tighten to IAM auth later if desired. Create the two secrets first:

```bash
printf '%s' "$(openssl rand -hex 32)" | gcloud secrets create nora-stitch-secret --data-file=- --project <PROJECT_ID>
printf '%s' "<service role key>"      | gcloud secrets create nora-supabase-service-key --data-file=- --project <PROJECT_ID>
```

Then set the same STITCH_SECRET + the service URL as Supabase edge-function
secrets (`STITCH_WORKER_URL`, `STITCH_SECRET`) so `cinematic-mint` can call it.

## API

`GET /status` → `{ok:true}` (not `/healthz` — Cloud Run reserves that path on
run.app domains and answers 404 itself)

`POST /frames` — extract JPEG frames
```json
{ "video_url": "<signed url>", "times": [0, "last"],
  "upload": { "bucket": "mint-staging", "prefix": "system/<gen-id>" } }
```

`POST /stitch` — normalize (scale/pad/fps), trim, concat, audio overlay
```json
{ "segments": [
    { "url": "<intro url>",  "duration": 1.5 },
    { "url": "<core url>" },
    { "url": "<outro url>", "duration": 1.5 } ],
  "audio": { "url": "<original trimmed clip url>", "at": 1.5 },
  "upload": { "bucket": "battle-media", "path": "chits/<chit-id>/cutscene.mp4" } }
```
`audio.at` = seconds into the output where the original audio starts (the intro
bridge length). Bridges stay silent; audio is padded/cut to video length.
