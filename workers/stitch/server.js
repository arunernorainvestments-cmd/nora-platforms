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
//   POST /trim    { source: {bucket, path}, start_ms, end_ms, keep_audio,
//                   upload: {bucket, prefix} }
//     -> { ok, clip_path, frame_paths[4] }     (cloud fallback for the browser
//        trimmer: same output contract as web/js/nora_trim.js — clip.mp4 capped
//        at 1280 long edge + f0..f3.jpg moderation frames at the prefix)
//   POST /stitch  {
//     segments: [ { url, start?, duration? }                       // video segment
//               | { image_url, duration, motion? } ],              // animated still
//                    // motion: 'push_in' (default) | 'pull_back' | 'none' — plates
//                    // become live segments via zoompan (bookends, 2026-07-15)
//     transition?: { type?, duration? },          // xfade at every boundary (e.g.
//                    // 'fadewhite' 0.35s); omitted = hard concat (legacy behavior)
//     audio?:   { url, start?, duration?, at },   // overlay source; `at` = secs into output
//     audio_from_segment?: <idx>,                 // use that VIDEO segment's own audio,
//                    // delayed to where the segment starts in the output
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
      'format=duration:stream=codec_type,duration', '-of', 'json', file]);
    let out = '';
    p.stdout.on('data', (d) => (out += d));
    p.on('close', (code) => {
      if (code !== 0) return reject(new Error(`ffprobe exit ${code}`));
      const info = JSON.parse(out);
      const streams = info.streams ?? [];
      const duration = Number(info.format?.duration ?? 0);
      // With co-generated audio (Seedance generate_audio) the audio stream runs a
      // hair longer than the video, so format.duration overshoots the last video
      // frame — seeking there extracts nothing. Track the video stream's own end.
      const vDur = Number(streams.find((s) => s.codec_type === 'video')?.duration);
      resolve({
        duration,
        videoDuration: Number.isFinite(vDur) && vDur > 0 ? Math.min(vDur, duration || vDur) : duration,
        hasAudio: streams.some((s) => s.codec_type === 'audio'),
      });
    });
  });
}

// Private-bucket object fetch with the service key (mint-staging has no public URLs).
async function downloadFromStorage(bucket, objectPath, dest) {
  const res = await fetch(`${SUPABASE_URL}/storage/v1/object/${bucket}/${objectPath}`, {
    headers: { authorization: `Bearer ${SERVICE_KEY}` },
  });
  if (!res.ok) throw new Error(`storage download ${res.status} for ${bucket}/${objectPath}`);
  await fs.writeFile(dest, Buffer.from(await res.arrayBuffer()));
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
    const { videoDuration } = await ffprobe(src);
    // times entries: seconds, 'last', or 'NN%' of the video duration — percentages
    // let callers sample interior content without knowing the final length (a
    // plate-bookended composite is longer than the core the caller rendered).
    const cap = Math.max(0, videoDuration - 0.15);
    const resolved = (Array.isArray(times) ? times : [times]).map((t) => {
      if (t === 'last') return cap;
      if (typeof t === 'string' && t.endsWith('%')) {
        const f = Math.min(100, Math.max(0, Number(t.slice(0, -1)))) / 100;
        return Math.min(f * videoDuration, cap);
      }
      return Math.min(Number(t), cap);
    });
    const frames = [];
    for (let i = 0; i < resolved.length; i++) {
      const out = path.join(dir, `frame_${i}.jpg`);
      // Boundary seeks can still decode nothing at the tail — verify the frame
      // materialized and step back once before giving up.
      let t = resolved[i];
      await ffmpeg(['-ss', String(t), '-i', src, '-frames:v', '1', '-q:v', '2', out]);
      const made = await fs.stat(out).then(() => true, () => false);
      if (!made) {
        t = Math.max(0, t - 0.5);
        await ffmpeg(['-ss', String(t), '-i', src, '-frames:v', '1', '-q:v', '2', out]);
      }
      const objectPath = `${upload.prefix}/frame_${i}.jpg`;
      await uploadToStorage(upload.bucket, objectPath, out, 'image/jpeg');
      frames.push({ time: t, path: `${upload.bucket}/${objectPath}` });
    }
    return { ok: true, frames };
  });
}

// ── /trim ───────────────────────────────────────────────────────────────────
// Cloud fallback for the in-browser ffmpeg.wasm trimmer (it OOMs on some
// device/file combos — real ffmpeg here has no wasm memory wall). Mirrors
// nora_trim.js exactly: frame-accurate cut, H.264/yuv420p normalize, long edge
// capped at 1280, optional audio strip, then the 4 moderation sample frames
// from the TRIMMED output at the same time positions.
async function handleTrim(body) {
  const { source, start_ms, end_ms, keep_audio, upload } = body;
  if (!source?.bucket || !source?.path || !upload?.bucket || !upload?.prefix) {
    throw new Error('source.bucket, source.path, upload.bucket, upload.prefix required');
  }
  const startMs = Math.floor(Number(start_ms));
  const endMs = Math.floor(Number(end_ms));
  if (!(startMs >= 0) || !(endMs - startMs >= 1000) || !(endMs - startMs <= 15000)) {
    throw new Error('trim window must be 1-15 seconds');
  }
  return await withWorkdir(async (dir) => {
    const src = path.join(dir, 'in.bin');
    await downloadFromStorage(source.bucket, source.path, src);

    const startS = startMs / 1000;
    const durS = (endMs - startMs) / 1000;
    const fastSeek = Math.max(0, startS - 2);
    const fineSeek = startS - fastSeek;
    const clip = path.join(dir, 'clip.mp4');
    const args = [
      '-ss', fastSeek.toFixed(3), '-i', src,
      '-ss', fineSeek.toFixed(3), '-t', durS.toFixed(3),
      '-vf', "scale='if(gt(iw,ih),min(1280,iw),-2)':'if(gt(iw,ih),-2,min(1280,ih))'",
      '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23',
      '-pix_fmt', 'yuv420p', '-movflags', '+faststart',
    ];
    if (keep_audio) args.push('-c:a', 'aac', '-b:a', '128k');
    else args.push('-an');
    args.push(clip);
    await ffmpeg(args);

    const framePaths = [];
    for (let i = 0; i < 4; i++) {
      const t = Math.min(durS - 0.05, Math.max(0, (durS * i) / 3 - (i === 3 ? 0.1 : 0)));
      const frame = path.join(dir, `f${i}.jpg`);
      await ffmpeg(['-ss', t.toFixed(3), '-i', clip, '-frames:v', '1', '-q:v', '4', frame]);
      const objectPath = `${upload.prefix}/f${i}.jpg`;
      await uploadToStorage(upload.bucket, objectPath, frame, 'image/jpeg');
      framePaths.push(objectPath);
    }
    const clipPath = `${upload.prefix}/clip.mp4`;
    await uploadToStorage(upload.bucket, clipPath, clip, 'video/mp4');
    return { ok: true, clip_path: clipPath, frame_paths: framePaths };
  });
}

// ── /stitch ─────────────────────────────────────────────────────────────────
// xfade transition names are a fixed ffmpeg vocabulary — validate rather than
// interpolating caller text into the filtergraph.
const XFADE_TYPES = new Set(['fade', 'fadeblack', 'fadewhite', 'dissolve', 'wipeleft',
  'wiperight', 'smoothleft', 'smoothright', 'circleopen', 'circleclose', 'radial']);

async function handleStitch(body) {
  const { segments, audio, upload } = body;
  const width = body.width ?? 1280, height = body.height ?? 720, fps = body.fps ?? 30;
  if (!Array.isArray(segments) || segments.length < 1) throw new Error('segments[] required');
  if (segments.length > 6) throw new Error('too many segments');
  if (!upload?.bucket || !upload?.path) throw new Error('upload.bucket and upload.path required');
  let fade = null;
  if (body.transition) {
    const type = String(body.transition.type ?? 'fade');
    if (!XFADE_TYPES.has(type)) throw new Error(`unknown transition type ${type}`);
    fade = { type, dur: Math.min(1.5, Math.max(0.1, Number(body.transition.duration ?? 0.35))) };
  }

  return await withWorkdir(async (dir) => {
    const inputs = [];
    for (let i = 0; i < segments.length; i++) {
      const seg = segments[i];
      if (seg.image_url) {
        if (!(Number(seg.duration) > 0)) throw new Error(`segments[${i}].duration required with image_url`);
        const f = path.join(dir, `seg_${i}.png`);
        await download(seg.image_url, f);
        inputs.push(f);
      } else {
        const f = path.join(dir, `seg_${i}.mp4`);
        await download(seg.url, f);
        inputs.push(f);
      }
    }
    const audioFile = audio?.url ? path.join(dir, 'audio_src.mp4') : null;
    if (audioFile) await download(audio.url, audioFile);

    // Effective length per segment — needed for xfade offsets AND to bound the
    // audio pad to the final duration (an unbounded apad overflows the filter
    // queue; -shortest alone does not stop the graph).
    const durs = [];
    for (let i = 0; i < segments.length; i++) {
      if (segments[i].image_url) {
        durs.push(Number(segments[i].duration));
        continue;
      }
      const probed = await ffprobe(inputs[i]);
      const start = Number(segments[i].start ?? 0);
      // Bound by the VIDEO stream, not the container: co-generated audio can run
      // past the last frame, and an xfade offset past the video tail stalls the
      // graph the same way the /frames 'last' seek used to.
      const eff = segments[i].duration != null
        ? Number(segments[i].duration)
        : Math.max(0, probed.videoDuration - start);
      durs.push(eff);
    }
    const totalDuration = fade
      ? durs.reduce((a, b) => a + b, 0) - fade.dur * (segments.length - 1)
      : durs.reduce((a, b) => a + b, 0);

    // Normalize every segment (trim -> scale/pad -> fps -> SAR -> pixfmt); still
    // images become live footage via zoompan (2x pre-upscale kills the jitter).
    // setsar=1 is load-bearing: xfade refuses inputs with mismatched SAR, and
    // trimmed phone clips routinely carry a non-square PAR.
    const args = inputs.flatMap((f) => ['-i', f]);
    if (audioFile) args.push('-i', audioFile);

    const norm = (i, seg) => {
      if (seg.image_url) {
        const dur = Number(seg.duration);
        const frames = Math.max(1, Math.round(fps * dur));
        const travel = 0.12;
        const z = seg.motion === 'none' ? '1'
          : seg.motion === 'pull_back'
            ? `${(1 + travel).toFixed(3)}-${travel}*on/${frames}`
            : `1+${travel}*on/${frames}`;
        return `[${i}:v]scale=${width * 2}:${height * 2}:force_original_aspect_ratio=increase,` +
          `crop=${width * 2}:${height * 2},` +
          `zoompan=z='${z}':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=${frames}:s=${width}x${height}:fps=${fps},` +
          `setsar=1,format=yuv420p[v${i}]`;
      }
      const trim = [
        seg.start != null ? `start=${Number(seg.start)}` : null,
        seg.duration != null ? `duration=${Number(seg.duration)}` : null,
      ].filter(Boolean).join(':');
      return `[${i}:v]${trim ? `trim=${trim},` : ''}setpts=PTS-STARTPTS,` +
        `scale=${width}:${height}:force_original_aspect_ratio=decrease,` +
        `pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2,fps=${fps},setsar=1,format=yuv420p[v${i}]`;
    };
    const chains = segments.map((seg, i) => norm(i, seg));
    if (fade && segments.length > 1) {
      let cur = '[v0]';
      let off = 0;
      for (let i = 1; i < segments.length; i++) {
        off += durs[i - 1] - fade.dur;
        const out = i === segments.length - 1 ? '[v]' : `[x${i}]`;
        chains.push(`${cur}[v${i}]xfade=transition=${fade.type}:duration=${fade.dur}:offset=${off.toFixed(3)}${out}`);
        cur = out;
      }
    } else {
      const concatIn = segments.map((_, i) => `[v${i}]`).join('');
      chains.push(`${concatIn}concat=n=${segments.length}:v=1:a=0[v]`);
    }

    // Output start time of segment i (xfade overlaps eat into the timeline).
    const segStart = (i) => durs.slice(0, i).reduce((a, b) => a + b, 0) - (fade ? fade.dur * i : 0);

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
    } else if (Number.isInteger(body.audio_from_segment)) {
      // Keep a segment's own soundtrack (Kling keep_audio / Seedance co-generated
      // audio / an already-final MP4 being re-composed), delayed to where that
      // segment lands in the output timeline. Silently skipped when the segment
      // has no audio stream — audio remains polish, never a failure.
      const aIdx = Number(body.audio_from_segment);
      if (aIdx >= 0 && aIdx < segments.length && !segments[aIdx].image_url) {
        const { hasAudio } = await ffprobe(inputs[aIdx]);
        if (hasAudio) {
          const delayMs = Math.round(Math.max(0, segStart(aIdx)) * 1000);
          const atrim = segments[aIdx].start != null ? `atrim=start=${Number(segments[aIdx].start)},` : '';
          chains.push(`[${aIdx}:a]${atrim}asetpts=PTS-STARTPTS,` +
            `adelay=${delayMs}|${delayMs},apad=whole_dur=${totalDuration.toFixed(3)},` +
            `atrim=duration=${totalDuration.toFixed(3)}[a]`);
          mapAudio = ['-map', '[a]', '-c:a', 'aac', '-b:a', '128k'];
        }
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
    if (req.url === '/trim') return json(res, 200, await handleTrim(body));
    if (req.url === '/stitch') return json(res, 200, await handleStitch(body));
    return json(res, 404, { error: 'not found' });
  } catch (e) {
    console.error(`${req.url} failed:`, e.message);
    return json(res, 500, { error: e.message });
  }
}).listen(PORT, () => console.log(`stitch worker on :${PORT}`));
