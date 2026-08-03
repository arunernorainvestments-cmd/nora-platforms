#!/usr/bin/env bash
# cine.sh — the "marketing ad" treatment for the product beats. Sourced by
# build_promo.sh and build_promo_16x9.sh so the two masters cannot drift apart.
#
# Draft 3 shot its UI beats as crop + slow zoom on a flat screenshot, with a blurred
# copy of that same screenshot filling the dead space. Legible, and completely inert —
# cut against a rendered anime street it read as a slide deck. The draft 4 note was to
# bring those beats up to ad quality.
#
# So a UI beat is no longer a screenshot shown full-bleed. It is a PANEL ON A STAGE:
#
#   stage       an animated radial wash in the beat's accent hue over #0A0A0F, drifting
#   glow        the panel's own highlights, blurred wide and screened in behind it, so
#               the neon inside the UI actually throws light onto the set
#   reflection  a fading vertical flip on the floor beneath the panel
#   sweep       a soft specular band travelling across it (the product-shot move)
#   dolly       a continuous push, rate-matched to the live-action beats either side
#   grain       a light noise floor over everything, so flat UI vector art and generated
#               footage sit in the same film
#
# All of it is pure ffmpeg. The QC gate (§7) forbids passing a UI screenshot through a
# generative model — a hallucinated button in a product ad is a lie about the product —
# so the polish has to come from compositing, and every bit of it does.
#
# Callers must set: W H FPS FONT O (out dir), and CAPY CAPSIZE for captions.

# The specular band, rendered once and then flown across frame. geq would evaluate this
# per pixel per frame; a pre-rendered band plus an overlay expression is the identical
# picture for a fraction of the time.
cine_sweep_png() {
  local out="$1" h="$2"
  [ -f "$out" ] && return 0
  ffmpeg -v error -f lavfi -i "color=c=black:s=900x${h}" \
    -vf "format=gray,geq=lum='250*exp(-pow((X-450)/95\,2))'" -frames:v 1 -y "$out"
}

# Captions fade up and out inside their own shot — a caption that pops is the clunkiest
# thing in a short edit. $1 = text, $2 = shot duration.
cine_cap() {
  local d="$2"
  local al="if(lt(t\,0.35)\,t/0.35\,if(gt(t\,${d}-0.45)\,max(0\,(${d}-t)/0.45)\,1))"
  echo "drawtext=fontfile=$FONT:text='$1':fontcolor=white:fontsize=$CAPSIZE:x=(w-tw)/2:y=$CAPY:\
box=1:boxcolor=0x0A0A0F@0.58:boxborderw=24:shadowcolor=black@0.7:shadowx=2:shadowy=2:alpha='$al'"
}

# ── one product beat ──────────────────────────────────────────────────────────────
#
#   cine_ui <out.mp4> <source> <crop|-> <src_w> <src_h> <panel_w> <accent> <dur> \
#           <caption|-> <sweep|nosweep> [extra_panel_filters]
#
# src_w/src_h are the dimensions AFTER the crop, passed in rather than probed: the panel
# height has to be known in bash to place the reflection and the halo, and overlay
# expressions cannot see another input's height.
cine_ui() {
  local out="$1" src="$2" crop="$3" sw="$4" sh="$5" pw="$6" accent="$7"
  local dur="$8" cap="$9" sweep="${10:-nosweep}" extra="${11:-}"

  local sweeppng="$O/sweep_${H}.png"
  cine_sweep_png "$sweeppng" "$H"

  # Panel height, forced even (libx264 hates odd dimensions), and the panel centred
  # above frame-centre so the caption never lands on it and the reflection has floor.
  local ph cy pad=200
  ph=$(python3 -c "print(int(round($pw*$sh/$sw/2))*2)")
  cy=$(python3 -c "print(int($H*0.42))")
  local ptop=$((cy - ph / 2))
  local rtop=$((cy + ph / 2 + 4))
  local gtop=$((ptop - pad))

  local pre=""
  [ "$crop" != "-" ] && pre="crop=$crop,"
  [ -n "$extra" ] && extra=",$extra"

  # -loop 1 for a still, plain read for a clip: the vault beat is a live render and the
  # rest are captures; both take the same treatment from the next line on.
  local inflag="-loop 1"
  case "$src" in *.mp4) inflag="" ;; esac

  # The sweep is a separate blend rather than an overlay because a specular highlight
  # ADDS light — overlaying it would paste a grey bar across the product. Both blends
  # run in gbrp: blend=screen applied to yuv420p screens the CHROMA planes as well,
  # which is not a highlight, it is a magenta wash over the whole frame.
  local sweepchain="[dol]null[swept];"
  if [ "$sweep" = "sweep" ]; then
    sweepchain="\
[2:v]scale=900:${H},lutyuv=y='val*0.13'[band];\
color=c=black:s=${W}x${H}:d=${dur}:r=${FPS}[sblk];\
[sblk][band]overlay=x='-900+(W+1800)*t/${dur}':y=0:shortest=1,format=gbrp[bandf];\
[dol]format=gbrp[dolr];[dolr][bandf]blend=all_mode=screen,format=yuv420p[swept];"
  fi

  # STAGE_SRC swaps the generated wash for a real image behind the panel. The card beat
  # uses it to stand the card inside its OWN 2048px artwork, which says "this picture
  # became this card" in one frame and needs no caption to do it. STAGE_BLUR keeps that
  # bed readable (12) where the abstract wash wants to be pure atmosphere (70).
  local stagein stagefx blur="${STAGE_BLUR:-70}"
  if [ -n "${STAGE_SRC:-}" ]; then
    stagein=(-loop 1 -t "$dur" -r "$FPS" -i "$STAGE_SRC")
    stagefx="[1:v]scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H},\
zoompan=z='min(1+0.0007*in,1.07)':d=1:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=${W}x${H}:fps=${FPS},\
gblur=sigma=${blur},eq=brightness=-0.20:saturation=1.10,vignette=angle=PI/3.1:mode=forward,format=gbrp[stage];"
  else
    stagein=(-f lavfi -t "$dur" -r "$FPS"
      -i "gradients=s=${W}x${H}:c0=0x0A0A0F:c1=${accent}:c2=0x0A0A0F:n=3:type=radial:speed=0.0016:x0=$((W / 2)):y0=${cy}")
    stagefx="[1:v]gblur=sigma=${blur},eq=brightness=-0.26:saturation=1.05,vignette=angle=PI/3.1:mode=forward,format=gbrp[stage];"
  fi

  ffmpeg -v error $inflag -i "$src" \
    "${stagein[@]}" \
    -loop 1 -i "$sweeppng" \
    -filter_complex "\
[0:v]${pre}scale=${pw}:${ph}:flags=lanczos,unsharp=5:5:0.55,setsar=1${extra}[pnl];\
[pnl]split=3[p1][p2][p3];\
[p2]vflip,crop=iw:ih*0.30:0:0,gblur=sigma=10,format=rgba,\
geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='125*(1-Y/H)'[refl];\
[p3]curves=all='0/0 0.62/0.02 0.86/0.42 1/1',pad=iw+$((pad * 2)):ih+$((pad * 2)):${pad}:${pad}:black,gblur=sigma=58[glw];\
${stagefx}\
color=c=black:s=${W}x${H}:d=${dur}:r=${FPS}[blk];\
[blk][glw]overlay=x=(W-w)/2:y=${gtop}:shortest=1,format=gbrp[glwf];\
[stage][glwf]blend=all_mode=screen:all_opacity=0.85,format=yuv420p[bg];\
[bg][refl]overlay=x=(W-w)/2:y=${rtop}[bg2];\
[bg2][p1]overlay=x=(W-w)/2:y=${ptop}[comp];\
[comp]zoompan=z='min(1+0.0011*in,1.10)':d=1:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=${W}x${H}:fps=${FPS},setsar=1[dol];\
${sweepchain}\
[swept]noise=alls=6:allf=t+u,format=yuv420p$([ "$cap" != "-" ] && echo ",$(cine_cap "$cap" "$dur")")[v]" \
    -map "[v]" -t "$dur" -c:v libx264 -crf 18 -preset medium -y "$out"
}
