#!/usr/bin/env bash
# build_promo.sh — "Mint Your Moment", 9:16 primary master. DRAFT 4.
#
#   SRC=<working dir with renders/, cuts/> bash tools/marketing/build_promo.sh
#
# What changed from draft 3, and why:
#
#   The film now opens on the two-fighter street, and the street's look reinvents the
#   throw instead of the other way round. Draft 3's cold open was 2.27s of raw Unity
#   capture — soft 3D, a dev menu at frame right, an @handle placeholder — and its best
#   frame arrived two shots later, in the rendered street. Founder note: make that the
#   opener, and let its style and quality carry the throw. So the throw is authored now
#   (tools/marketing/generate_opener.ts), and it is given 9.3s instead of 2.27s: hold,
#   throw, tumble, freeze, detonation. An action beat needs room or it reads as a glitch.
#
#   The card FREEZES, the detonation blooms to white, and the film cuts on that white
#   into the card's own cutscene — the opener lands on the house impact plate, which is
#   the exact seam every minted cutscene is bracketed by (Hard Rule 39), so the cut is a
#   continuation rather than an edit.
#
#   Then the product, in the order the founder gave: card + finished art → the mint
#   wizard → the Vault → the trade → the profile → end card. The arena-lobby beat is
#   dropped; the cold open now IS the arena, and re-establishing it two thirds of the
#   way through only slowed the run.
#
#   Every product beat is rebuilt through cine.sh as a lit panel on a stage rather than
#   a screenshot with a blurred copy of itself behind it (see that file's header).
#
# Pure ffmpeg assembly, reproducible. No UI passes through a generative model (§7).
set -euo pipefail

SRC="${SRC:?set SRC to the working dir}"
A="tools/marketing/assets"
O="tools/marketing/out"
C="$O/cuts"
mkdir -p "$C" "$O/sfx"

BG=0x0A0A0F
FONT=/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf
MONO=/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf
W=1080; H=1920; FPS=30
XF=0.32
CAPY=1455; CAPSIZE=60
export W H FPS FONT O CAPY CAPSIZE
# shellcheck source=tools/marketing/cine.sh
source tools/marketing/cine.sh

# The opener carries the film; the product beats are deliberately brisk behind it, so
# the piece front-loads its best footage where the feed decides whether to keep watching.
D1=9.70; D2=3.60; D3=3.60; D4=3.40; D5=2.80; D6=2.60; D7=2.60; D8=3.20

# ── The hero card. The film shows ONE chit: its cutscene (shot 2), its card face
# (shot 3), and its artwork as the stage behind them. Swapping the film's card is
# these four lines plus a matching rebuild of the card face.
#
# 2026-08-03, founder call: "Who's Gonna Carry The Boats" (moment 552c6b30, chit
# 7d7457d2 attempt4, NORA-0228, A-Tier athlete) replaces "You're Fired". That also
# LIFTS the QC-gate exclusion this asset carried since draft 1 — it was held out only
# because no founder approval was on file, and now it is.
HERO_CUT="$SRC/cuts/boats.mp4"
HERO_SS=2.0                       # past the plate flash; out-point lands on the next one
HERO_ART="$SRC/src/boats_art.png"
HERO_FACE="$O/card_face_boats.png"
[ -f "$HERO_FACE" ] || ART="$HERO_ART" bash tools/marketing/make_card_face.sh "$HERO_FACE"

# ── SFX. Synthesized here rather than carried in a scratch directory, so a rebuild on a
# clean machine sounds identical. All noise-based: the founder cut the three sine-based
# cues in draft 3 ("the beeps"), and nothing tonal has been added back.
sfx() { [ -f "$O/sfx/$1" ] || ffmpeg -v error -f lavfi -i "$2" -af "$3" -ar 48000 -ac 2 -y "$O/sfx/$1"; }
sfx whoosh.wav "anoisesrc=c=pink:d=0.75:r=48000" \
  "highpass=f=320,lowpass=f=5200,volume='min(t/0.12,1)*exp(-3.4*max(0,t-0.12))':eval=frame,volume=0.9"
sfx riser.wav  "anoisesrc=c=pink:d=1.30:r=48000" \
  "highpass=f=200,volume='pow(t/1.3,2.2)':eval=frame,volume=0.85"
sfx impact.wav "anoisesrc=c=brown:d=0.90:r=48000" \
  "lowpass=f=190,volume='exp(-5.5*t)':eval=frame,volume=1.0"
# Room tone for the product half, where there is no clip audio to carry the picture.
# Air, not music (§5 — the founder layers trend audio at post time).
sfx air.wav "anoisesrc=c=pink:d=22:r=48000" "lowpass=f=520,highpass=f=90,volume=0.085"

echo "── 1  cold open: the reinvented throw (generated, 9.3s, native audio)"
# The tail ramps to white: the vertical render's detonation peaks but never blows out,
# and the fadewhite into the cutscene has to read as the burst continuing, not a dip.
# The caption arrives LATE — the first six seconds are the action and a caption over
# them would be answering a question nobody has asked yet. It fades in as the card
# freezes and is gone before the detonation.
ffmpeg -v error -t $D1 -i "$SRC/renders/opener_9x16.mp4" \
  -vf "scale=$W:$H:force_original_aspect_ratio=increase,crop=$W:$H,\
unsharp=5:5:0.35,setsar=1,fps=$FPS,\
eq=brightness='if(gt(t\,$(python3 -c "print($D1-0.45)"))\,(t-$(python3 -c "print($D1-0.45)"))/0.45*0.9\,0)':eval=frame,\
format=yuv420p,\
drawtext=fontfile=$FONT:text='THIS IS NORA.':fontcolor=white:fontsize=68:x=(w-tw)/2:y=$CAPY:\
box=1:boxcolor=0x0A0A0F@0.55:boxborderw=26:shadowcolor=black@0.7:shadowx=2:shadowy=2:\
alpha='if(lt(t\,5.0)\,0\,if(lt(t\,5.4)\,(t-5.0)/0.4\,if(gt(t\,7.3)\,max(0\,(7.7-t)/0.4)\,1)))'" \
  -an -c:v libx264 -crf 17 -preset medium -y "$C/01_open.mp4"
ffmpeg -v error -t $D1 -i "$SRC/renders/opener_9x16.mp4" -vn \
  -af "volume=1.0,afade=t=out:st=$(python3 -c "print($D1-0.35)"):d=0.35" -ar 48000 -ac 2 -y "$C/a01.wav"

echo "── 2  the card's own cutscene — the white flash lands here"
ffmpeg -v error -ss $HERO_SS -i "$HERO_CUT" -t $D2 \
  -vf "scale=$W:$H:force_original_aspect_ratio=increase,crop=$W:$H,setsar=1,fps=$FPS,format=yuv420p,\
$(cine_cap 'Every card carries its moment.' $D2)" \
  -an -c:v libx264 -crf 18 -preset medium -y "$C/02_cutscene.mp4"
ffmpeg -v error -ss $HERO_SS -i "$HERO_CUT" -t $D2 -vn \
  -af "volume=0.95,afade=t=in:st=0:d=0.25,afade=t=out:st=$(python3 -c "print($D2-0.4)"):d=0.4" \
  -ar 48000 -ac 2 -y "$C/a02.wav"

echo "── 3  the card, standing inside its own finished art"
STAGE_SRC="$HERO_ART" STAGE_BLUR=12 \
cine_ui "$C/03_card.mp4" "$HERO_FACE" - 732 1090 660 0x5348E0 \
  $D3 'A real moment. A real card.' sweep

echo "── 4  the mint wizard, with the URL typing itself in"
# Typing is drawn in PANEL space (the crop scaled to the panel width), so the field
# coordinates survive any change to how large the panel is staged.
python3 - 540 430 940 > "$O/typing9.filter" <<'PY'
import sys
sw, sh, pw = (float(x) for x in sys.argv[1:4])
k = pw / sw
MONO = '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf'
# Kept short enough that the typed string still FITS the field at a legible size:
# adv*len must stay under FW*k, or the URL runs out past the input's right edge.
url = 'tiktok.com/@yourhandle/video/7421'
# The URL field inside the crop, in source pixels, measured off the capture.
FX, FY, FW, FH = 32, 206, 476, 50
x0, y0 = int((FX + 12) * k), int((FY + 12) * k)
size = max(12, int(FH * k * 0.44)); adv = size * 0.60206
T0, TD = 0.30, 1.45
# A URL is nothing but drawtext metacharacters. ':' separates filter options, so an
# unescaped one silently truncates the argument rather than erroring — draft 4's first
# build typed "https" and then stopped, and looked like a slow animation rather than a
# parse failure. Escape before interpolating, always.
def esc(s):
    return s.replace('\\', '\\\\').replace(':', '\\:').replace("'", "\\'").replace('%', '\\%')
p = [f'drawbox=x={int(FX*k)}:y={int(FY*k)}:w={int(FW*k)}:h={int(FH*k)}:color=0x161A2E:t=fill']
n = len(url)
for i in range(1, n + 1):
    ta, tb = T0 + (i - 1) / n * TD, T0 + i / n * TD
    en = f'between(t\\,{ta:.3f}\\,{tb:.3f})' if i < n else f'gte(t\\,{ta:.3f})'
    p.append(f"drawtext=fontfile={MONO}:text='{esc(url[:i])}':fontcolor=white:fontsize={size}:"
             f"x={x0}:y={y0}:enable='{en}'")
for i in range(n + 1):
    ta = T0 + i / n * TD
    tb = T0 + (i + 1) / n * TD if i < n else 99
    en = (f'between(t\\,{ta:.3f}\\,{tb:.3f})' if i < n
          else f'gte(t\\,{ta:.3f})*lt(mod(t\\,0.86)\\,0.5)')
    p.append(f'drawbox=x={int(x0 + i * adv) + 2}:y={y0}:w=3:h={int(size*1.25)}:'
             f"color=0x03DAC6:t=fill:enable='{en}'")
# the Verify button takes the press once the URL is in
p.append("drawbox=x=%d:y=%d:w=%d:h=%d:color=0x8B84FF@0.34:t=fill:enable='between(t,2.05,2.45)'"
         % (int(30 * k), int(304 * k), int(480 * k), int(34 * k)))
print(','.join(p))
PY
cine_ui "$C/04_mint.mp4" "$A/Mint Flow.jpg" "540:430:120:280" 540 430 940 0x5348E0 \
  $D4 'Take a post you own. Mint it.' nosweep "$(cat "$O/typing9.filter")"

echo "── 5  the Vault (live render — the tier glows are already moving)"
cine_ui "$C/05_vault.mp4" "$SRC/renders/i2v_vault.mp4" "760:345:40:112" 760 345 1010 0x0E6F66 \
  $D5 'Build your deck.' nosweep

echo "── 6  the economy beat"
# Deliberately NOT staged on the hero card's artwork. "Who's Gonna Carry The
# Boats" is a platform seed card (is_generic, seed_source=platform), and Hard
# Rules 41/43 mean a generic card can never be listed, traded or ascended — so
# putting its art behind a Sell/Ascend rail would advertise something the product
# structurally refuses for that card. The rail is true of consent-minted cards,
# which is what the film is selling, so it plays on the neutral stage instead.
cine_ui "$C/06_trade.mp4" "$A/Card View.jpg" "238:68:118:828" 238 68 820 0x0E6F66 \
  $D6 'Trade it. Climb the ladder.' sweep

echo "── 7  your platforms"
cine_ui "$C/07_profile.mp4" "$A/Profile.jpg" "661:300:0:8" 661 300 1000 0x5348E0 \
  $D7 'Your platforms. Your moments.' nosweep

echo "── 8  end card"
ffmpeg -v error -f lavfi -i "color=c=$BG:s=${W}x${H}:d=$D8:r=$FPS" \
  -vf "drawtext=fontfile=$FONT:text='N.O.R.A.':fontcolor=0x6C63FF:fontsize=138:x=(w-tw)/2:y=740:alpha='min(1,t*1.8)',\
drawtext=fontfile=$FONT:text='PLATFORMS':fontcolor=white:fontsize=46:x=(w-tw)/2:y=906:alpha='min(1,max(0,(t-0.3)*1.8))',\
drawtext=fontfile=$FONT:text='MINT YOUR MOMENT':fontcolor=0x03DAC6:fontsize=70:x=(w-tw)/2:y=1080:alpha='min(1,max(0,(t-0.7)*1.8))',\
drawtext=fontfile=$FONT:text='noraplatforms.com':fontcolor=white:fontsize=50:x=(w-tw)/2:y=1196:alpha='min(1,max(0,(t-1.0)*1.8))',\
format=yuv420p" \
  -c:v libx264 -crf 18 -preset medium -y "$C/08_end.mp4"

# ── transitions. offset_i = sum(D_0..D_i-1) - i*XF, because xfade offsets are absolute
#    against the accumulating stream and each one nets off the previous overlap.
echo "── cross-dissolve chain"
python3 - "$XF" $D1 $D2 $D3 $D4 $D5 $D6 $D7 $D8 > "$O/xfade.txt" <<'PY'
import sys
xf = float(sys.argv[1]); ds = [float(x) for x in sys.argv[2:]]
# The white flash is the load-bearing one: the detonation blows out and the card's own
# cutscene is already running underneath. Two slides carry the product half so the run
# has travel; everything else dissolves, so eight sources read as one film.
tr = ['fadewhite', 'fade', 'slideleft', 'fade', 'slideleft', 'fade', 'fade']
acc = ds[0]; parts = []
for i in range(1, len(ds)):
    off = acc - xf
    parts.append(f'{tr[i-1]}:{off:.3f}')
    acc = off + ds[i]
print(' '.join(parts)); print(f'{acc:.3f}')
PY
CHAIN=$(sed -n 1p "$O/xfade.txt"); TOTAL=$(sed -n 2p "$O/xfade.txt")

FC=""; PREV="[0:v]"; i=1
for spec in $CHAIN; do
  TR="${spec%%:*}"; OFF="${spec##*:}"
  FC="${FC}${PREV}[${i}:v]xfade=transition=${TR}:duration=${XF}:offset=${OFF}[x${i}];"
  PREV="[x${i}]"; i=$((i + 1))
done
FC="${FC}${PREV}eq=saturation=1.07:contrast=1.05,colorbalance=bs=0.05:bm=0.02,\
vignette=angle=PI/5:mode=forward,format=yuv420p[vout]"

ffmpeg -v error \
  -i "$C/01_open.mp4" -i "$C/02_cutscene.mp4" -i "$C/03_card.mp4" -i "$C/04_mint.mp4" \
  -i "$C/05_vault.mp4" -i "$C/06_trade.mp4" -i "$C/07_profile.mp4" -i "$C/08_end.mp4" \
  -filter_complex "$FC" -map "[vout]" \
  -c:v libx264 -crf 18 -preset slow -pix_fmt yuv420p -y "$C/video_only.mp4"

# ── audio: the two clips' native tracks at their new offsets, plus room tone and cues
echo "── audio bed"
python3 - "$XF" $D1 $D2 $D3 $D4 $D5 $D6 $D7 $D8 > "$O/offsets.txt" <<'PY'
import sys
xf = float(sys.argv[1]); ds = [float(x) for x in sys.argv[2:]]
outs = [0.0]
for i in range(1, len(ds)):
    outs.append((outs[-1] + ds[i-1]) - xf)
print(' '.join(f'{o:.3f}' for o in outs))
PY
read -r -a OFF <<< "$(cat "$O/offsets.txt")"
S="$O/sfx"
ms() { python3 -c "print(int(float('$1')*1000))"; }

ffmpeg -v error \
 -i "$C/video_only.mp4" -i "$C/a01.wav" -i "$C/a02.wav" -i "$S/air.wav" \
 -i "$S/whoosh.wav" -i "$S/whoosh.wav" -i "$S/whoosh.wav" -i "$S/whoosh.wav" \
 -i "$S/riser.wav" -i "$S/impact.wav" \
 -filter_complex "\
[1]adelay=0|0,volume=1.0[c1];\
[2]adelay=$(ms ${OFF[1]})|$(ms ${OFF[1]}),volume=1.0[c2];\
[3]adelay=$(ms ${OFF[2]})|$(ms ${OFF[2]}),volume=1.0,afade=t=in:st=0:d=1.2[air];\
[4]adelay=$(ms ${OFF[2]})|$(ms ${OFF[2]}),volume=0.30[w1];\
[5]adelay=$(ms ${OFF[3]})|$(ms ${OFF[3]}),volume=0.30[w2];\
[6]adelay=$(ms ${OFF[4]})|$(ms ${OFF[4]}),volume=0.26[w3];\
[7]adelay=$(ms ${OFF[5]})|$(ms ${OFF[5]}),volume=0.26[w4];\
[8]adelay=$(ms $(python3 -c "print(${OFF[7]}-1.15)"))|$(ms $(python3 -c "print(${OFF[7]}-1.15)")),volume=0.55[rs];\
[9]adelay=$(ms ${OFF[7]})|$(ms ${OFF[7]}),volume=0.66[hit];\
[c1][c2][air][w1][w2][w3][w4][rs][hit]amix=inputs=9:duration=longest:dropout_transition=0,\
loudnorm=I=-15:TP=-1.5:LRA=13,alimiter=limit=0.97,apad=whole_dur=40[aout]" \
 -map 0:v -map "[aout]" -shortest \
 -c:v copy -c:a aac -b:a 192k -ar 48000 -movflags +faststart \
 -y "$O/promo_mint_your_moment_9x16.mp4"

echo
ffprobe -v error -show_entries format=duration,size -of default=noprint_wrappers=1 \
  "$O/promo_mint_your_moment_9x16.mp4"
