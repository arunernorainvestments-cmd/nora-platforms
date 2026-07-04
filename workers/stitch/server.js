// NORA stitch worker — Cloud Run ffmpeg service for the minting pipeline (§4).
//
// Does the video ops Segmind can't: concatenate intro-bridge + core + outro-bridge,
// lay the ORIGINAL clip audio under the core segment only (bridges stay silent),
// trim the 5s Kling bridges down to bridge length, and extract frames for the
// bridge generations. Zero npm dependencies — Node 20 built-ins + ffmpeg binary.
//
// Auth: every request must carry X-Stitch-Secret matching env STITCH_SECRET.
// Storage: results are uploaded straight to Supabase Storage (service key env),
// so signed provider URLs never leave the backend loop (Hard Rule 38 spirit:
// callers deal only in our storage paths).
//
// Endpoints (JSON in, JSON out):
//   POST /frames  { video_url, times: number[]|"last", upload: {bucket, prefix} }
//     -> { ok, frames: [{time, path}] }        (JPEGs at prefix/frame_<i>.jpg)
//   POST /stitch  {
//     segments: [ { url, start?, duration? } ],   // in order; trims re-encode
//     audio?:   { url, start?, duration?, at },   // overlay source; `at` = secs into output
//     width?, height?, fps?,                      // default 1280x720@30
//     upload: { bucket, path }                    // destination for final MP4
//   } -> { ok, path, duration_s }
//   GET /status -> ok   (NOT /healthz — Cloud Run's frontend reserves that
//                        path on run.app domains and 404s it before the app)

const http = require('node:http');
const { spawn } = require('node:child_process');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');

const PORT = process.env.PORT || 8080;
const STITCH_SECRET = process.env.STITCH_SECRET || '';
const SUPABASE_URL = process.env.SUPABASE_URL || '';
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || '';

function json(res, status, body) {
  const s = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(s) });
  res.end(s);
}

async function readBody(req, limit = 1 << 20) {
  const chunks = [];
  let size = 0;
  for await (const c of req) {
    size += c.length;
    if (size > limit) throw new Error('body too large');
    chunks.push(c);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

async function download(url, dest) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`download ${res.status} for input`);
  await fs.writeFile(dest, Buffer.from(await res.arrayBuffer()));
}

function ffmpeg(args, timeoutMs = 240000) {
  return new Promise((resolve, reject) => {
    const p = spawn('ffmpeg', ['-hide_banner', '-y', ...args]);
    let err = '';
    p.stderr.on('data', (d) => { err += d; if (err.length > 20000) err = err.slice(-20000); });
    const t = setTimeout(() => { p.kill('SIGKILL'); reject(new Error('ffmpeg timeout')); }, timeoutMs);
    p.on('close', (code) => {
      clearTimeout(t);
      code === 0 ? resolve() : reject(new Error(`ffmpeg exit ${code}: ${err.slice(-2000)}`));
    });
  });
}

function ffprobe(file) {
  return new Promise((resolve, reject) => {
    const p = spawn('ffprobe', ['-v', 'error', '-show_entries',
      'format=duration:stream=codec_type', '-of', 'json', file]);
    let out = '';
    p.stdout.on('data', (d) => (out += d));
    p.on('close', (code) => {
      if (code !== 0) return reject(new Error(`ffprobe exit ${code}`));
      const info = JSON.parse(out);
      resolve({
        duration: Number(info.format?.duration ?? 0),
        hasAudio: (info.streams ?? []).some((s) => s.codec_type === 'audio'),
      });
    });
  });
}

async function uploadToStorage(bucket, objectPath, file, contentType) {
  const bytes = await fs.readFile(file);
  const res = await fetch(`${SUPABASE_URL}/storage/v1/object/${bucket}/${objectPath}`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${SERVICE_KEY}`,
      'content-type': contentType,
      'x-upsert': 'true',
    },
    body: bytes,
  });
  if (!res.ok) throw new Error(`storage upload ${res.status}: ${(await res.text()).slice(0, 300)}`);
}

async function withWorkdir(fn) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'stitch-'));
  try {
    return await fn(dir);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
}

// ── /frames ─────────────────────────────────────────────────────────────────
async function handleFrames(body) {
  const { video_url, times, upload } = body;
  if (!video_url || !upload?.bucket || !upload?.prefix) throw new Error('video_url, upload.bucket, upload.prefix required');
  return await withWorkdir(async (dir) => {
    const src = path.join(dir, 'in.mp4');
    await download(video_url, src);
    const { duration } = await ffprobe(src);
    const resolved = (Array.isArray(times) ? times : [times]).map((t) =>
      t === 'last' ? Math.max(0, duration - 0.05) : Number(t));
    const frames = [];
    for (let i = 0; i < resolved.length; i++) {
      const out = path.join(dir, `frame_${i}.jpg`);
      await ffmpeg(['-ss', String(resolved[i]), '-i', src, '-frames:v', '1', '-q:v', '2', out]);
      const objectPath = `${upload.prefix}/frame_${i}.jpg`;
      await uploadToStorage(upload.bucket, objectPath, out, 'image/jpeg');
      frames.push({ time: resolved[i], path: `${upload.bucket}/${objectPath}` });
    }
    return { ok: true, frames };
  });
}

// ── /stitch ─────────────────────────────────────────────────────────────────
async function handleStitch(body) {
  const { segments, audio, upload } = body;
  const width = body.width ?? 1280, height = body.height ?? 720, fps = body.fps ?? 30;
  if (!Array.isArray(segments) || segments.length < 1) throw new Error('segments[] required');
  if (segments.length > 6) throw new Error('too many segments');
  if (!upload?.bucket || !upload?.path) throw new Error('upload.bucket and upload.path required');

  return await withWorkdir(async (dir) => {
    const inputs = [];
    for (let i = 0; i < segments.length; i++) {
      const f = path.join(dir, `seg_${i}.mp4`);
      await download(segments[i].url, f);
      inputs.push(f);
    }
    const audioFile = audio?.url ? path.join(dir, 'audio_src.mp4') : null;
    if (audioFile) await download(audio.url, audioFile);

    // Probe each segment for its effective length — the audio pad must be
    // bounded to the final duration (an unbounded apad overflows the filter
    // queue; -shortest alone does not stop the graph).
    let totalDuration = 0;
    for (let i = 0; i < segments.length; i++) {
      const probed = await ffprobe(inputs[i]);
      const start = Number(segments[i].start ?? 0);
      const eff = segments[i].duration != null
        ? Number(segments[i].duration)
        : Math.max(0, probed.duration - start);
      totalDuration += eff;
    }

    // Normalize every segment (trim -> scale/pad -> fps -> pixfmt), then concat.
    const args = inputs.flatMap((f) => ['-i', f]);
    if (audioFile) args.push('-i', audioFile);

    const norm = (i, seg) => {
      const trim = [
        seg.start != null ? `start=${Number(seg.start)}` : null,
        seg.duration != null ? `duration=${Number(seg.duration)}` : null,
      ].filter(Boolean).join(':');
      return `[${i}:v]${trim ? `trim=${trim},` : ''}setpts=PTS-STARTPTS,` +
        `scale=${width}:${height}:force_original_aspect_ratio=decrease,` +
        `pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2,fps=${fps},format=yuv420p[v${i}]`;
    };
    const chains = segments.map((seg, i) => norm(i, seg));
    const concatIn = segments.map((_, i) => `[v${i}]`).join('');
    chains.push(`${concatIn}concat=n=${segments.length}:v=1:a=0[v]`);

    let mapAudio = [];
    if (audioFile) {
      const { hasAudio } = await ffprobe(audioFile);
      if (hasAudio) {
        const aIdx = segments.length;
        const atrim = [
          audio.start != null ? `start=${Number(audio.start)}` : null,
          audio.duration != null ? `duration=${Number(audio.duration)}` : null,
        ].filter(Boolean).join(':');
        const delayMs = Math.round(Number(audio.at ?? 0) * 1000);
        chains.push(`[${aIdx}:a]${atrim ? `atrim=${atrim},` : ''}asetpts=PTS-STARTPTS,` +
          `adelay=${delayMs}|${delayMs},apad=whole_dur=${totalDuration.toFixed(3)},` +
          `atrim=duration=${totalDuration.toFixed(3)}[a]`);
        mapAudio = ['-map', '[a]', '-c:a', 'aac', '-b:a', '128k'];
      }
    }

    const out = path.join(dir, 'out.mp4');
    await ffmpeg([
      ...args,
      '-filter_complex', chains.join(';'),
      '-map', '[v]', ...mapAudio,
      '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
      '-movflags', '+faststart',
      '-t', totalDuration.toFixed(3),
      out,
    ]);
    const { duration } = await ffprobe(out);
    await uploadToStorage(upload.bucket, upload.path, out, 'video/mp4');
    return { ok: true, path: `${upload.bucket}/${upload.path}`, duration_s: duration };
  });
}

// ── server ──────────────────────────────────────────────────────────────────
http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/status') return json(res, 200, { ok: true });
  if (req.method !== 'POST') return json(res, 405, { error: 'POST only' });
  if (!STITCH_SECRET || req.headers['x-stitch-secret'] !== STITCH_SECRET) {
    return json(res, 401, { error: 'unauthorized' });
  }
  try {
    const body = await readBody(req);
    if (req.url === '/frames') return json(res, 200, await handleFrames(body));
    if (req.url === '/stitch') return json(res, 200, await handleStitch(body));
    return json(res, 404, { error: 'not found' });
  } catch (e) {
    console.error(`${req.url} failed:`, e.message);
    return json(res, 500, { error: e.message });
  }
}).listen(PORT, () => console.log(`stitch worker on :${PORT}`));
