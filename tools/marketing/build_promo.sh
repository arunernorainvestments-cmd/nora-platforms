#!/usr/bin/env bash
# build_promo.sh — "Mint Your Moment" promo assembly (PROMPT_promo_video_mint_your_moment.md)
#
# Composites the supplied skeleton assets + Segmind I2V renders + 3x live UI captures
# into the 9:16 primary. Pure ffmpeg: UI never passes through a generative model (§1).
#
#   SRC=<working dir with i2v_*.mp4, shots/*.png, cuts/*.mp4>  bash tools/marketing/build_promo.sh
#
# Draft 2 — the note was "clunky, doesn't flow". Four structural changes:
#   1. shots are XFADED, not butt-joined; every cut carries motion across it
#   2. every shot pushes IN at a similar rate, so the piece has one continuous drift
#   3. captions fade up/out inside their shot instead of popping on and off
#   4. one grade + vignette over the whole cut so ten sources read as one film
set -euo pipefail

SRC="${SRC:?set SRC to the working dir}"
A="tools/marketing/assets"
O="tools/marketing/out"
C="$O/cuts"
mkdir -p "$C"

BG=0x0A0A0F
FONT=/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf
W=1080; H=1920; FPS=30
XF=0.32                       # cross-dissolve length

# Captions sit inside the TikTok safe zone (top 12% / bottom 18% clear) and fade
# up and out within their own shot — a caption that pops is the clunkiest thing
# in a short edit. $1=text $2=shot duration
cap() {
  local d="$2"
  local al="if(lt(t\,0.35)\,t/0.35\,if(gt(t\,${d}-0.4)\,max(0\,(${d}-t)/0.4)\,1))"
  echo "drawtext=fontfile=$FONT:text='$1':fontcolor=white:fontsize=60:x=(w-tw)/2:y=1455:\
box=1:boxcolor=0x0A0A0F@0.60:boxborderw=24:shadowcolor=black@0.7:shadowx=2:shadowy=2:alpha='$al'"
}

# FILL: a 16:9 source in a 9:16 frame leaves 60% of the canvas empty, and dead space
# reads as unfinished. Same frame scaled to COVER, blurred and darkened as a bed, with
# the sharp copy centred on top. $1 = foreground width.
fill() {
  local fw="${1:-1040}"
  echo "split=2[bg][fg];\
[bg]scale=$W:$H:force_original_aspect_ratio=increase,crop=$W:$H,\
gblur=sigma=42,eq=brightness=-0.26:saturation=0.65[bgo];\
[fg]scale=$fw:-2:flags=lanczos[fgo];\
[bgo][fgo]overlay=(W-w)/2:(H-h)/2"
}
FINISH="setsar=1,fps=$FPS,format=yuv420p"

# Continuous slow push on live footage too, so motion never stalls at a cut.
push() { echo "scale=iw*1.06:-2,zoompan=z='min(1+0.0006*in,1.05)':d=1:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=${1}x${2}:fps=$FPS"; }

# ── durations (pre-transition). Tighter than draft 1: ~2.3s average, not 2.6s.
D1=2.2; D2=2.4; D3=2.6; D4=2.6; D5=3.4; D6=2.4; D7=2.4; D8=2.3; D9=2.3; D10=3.2

echo "── shot 1  cold open: the summon burst (full-bleed, original audio)"
ffmpeg -v error -ss 9.55 -i "$A/Chit Throw.mp4" -t $D1 \
  -vf "crop=373:664:434:0,scale=$W:$H:flags=lanczos,unsharp=5:5:0.6,$FINISH" \
  -an -c:v libx264 -crf 18 -preset medium -y "$C/01_burst.mp4"
ffmpeg -v error -ss 9.55 -i "$A/Chit Throw.mp4" -t $D1 -vn \
  -af "volume=1.0,afade=t=out:st=1.9:d=0.3" -ar 48000 -ac 2 -y "$C/a01.wav"

echo "── shot 2  living battle street (I2V) — crop tightened past the @handle placeholder"
ffmpeg -v error -i "$SRC/i2v_street.mp4" -t $D2 \
  -vf "crop=500:430:400:130,$(fill 1080),$FINISH,$(cap 'THIS IS NORA.' $D2)" \
  -an -c:v libx264 -crf 18 -preset medium -y "$C/02_street.mp4"

echo "── shot 3  the mint wizard (real UI, 3x capture)"
ffmpeg -v error -loop 1 -i "$SRC/shots/cap_mint.png" -t $D3 -r $FPS \
  -vf "crop=1500:1010:1170:700,zoompan=z='min(1+0.0012*in,1.10)':d=1:\
x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=1500x1010:fps=$FPS,\
$(fill 1080),$FINISH,$(cap 'Take a post you own…' $D3)" \
  -c:v libx264 -crf 18 -preset medium -y "$C/03_mint.mp4"

echo "── shot 4  the card reveal"
ffmpeg -v error -loop 1 -i "$A/Card View.jpg" -t $D4 -r $FPS \
  -vf "crop=366:552:60:6,zoompan=z='min(1+0.0013*in,1.13)':d=1:\
x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=366x552:fps=$FPS,\
$(fill 940),$FINISH,$(cap 'Mint it into a card.' $D4)" \
  -c:v libx264 -crf 18 -preset medium -y "$C/04_card.mp4"

echo "── shot 5  the card's own cutscene (1280x720 original; in-point moved past the pale frame)"
ffmpeg -v error -ss 1.9 -i "$SRC/cuts/66c370f4.mp4" -t $D5 \
  -vf "$(fill 1080),$FINISH,$(cap 'Every card carries its moment.' $D5)" \
  -an -c:v libx264 -crf 18 -preset medium -y "$C/05_cutscene.mp4"
ffmpeg -v error -ss 1.9 -i "$SRC/cuts/66c370f4.mp4" -t $D5 -vn \
  -af "volume=0.9,afade=t=in:st=0:d=0.3,afade=t=out:st=3.0:d=0.4" -ar 48000 -ac 2 -y "$C/a05.wav"

echo "── shot 6  the vault (I2V)"
ffmpeg -v error -ss 0.3 -i "$SRC/i2v_vault.mp4" -t $D6 \
  -vf "crop=740:470:24:130,$(fill 1080),$FINISH,$(cap 'Build your deck.' $D6)" \
  -an -c:v libx264 -crf 18 -preset medium -y "$C/06_vault.mp4"

echo "── shot 7  the arena lobby (I2V) — right challenge panel cropped OUT (§1 garbled text)"
ffmpeg -v error -ss 0.4 -i "$SRC/i2v_lobby.mp4" -t $D7 \
  -vf "crop=790:580:70:120,$(fill 1080),$FINISH,$(cap 'Play it in the Arena.' $D7)" \
  -an -c:v libx264 -crf 18 -preset medium -y "$C/07_lobby.mp4"

echo "── shot 8  the economy beat"
ffmpeg -v error -loop 1 -i "$A/Card View.jpg" -t $D8 -r $FPS \
  -vf "crop=452:132:16:752,zoompan=z='min(1+0.0009*in,1.08)':d=1:\
x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=452x132:fps=$FPS,\
$(fill 1080),$FINISH,$(cap 'Trade it. Climb the ladder.' $D8)" \
  -c:v libx264 -crf 18 -preset medium -y "$C/08_trade.mp4"

echo "── shot 9  your platforms (real UI, 3x capture)"
ffmpeg -v error -loop 1 -i "$SRC/shots/cap_profile.png" -t $D9 -r $FPS \
  -vf "crop=1960:1120:940:850,zoompan=z='min(1+0.001*in,1.09)':d=1:\
x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=1960x1120:fps=$FPS,\
$(fill 1080),$FINISH,$(cap 'Your platforms. Your moments.' $D9)" \
  -c:v libx264 -crf 18 -preset medium -y "$C/09_profile.mp4"

echo "── shot 10 end card"
ffmpeg -v error -f lavfi -i "color=c=$BG:s=${W}x${H}:d=$D10:r=$FPS" \
  -vf "drawtext=fontfile=$FONT:text='N.O.R.A.':fontcolor=0x6C63FF:fontsize=138:x=(w-tw)/2:y=740:alpha='min(1,t*1.8)',\
drawtext=fontfile=$FONT:text='PLATFORMS':fontcolor=white:fontsize=46:x=(w-tw)/2:y=906:alpha='min(1,max(0,(t-0.3)*1.8))',\
drawtext=fontfile=$FONT:text='MINT YOUR MOMENT':fontcolor=0x03DAC6:fontsize=70:x=(w-tw)/2:y=1080:alpha='min(1,max(0,(t-0.7)*1.8))',\
drawtext=fontfile=$FONT:text='noraplatforms.com':fontcolor=white:fontsize=50:x=(w-tw)/2:y=1196:alpha='min(1,max(0,(t-1.0)*1.8))',\
format=yuv420p" \
  -c:v libx264 -crf 18 -preset medium -y "$C/10_end.mp4"

# ── XFADE chain. offset_i = sum(D_0..D_i-1) - i*XF  (xfade offsets are absolute
#    against the accumulating stream, so each one nets off the previous overlap).
echo "── cross-dissolve chain"
python3 - "$XF" $D1 $D2 $D3 $D4 $D5 $D6 $D7 $D8 $D9 $D10 > "$O/xfade.txt" <<'PY'
import sys
xf=float(sys.argv[1]); ds=[float(x) for x in sys.argv[2:]]
# mostly dissolves so the piece reads as one film; two slides and one white flash
# as accents — the flash sits on card → cutscene, where the card "ignites".
tr=['fade','slideleft','fade','fadewhite','fade','slideleft','fade','slideleft','fade']
acc=ds[0]; parts=[]
for i in range(1,len(ds)):
    off=acc-xf
    parts.append(f"{tr[i-1]}:{off:.3f}")
    acc=off+ds[i]
print(" ".join(parts)); print(f"{acc:.3f}")
PY
CHAIN=$(sed -n 1p "$O/xfade.txt"); TOTAL=$(sed -n 2p "$O/xfade.txt")

FC=""; PREV="[0:v]"; i=1
for spec in $CHAIN; do
  TR="${spec%%:*}"; OFF="${spec##*:}"
  FC="${FC}${PREV}[${i}:v]xfade=transition=${TR}:duration=${XF}:offset=${OFF}[x${i}];"
  PREV="[x${i}]"; i=$((i+1))
done
# One grade + vignette across the whole cut: ten sources, one film.
FC="${FC}${PREV}eq=saturation=1.07:contrast=1.05,colorbalance=bs=0.05:bm=0.02,\
vignette=angle=PI/5:mode=forward,format=yuv420p[vout]"

ffmpeg -v error \
  -i "$C/01_burst.mp4" -i "$C/02_street.mp4" -i "$C/03_mint.mp4" -i "$C/04_card.mp4" \
  -i "$C/05_cutscene.mp4" -i "$C/06_vault.mp4" -i "$C/07_lobby.mp4" -i "$C/08_trade.mp4" \
  -i "$C/09_profile.mp4" -i "$C/10_end.mp4" \
  -filter_complex "$FC" -map "[vout]" \
  -c:v libx264 -crf 18 -preset slow -pix_fmt yuv420p -y "$C/video_only.mp4"

# ── audio: native clip audio at its new offsets + synthesized SFX on the cuts
echo "── audio bed"
python3 - "$XF" $D1 $D2 $D3 $D4 $D5 $D6 $D7 $D8 $D9 $D10 > "$O/offsets.txt" <<'PY'
import sys
xf=float(sys.argv[1]); ds=[float(x) for x in sys.argv[2:]]
acc=0.0; outs=[0.0]
for i in range(1,len(ds)):
    acc=(outs[-1]+ds[i-1])-xf; outs.append(acc)
print(" ".join(f"{o:.3f}" for o in outs))
PY
read -r -a OFF <<< "$(cat "$O/offsets.txt")"
S="$SRC/sfx"
ms() { python3 -c "print(int(float('$1')*1000))"; }

ffmpeg -v error \
 -i "$C/video_only.mp4" -i "$C/a01.wav" -i "$C/a05.wav" \
 -i "$S/whoosh.wav" -i "$S/tick.wav" -i "$S/shimmer.wav" -i "$S/whoosh.wav" \
 -i "$S/whoosh.wav" -i "$S/tick.wav" -i "$S/riser.wav" -i "$S/impact.wav" \
 -filter_complex "\
[1]adelay=0|0,volume=1.0[c1];\
[2]adelay=$(ms ${OFF[4]})|$(ms ${OFF[4]}),volume=1.0[c5];\
[3]adelay=$(ms ${OFF[1]})|$(ms ${OFF[1]}),volume=0.34[s2];\
[4]adelay=$(ms ${OFF[2]})|$(ms ${OFF[2]}),volume=0.42[s3];\
[5]adelay=$(ms ${OFF[3]})|$(ms ${OFF[3]}),volume=0.42[s4];\
[6]adelay=$(ms ${OFF[5]})|$(ms ${OFF[5]}),volume=0.30[s6];\
[7]adelay=$(ms ${OFF[6]})|$(ms ${OFF[6]}),volume=0.30[s7];\
[8]adelay=$(ms ${OFF[8]})|$(ms ${OFF[8]}),volume=0.42[s9];\
[9]adelay=$(ms $(python3 -c "print(${OFF[9]}-1.1)"))|$(ms $(python3 -c "print(${OFF[9]}-1.1)")),volume=0.55[sr];\
[10]adelay=$(ms ${OFF[9]})|$(ms ${OFF[9]}),volume=0.62[se];\
[c1][c5][s2][s3][s4][s6][s7][s9][sr][se]amix=inputs=10:duration=longest:dropout_transition=0,\
loudnorm=I=-16.5:TP=-1.5:LRA=11,alimiter=limit=0.97,apad=whole_dur=30[aout]" \
 -map 0:v -map "[aout]" -shortest \
 -c:v copy -c:a aac -b:a 192k -ar 48000 -movflags +faststart \
 -y "$O/promo_mint_your_moment_9x16.mp4"

echo
ffprobe -v error -show_entries format=duration,size -of default=noprint_wrappers=1 \
  "$O/promo_mint_your_moment_9x16.mp4"
