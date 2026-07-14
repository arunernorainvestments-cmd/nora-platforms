// nora_trim.js — browser-side clip trimming for BattleChit minting (Minting_Workflow.md §1B).
//
// Wraps the vendored ffmpeg.wasm (single-threaded UMD build in /vendor/ffmpeg/) so the
// Flutter app can trim the user's camera-roll clip BEFORE upload: frame-accurate cut,
// normalize to H.264/yuv420p mp4 (handles HEVC iPhone footage), downscale to max 1280
// on the long edge, optional audio strip. Also extracts moderation sample frames and
// filmstrip thumbnails (plain <video> + <canvas>, no ffmpeg).
//
// Single-threaded core on purpose: no SharedArrayBuffer, so no COOP/COEP headers —
// enabling those site-wide would break cross-origin embeds elsewhere in the app.
//
// API (all Promise-based, consumed from Dart via js_interop):
//   noraTrim.load()                                   -> void (idempotent, lazy)
//   noraTrim.probe(objectUrl)                         -> { durationMs, width, height }
//   noraTrim.filmstrip(objectUrl, count, thumbHeight) -> [dataUrl, ...]
//   noraTrim.process(objectUrl, startMs, endMs, keepAudio, onProgress)
//     -> { video: Uint8Array (mp4), frames: [Uint8Array (jpeg) x4] }
(function () {
  'use strict';

  let ffmpeg = null;      // FFmpegWASM.FFmpeg instance, created on first load()
  let loading = null;     // in-flight load() promise (dedupe concurrent callers)
  let busy = false;       // ffmpeg.wasm runs one exec at a time

  function injectScript(src) {
    return new Promise(function (resolve, reject) {
      const s = document.createElement('script');
      s.src = src;
      s.onload = resolve;
      s.onerror = function () { reject(new Error('failed to load ' + src)); };
      document.head.appendChild(s);
    });
  }

  async function load() {
    if (ffmpeg) return;
    if (loading) return loading;
    loading = (async function () {
      if (!window.FFmpegWASM) await injectScript('/vendor/ffmpeg/ffmpeg.js');
      const inst = new window.FFmpegWASM.FFmpeg();
      await inst.load({
        coreURL: new URL('/vendor/ffmpeg/core/ffmpeg-core.js', window.location.origin).href,
        wasmURL: new URL('/vendor/ffmpeg/core/ffmpeg-core.wasm', window.location.origin).href,
      });
      ffmpeg = inst;
    })();
    try { await loading; } finally { loading = null; }
  }

  // Metadata via a detached <video> element — also the "can this browser preview
  // this file at all" gate (rare codecs fail here and the UI reports it cleanly).
  function probe(objectUrl) {
    return new Promise(function (resolve, reject) {
      const v = document.createElement('video');
      v.preload = 'metadata';
      v.muted = true;
      v.src = objectUrl;
      v.onloadedmetadata = function () {
        resolve({
          durationMs: Math.round(v.duration * 1000),
          width: v.videoWidth,
          height: v.videoHeight,
        });
        v.removeAttribute('src');
      };
      v.onerror = function () { reject(new Error('unsupported_video')); };
    });
  }

  function seekFrame(video, canvas, ctx, tSeconds) {
    return new Promise(function (resolve, reject) {
      video.onseeked = function () {
        ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
        resolve(canvas.toDataURL('image/jpeg', 0.7));
      };
      video.onerror = function () { reject(new Error('seek_failed')); };
      video.currentTime = tSeconds;
    });
  }

  async function filmstrip(objectUrl, count, thumbHeight) {
    const video = document.createElement('video');
    video.preload = 'auto';
    video.muted = true;
    video.src = objectUrl;
    await new Promise(function (resolve, reject) {
      video.onloadedmetadata = resolve;
      video.onerror = function () { reject(new Error('unsupported_video')); };
    });
    const h = thumbHeight || 56;
    const w = Math.max(1, Math.round(h * (video.videoWidth / Math.max(1, video.videoHeight))));
    const canvas = document.createElement('canvas');
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext('2d');
    const thumbs = [];
    for (let i = 0; i < count; i++) {
      // small epsilon off the very start/end — t=0 and t=duration often render black
      const t = Math.max(0.1, (video.duration * (i + 0.5)) / count);
      thumbs.push(await seekFrame(video, canvas, ctx, Math.min(t, video.duration - 0.1)));
    }
    video.removeAttribute('src');
    return thumbs;
  }

  // The wasm heap holds the WHOLE source file plus the decode/encode buffers, so big
  // camera-roll / downloaded videos can exhaust it ("memory access out of bounds").
  // Above TWO_PASS_BYTES a stream-copy pre-cut (no decode) shrinks the input and the
  // big source is FREED before the memory-hungry encode pass; -copyts keeps original
  // timestamps so the accurate seek still lands exactly on the user's trim handles.
  const TWO_PASS_BYTES = 80 * 1024 * 1024;
  const MAX_SOURCE_BYTES = 900 * 1024 * 1024;   // beyond this the heap can't even hold the file
  const WASM_CRASH_RE = /memory access out of bounds|table index is out of bounds|unreachable|out of memory|Aborted/i;

  function cleanupFiles(names) {
    if (!ffmpeg) return Promise.resolve();
    return Promise.all(names.map(function (n) {
      return ffmpeg.deleteFile(n).catch(function (_) { /* not created */ });
    }));
  }

  async function process(objectUrl, startMs, endMs, keepAudio, onProgress) {
    await load();
    if (busy) throw new Error('trim_busy');
    busy = true;
    const progressHandler = function (ev) {
      // ffmpeg progress is against the -t duration of the trim exec; clamp for sanity
      if (onProgress) onProgress(Math.max(0, Math.min(1, ev.progress)));
    };
    try {
      const startS = Math.max(0, startMs / 1000);
      const durS = (endMs - startMs) / 1000;

      const srcBuf = await (await fetch(objectUrl)).arrayBuffer();
      if (srcBuf.byteLength > MAX_SOURCE_BYTES) throw new Error('video_too_large');
      await ffmpeg.writeFile('in.bin', new Uint8Array(srcBuf));

      // Defaults = the original single-pass plan: fast input seek to ~2s before the
      // cut, then an accurate output-side seek — frame-accurate without decoding a
      // long source from t=0.
      let input = 'in.bin';
      let fastSeek = Math.max(0, startS - 2);
      let fineSeek = startS - fastSeek;

      if (srcBuf.byteLength > TWO_PASS_BYTES) {
        // Pass 1: keyframe-padded stream copy of just the trim window (no decode,
        // tiny memory), original timestamps preserved via -copyts. Nonzero exit →
        // fall back to the single-pass path (no worse than before).
        const pad = 5;
        const pcode = await ffmpeg.exec([
          '-ss', Math.max(0, startS - pad).toFixed(3), '-i', 'in.bin',
          '-t', (pad + durS + 2).toFixed(3),
          '-c', 'copy', '-copyts', 'pre.mp4',
        ]);
        if (pcode === 0) {
          await ffmpeg.deleteFile('in.bin');   // free the big source BEFORE encoding
          input = 'pre.mp4';
          fastSeek = startS;                   // absolute timestamps survived the copy
          fineSeek = 0;
        }
      }

      ffmpeg.on('progress', progressHandler);
      const args = [
        '-ss', fastSeek.toFixed(3), '-i', input,
        '-ss', fineSeek.toFixed(3), '-t', durS.toFixed(3),
        // long edge capped at 1280 (portrait or landscape), even dims for yuv420p
        '-vf', "scale='if(gt(iw,ih),min(1280,iw),-2)':'if(gt(iw,ih),-2,min(1280,ih))'",
        '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '23',
        '-pix_fmt', 'yuv420p', '-movflags', '+faststart',
      ];
      if (keepAudio) args.push('-c:a', 'aac', '-b:a', '128k');
      else args.push('-an');
      args.push('out.mp4');
      const code = await ffmpeg.exec(args);
      ffmpeg.off('progress', progressHandler);
      if (code !== 0) throw new Error('trim_failed_' + code);
      const video = await ffmpeg.readFile('out.mp4');

      // 4 moderation sample frames from the TRIMMED output (what will be minted)
      const frames = [];
      for (let i = 0; i < 4; i++) {
        const t = Math.min(durS - 0.05, Math.max(0, (durS * i) / 3 - (i === 3 ? 0.1 : 0)));
        const name = 'f' + i + '.jpg';
        const fcode = await ffmpeg.exec([
          '-ss', t.toFixed(3), '-i', 'out.mp4', '-frames:v', '1', '-q:v', '4', name,
        ]);
        if (fcode !== 0) throw new Error('frame_extract_failed_' + fcode);
        frames.push(await ffmpeg.readFile(name));
        await ffmpeg.deleteFile(name);
      }
      await cleanupFiles(['in.bin', 'pre.mp4', 'out.mp4']);
      return { video: video, frames: frames };
    } catch (err) {
      if (WASM_CRASH_RE.test(String(err))) {
        // The wasm heap is corrupt after an OOM — retries would fail instantly.
        // Tear the instance down so the next attempt boots a fresh engine.
        try { ffmpeg && ffmpeg.terminate(); } catch (_) { /* already dead */ }
        ffmpeg = null;
        throw new Error('video_too_large');
      }
      await cleanupFiles(['in.bin', 'pre.mp4', 'out.mp4']);
      throw err;
    } finally {
      busy = false;
      try { ffmpeg && ffmpeg.off('progress', progressHandler); } catch (_) { /* already off */ }
    }
  }

  window.noraTrim = {
    load: load,
    probe: probe,
    filmstrip: filmstrip,
    process: process,
  };
})();
