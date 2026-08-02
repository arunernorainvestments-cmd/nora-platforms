#!/usr/bin/env bash
# build_promo.sh — "Mint Your Moment" promo assembly (PROMPT_promo_video_mint_your_moment.md)
#
# Composites the supplied skeleton assets + Segmind I2V renders + 3x live UI captures
# into the 9:16 primary. Pure ffmpeg: UI never passes through a generative model (§1).
#
#   SRC=<working dir with i2v_*.mp4, shots/*.png, cuts/*.mp4>  bash tools/marketing/build_promo.sh
set -euo pipefail

SRC="${SRC:?set SRC to the working dir}"
A="tools/marketing/assets"
O="tools/marketing/out"
C="$O/cuts"
mkdir -p "$C"

BG=0x0A0A0F
FONT=/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf
W=1080; H=1920; FPS=30

# Captions sit inside the TikTok safe zone: top 12% (230px) and bottom 18% (345px)
# stay clear of type, so the platform UI never covers a word (§6).
cap() {
  echo "drawtext=fontfile=$FONT:text='$1':fontcolor=white:fontsize=60:x=(w-tw)/2:y=1455:\
box=1:boxcolor=0x0A0A0F@0.62:boxborderw=24:shadowcolor=black@0.7:shadowx=2:shadowy=2"
}

# FILL: a 16:9 source in a 9:16 frame leaves 60% of the canvas empty, and dead space
# reads as unfinished. So the same frame is scaled to COVER, blurred and darkened as a
# bed, with the sharp copy centred on top — the frame is always full, focus stays
# centre, and the blur doubles as a vignette. $1 = foreground width.
fill() {
  local fw="${1:-1040}"
  echo "split=2[bg][fg];\
[bg]scale=$W:$H:force_original_aspect_ratio=increase,crop=$W:$H,\
gblur=sigma=42,eq=brightness=-0.26:saturation=0.65[bgo];\
[fg]scale=$fw:-2:flags=lanczos[fgo];\
[bgo][fgo]overlay=(W-w)/2:(H-h)/2"
}
FINISH="setsar=1,fps=$FPS,format=yuv420p"

echo "── shot 1  cold open: the summon burst (original audio, full-bleed)"
ffmpeg -v error -ss 9.55 -i "$A/Chit Throw.mp4" -t 2.0 \
  -vf "crop=373:664:434:0,scale=$W:$H:flags=lanczos,unsharp=5:5:0.6,$FINISH" \
  -af "volume=1.0,afade=t=out:st=1.7:d=0.3" \
  -c:v libx264 -crf 18 -preset medium -c:a aac -b:a 160k -y "$C/01_burst.mp4"

echo "── shot 2  living battle street (I2V) — trimmed before the HUD text drifts"
ffmpeg -v error -i "$SRC/i2v_street.mp4" -t 2.4 \
  -vf "crop=820:462:300:150,$(fill 1080),$FINISH,$(cap 'THIS IS NORA.')" \
  -an -c:v libx264 -crf 18 -preset medium -y "$C/02_street.mp4"

echo "── shot 3  the mint wizard (real UI, 3x capture, slow push-in)"
ffmpeg -v error -loop 1 -i "$SRC/shots/cap_mint.png" -t 2.8 -r $FPS \
  -vf "crop=1660:1180:1090:660,zoompan=z='min(1+0.0011*in,1.10)':d=1:\
x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=1660x1180:fps=$FPS,\
$(fill 1080),$FINISH,$(cap 'Take a post you own…')" \
  -c:v libx264 -crf 18 -preset medium -y "$C/03_mint.mp4"

echo "── shot 4  the card reveal (full card, no crop into the frame)"
ffmpeg -v error -loop 1 -i "$A/Card View.jpg" -t 2.6 -r $FPS \
  -vf "crop=366:552:60:6,zoompan=z='min(1+0.0013*in,1.13)':d=1:\
x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=366x552:fps=$FPS,\
$(fill 940),$FINISH,$(cap 'Mint it into a card.')" \
  -c:v libx264 -crf 18 -preset medium -y "$C/04_card.mp4"

echo "── shot 5  the card's own cutscene (1280x720 original from battle-media)"
ffmpeg -v error -ss 1.2 -i "$SRC/cuts/66c370f4.mp4" -t 3.6 \
  -vf "$(fill 1080),$FINISH,$(cap 'Every card carries its moment.')" \
  -af "volume=0.9,afade=t=in:st=0:d=0.25,afade=t=out:st=3.2:d=0.4" \
  -c:v libx264 -crf 18 -preset medium -c:a aac -b:a 160k -y "$C/05_cutscene.mp4"

echo "── shot 6  the vault (I2V) — the most stable render, framed on the cards"
ffmpeg -v error -ss 0.3 -i "$SRC/i2v_vault.mp4" -t 2.6 \
  -vf "crop=740:470:24:130,$(fill 1080),$FINISH,$(cap 'Build your deck.')" \
  -an -c:v libx264 -crf 18 -preset medium -y "$C/06_vault.mp4"

echo "── shot 7  the arena lobby (I2V) — right challenge panel cropped OUT (§1 garbled text)"
ffmpeg -v error -ss 0.4 -i "$SRC/i2v_lobby.mp4" -t 2.6 \
  -vf "crop=790:580:70:120,$(fill 1080),$FINISH,$(cap 'Play it in the Arena.')" \
  -an -c:v libx264 -crf 18 -preset medium -y "$C/07_lobby.mp4"

echo "── shot 8  the economy beat"
ffmpeg -v error -loop 1 -i "$A/Card View.jpg" -t 2.4 -r $FPS \
  -vf "crop=452:132:16:752,zoompan=z='min(1+0.0009*in,1.08)':d=1:\
x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=452x132:fps=$FPS,\
$(fill 1080),$FINISH,$(cap 'Trade it. Climb the ladder.')" \
  -c:v libx264 -crf 18 -preset medium -y "$C/08_trade.mp4"

echo "── shot 9  your platforms (real UI, 3x capture)"
ffmpeg -v error -loop 1 -i "$SRC/shots/cap_profile.png" -t 2.4 -r $FPS \
  -vf "crop=1960:1120:940:850,zoompan=z='min(1+0.001*in,1.09)':d=1:\
x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=1960x1120:fps=$FPS,\
$(fill 1080),$FINISH,$(cap 'Your platforms. Your moments.')" \
  -c:v libx264 -crf 18 -preset medium -y "$C/09_profile.mp4"

echo "── shot 10 end card (built in ffmpeg, house palette)"
ffmpeg -v error -f lavfi -i "color=c=$BG:s=${W}x${H}:d=3.2:r=$FPS" \
  -vf "drawtext=fontfile=$FONT:text='N.O.R.A.':fontcolor=0x6C63FF:fontsize=138:x=(w-tw)/2:y=740:alpha='min(1,t*1.8)',\
drawtext=fontfile=$FONT:text='PLATFORMS':fontcolor=white:fontsize=46:x=(w-tw)/2:y=906:alpha='min(1,max(0,(t-0.3)*1.8))',\
drawtext=fontfile=$FONT:text='MINT YOUR MOMENT':fontcolor=0x03DAC6:fontsize=70:x=(w-tw)/2:y=1080:alpha='min(1,max(0,(t-0.7)*1.8))',\
drawtext=fontfile=$FONT:text='noraplatforms.com':fontcolor=white:fontsize=50:x=(w-tw)/2:y=1196:alpha='min(1,max(0,(t-1.0)*1.8))',\
format=yuv420p" \
  -c:v libx264 -crf 18 -preset medium -y "$C/10_end.mp4"

echo "── concat"
: > "$O/concat.txt"
for f in 01_burst 02_street 03_mint 04_card 05_cutscene 06_vault 07_lobby 08_trade 09_profile 10_end; do
  if ! ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$C/$f.mp4" | grep -q .; then
    ffmpeg -v error -i "$C/$f.mp4" -f lavfi -i anullsrc=r=48000:cl=stereo \
      -shortest -c:v copy -c:a aac -b:a 160k -y "$C/${f}_a.mp4"
    echo "file '$(pwd)/$C/${f}_a.mp4'" >> "$O/concat.txt"
  else
    echo "file '$(pwd)/$C/$f.mp4'" >> "$O/concat.txt"
  fi
done
ffmpeg -v error -f concat -safe 0 -i "$O/concat.txt" \
  -c:v libx264 -crf 18 -preset slow -pix_fmt yuv420p -c:a aac -b:a 192k -ar 48000 \
  -movflags +faststart -y "$O/promo_mint_your_moment_9x16.mp4"

echo
ffprobe -v error -show_entries format=duration,size -of default=noprint_wrappers=1 \
  "$O/promo_mint_your_moment_9x16.mp4"
