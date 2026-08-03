#!/usr/bin/env bash
# build_promo_16x9.sh — the 16:9 master (YouTube / X / site embed).
#
# Not a crop of the 9:16. Sources that are natively 16:9 (the card cutscene, the
# I2V renders, the throw footage) fill the frame directly; the portrait sources
# (card view) and the one source with a small clean window (the battle street,
# whose only text-free region is 500x430) keep the blurred-bed fill so they never
# upscale past what they can carry.
#
#   SRC=<working dir>  bash tools/marketing/build_promo_16x9.sh
set -euo pipefail

SRC="${SRC:?set SRC to the working dir}"
A="tools/marketing/assets"
O="tools/marketing/out"
C="$O/cuts16"
mkdir -p "$C"

BG=0x0A0A0F
FONT=/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf
MONO=/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf
W=1920; H=1080; FPS=30
XF=0.32

# 16:9 has no platform chrome to dodge, so the caption sits on the lower third.
cap() {
  local d="$2"
  local al="if(lt(t\,0.35)\,t/0.35\,if(gt(t\,${d}-0.4)\,max(0\,(${d}-t)/0.4)\,1))"
  echo "drawtext=fontfile=$FONT:text='$1':fontcolor=white:fontsize=54:x=(w-tw)/2:y=968:\
box=1:boxcolor=0x0A0A0F@0.58:boxborderw=22:shadowcolor=black@0.7:shadowx=2:shadowy=2:alpha='$al'"
}
fill() {
  local fw="${1:-1660}"
  echo "split=2[bg][fg];\
[bg]scale=$W:$H:force_original_aspect_ratio=increase,crop=$W:$H,\
gblur=sigma=40,eq=brightness=-0.26:saturation=0.65[bgo];\
[fg]scale=-2:${fw}:flags=lanczos[fgo];\
[bgo][fgo]overlay=(W-w)/2:(H-h)/2"
}
FINISH="setsar=1,fps=$FPS,format=yuv420p"
D1=2.267; D2=2.4; D3=2.6; D4=2.6; D5=3.4; D6=2.4; D7=2.4; D8=2.3; D9=2.3; D10=3.2

echo "── 1  cold open: speed-ramped burst, native 16:9 framing"
CROP16="crop=644:362:268:150,scale=$W:$H:flags=lanczos,unsharp=6:6:0.8,setsar=1,format=yuv420p"
ffmpeg -v error -ss 9.34 -t 0.36 -i "$A/Chit Throw.mp4" \
  -vf "$CROP16,setpts=PTS/0.5,fps=$FPS" -an -c:v libx264 -crf 17 -preset medium -y "$C/01a.mp4"
ffmpeg -v error -ss 9.70 -t 1.47 -i "$A/Chit Throw.mp4" \
  -vf "$CROP16,zoompan=z='max(1.0,1.12-0.0133*in)':d=1:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=${W}x${H}:fps=$FPS,format=yuv420p" \
  -an -c:v libx264 -crf 17 -preset medium -y "$C/01b.mp4"
ffmpeg -v error -i "$C/01a.mp4" -i "$C/01b.mp4" \
  -filter_complex "[0:v][1:v]concat=n=2:v=1:a=0,eq=brightness='if(between(t,0.70,0.78),0.6,0)':eval=frame,$FINISH[v]" \
  -map "[v]" -c:v libx264 -crf 17 -preset medium -y "$C/01_burst.mp4"

echo "── 2  battle street (I2V) — the 500x430 window is the only text-free region"
ffmpeg -v error -i "$SRC/i2v_street.mp4" -t $D2 \
  -vf "crop=500:430:400:130,$(fill 930),$FINISH,$(cap 'THIS IS NORA.' $D2)" \
  -an -c:v libx264 -crf 18 -preset medium -y "$C/02_street.mp4"

echo "── 3  the mint wizard, with the URL typed in (wide framing)"
python3 - "$W" "$H" > "$O/typing16.filter" <<'PY'
import sys
MONO='/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf'
FONT='/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf'
url="https://www.tiktok.com/@yourhandle/video/7421"
X0,Y,SIZE=1252,1466,44
ADV=SIZE*0.60206; T0,TD=0.28,1.5
esc=lambda s:s.replace('\\','\\\\').replace(':','\\:').replace("'","\\'").replace('%','\\%')
p=["drawbox=x=1210:y=1432:w=1420:h=126:color=0x16213E:t=fill"]
n=len(url)
for i in range(1,n+1):
    ta=T0+((i-1)/n)*TD; tb=T0+(i/n)*TD
    en=f"between(t\\,{ta:.3f}\\,{tb:.3f})" if i<n else f"gte(t\\,{ta:.3f})"
    p.append(f"drawtext=fontfile={MONO}:text='{esc(url[:i])}':fontcolor=white:fontsize={SIZE}:x={X0}:y={Y}:enable='{en}'")
for i in range(n+1):
    ta=T0+(i/n)*TD; tb=T0+((i+1)/n)*TD if i<n else 99
    x=int(X0+i*ADV)+2
    en=(f"between(t\\,{ta:.3f}\\,{tb:.3f})" if i<n else f"gte(t\\,{ta:.3f})*lt(mod(t\\,0.86)\\,0.5)")
    p.append(f"drawbox=x={x}:y=1460:w=4:h=62:color=0x03DAC6:t=fill:enable='{en}'")
p.append("drawbox=x=1206:y=1709:w=1428:h=96:color=0x8B84FF@0.30:t=fill:enable='between(t,2.12,2.44)'")
# wide crop for 16:9: the whole wizard card plus breathing room either side
p.append("crop=2200:1240:830:640")
p.append("zoompan=z='min(1+0.0012*in,1.09)':d=1:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=2200x1240:fps=30")
p.append("split=2[bg][fg];[bg]scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,"
         "gblur=sigma=40,eq=brightness=-0.26:saturation=0.65[bgo];[fg]scale=-2:880:flags=lanczos[fgo];"
         "[bgo][fgo]overlay=(W-w)/2:(H-h)/2")
p.append("setsar=1,fps=30,format=yuv420p")
al="if(lt(t\\,0.35)\\,t/0.35\\,if(gt(t\\,2.2)\\,max(0\\,(2.6-t)/0.4)\\,1))"
p.append(f"drawtext=fontfile={FONT}:text='Take a post you own…':fontcolor=white:fontsize=54:"
         f"x=(w-tw)/2:y=968:box=1:boxcolor=0x0A0A0F@0.58:boxborderw=22:"
         f"shadowcolor=black@0.7:shadowx=2:shadowy=2:alpha='{al}'")
print(",".join(p))
PY
ffmpeg -v error -loop 1 -i "$SRC/shots/cap_mint.png" -t $D3 -r $FPS \
  -filter_script:v "$O/typing16.filter" -c:v libx264 -crf 18 -preset medium -y "$C/03_mint.mp4"

echo "── 4  the card reveal (portrait source keeps the fill bed)"
ffmpeg -v error -loop 1 -i "$A/Card View.jpg" -t $D4 -r $FPS \
  -vf "crop=366:552:60:6,zoompan=z='min(1+0.0013*in,1.13)':d=1:\
x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=366x552:fps=$FPS,\
$(fill 900),$FINISH,$(cap 'Mint it into a card.' $D4)" \
  -c:v libx264 -crf 18 -preset medium -y "$C/04_card.mp4"

echo "── 5  the cutscene — natively 16:9, fills the frame"
ffmpeg -v error -ss 1.9 -i "$SRC/cuts/66c370f4.mp4" -t $D5 \
  -vf "scale=$W:$H:flags=lanczos,$FINISH,$(cap 'Every card carries its moment.' $D5)" \
  -an -c:v libx264 -crf 18 -preset medium -y "$C/05_cutscene.mp4"

echo "── 6  the vault (I2V) — wide framing on the card row"
ffmpeg -v error -ss 0.3 -i "$SRC/i2v_vault.mp4" -t $D6 \
  -vf "crop=1180:664:30:70,scale=$W:$H:flags=lanczos,$FINISH,$(cap 'Build your deck.' $D6)" \
  -an -c:v libx264 -crf 18 -preset medium -y "$C/06_vault.mp4"

echo "── 7  the arena lobby (I2V) — challenge panel still cropped out (§1)"
ffmpeg -v error -ss 0.4 -i "$SRC/i2v_lobby.mp4" -t $D7 \
  -vf "crop=1030:579:40:110,scale=$W:$H:flags=lanczos,$FINISH,$(cap 'Play it in the Arena.' $D7)" \
  -an -c:v libx264 -crf 18 -preset medium -y "$C/07_lobby.mp4"

echo "── 8  the economy beat"
ffmpeg -v error -loop 1 -i "$A/Card View.jpg" -t $D8 -r $FPS \
  -vf "crop=452:132:16:752,zoompan=z='min(1+0.0009*in,1.08)':d=1:\
x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=452x132:fps=$FPS,\
$(fill 420),$FINISH,$(cap 'Trade it. Climb the ladder.' $D8)" \
  -c:v libx264 -crf 18 -preset medium -y "$C/08_trade.mp4"

echo "── 9  your platforms (real UI, wide crop)"
ffmpeg -v error -loop 1 -i "$SRC/shots/cap_profile.png" -t $D9 -r $FPS \
  -vf "crop=2400:1350:720:760,zoompan=z='min(1+0.001*in,1.09)':d=1:\
x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=2400x1350:fps=$FPS,\
$(fill 900),$FINISH,$(cap 'Your platforms. Your moments.' $D9)" \
  -c:v libx264 -crf 18 -preset medium -y "$C/09_profile.mp4"

echo "── 10 end card"
ffmpeg -v error -f lavfi -i "color=c=$BG:s=${W}x${H}:d=$D10:r=$FPS" \
  -vf "drawtext=fontfile=$FONT:text='N.O.R.A.':fontcolor=0x6C63FF:fontsize=132:x=(w-tw)/2:y=340:alpha='min(1,t*1.8)',\
drawtext=fontfile=$FONT:text='PLATFORMS':fontcolor=white:fontsize=44:x=(w-tw)/2:y=498:alpha='min(1,max(0,(t-0.3)*1.8))',\
drawtext=fontfile=$FONT:text='MINT YOUR MOMENT':fontcolor=0x03DAC6:fontsize=66:x=(w-tw)/2:y=640:alpha='min(1,max(0,(t-0.7)*1.8))',\
drawtext=fontfile=$FONT:text='noraplatforms.com':fontcolor=white:fontsize=48:x=(w-tw)/2:y=750:alpha='min(1,max(0,(t-1.0)*1.8))',\
format=yuv420p" \
  -c:v libx264 -crf 18 -preset medium -y "$C/10_end.mp4"

echo "── cross-dissolve chain + grade"
ffmpeg -v error \
 -i "$C/01_burst.mp4" -i "$C/02_street.mp4" -i "$C/03_mint.mp4" -i "$C/04_card.mp4" \
 -i "$C/05_cutscene.mp4" -i "$C/06_vault.mp4" -i "$C/07_lobby.mp4" -i "$C/08_trade.mp4" \
 -i "$C/09_profile.mp4" -i "$C/10_end.mp4" \
 -filter_complex "\
[0:v][1:v]xfade=transition=fade:duration=$XF:offset=1.947[x1];\
[x1][2:v]xfade=transition=slideleft:duration=$XF:offset=4.027[x2];\
[x2][3:v]xfade=transition=fade:duration=$XF:offset=6.307[x3];\
[x3][4:v]xfade=transition=fadewhite:duration=$XF:offset=8.587[x4];\
[x4][5:v]xfade=transition=fade:duration=$XF:offset=11.667[x5];\
[x5][6:v]xfade=transition=slideleft:duration=$XF:offset=13.747[x6];\
[x6][7:v]xfade=transition=fade:duration=$XF:offset=15.827[x7];\
[x7][8:v]xfade=transition=slideleft:duration=$XF:offset=17.807[x8];\
[x8][9:v]xfade=transition=fade:duration=$XF:offset=19.787[x9];\
[x9]eq=saturation=1.07:contrast=1.05,colorbalance=bs=0.05:bm=0.02,\
vignette=angle=PI/5:mode=forward,format=yuv420p[vout]" \
 -map "[vout]" -c:v libx264 -crf 18 -preset slow -pix_fmt yuv420p -y "$C/video_only.mp4"

echo "── audio (identical bed to the 9:16 — no beeps)"
S="$SRC/sfx"
ffmpeg -v error \
 -i "$C/video_only.mp4" -i "$O/cuts/a01.wav" -i "$O/cuts/a05.wav" \
 -i "$S/whoosh.wav" -i "$S/whoosh.wav" -i "$S/whoosh.wav" -i "$S/riser.wav" -i "$S/impact.wav" \
 -filter_complex "\
[1]adelay=0|0,volume=1.0[c1];[2]adelay=8587|8587,volume=1.0[c5];\
[3]adelay=1947|1947,volume=0.34[w1];[4]adelay=11667|11667,volume=0.30[w2];\
[5]adelay=13747|13747,volume=0.30[w3];[6]adelay=18690|18690,volume=0.55[rs];\
[7]adelay=19787|19787,volume=0.60[hit];\
[c1][c5][w1][w2][w3][rs][hit]amix=inputs=7:duration=longest:dropout_transition=0,\
loudnorm=I=-16.5:TP=-1.5:LRA=11,alimiter=limit=0.97,apad=whole_dur=30[aout]" \
 -map 0:v -map "[aout]" -shortest \
 -c:v copy -c:a aac -b:a 192k -ar 48000 -movflags +faststart \
 -y "$O/promo_mint_your_moment_16x9.mp4"

echo
ffprobe -v error -show_entries format=duration,size -of default=noprint_wrappers=1 \
  "$O/promo_mint_your_moment_16x9.mp4"
