#!/usr/bin/env bash
# make_card_face.sh — re-render a card face for a chit the repo has no detail screenshot of.
#
#   ART=<card_art.png> bash tools/marketing/make_card_face.sh <out.png>
#
# The promo's card beat crops the real `Card View.jpg` detail screenshot. That screenshot
# is of ONE chit (You're Fired, NORA-0103), so swapping the film's hero card leaves the
# beat showing the wrong card. The app cannot be driven headlessly here to capture a new
# one, so this rebuilds the face: the REAL screenshot's chrome, at 2x, with the real
# artwork and the real column values from `moment_chits` composited into it.
#
# It is a re-render, not an invention. Every string below is a live DB value, and the
# layout rules are read off flutter_app/lib/core/widgets/card_face.dart:
#   - the badge hexagon is filled with the FAMILY accent (athlete = #FF5A1F), and its
#     letter is white or #1A1A2E by `_readableOn` (luminance > 0.55 → dark). Orange
#     linearises to 0.29, so the letter is white.
#   - the type line is '<Creature|Spell-Moment> — <TitleCase family>'
#   - the footer is 'Minted from <handle> · <TitleCase platform>' and
#     '<serial> · #1 of <supply> · <TIER>-Tier'
# If any of those change in the app, this file is what goes stale — check it against
# card_face.dart before reusing.
#
# Working at 2x also makes the beat SHARPER than the original: the chrome upscales once
# with lanczos, and the art arrives from the 2048px master rather than from a 320px
# region of a screenshot.
set -euo pipefail

OUT="${1:?usage: ART=<art.png> make_card_face.sh <out.png>}"
A="tools/marketing/assets"
ART="${ART:?set ART to the card_art.png path}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

SANS=/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf
ITAL=/usr/share/fonts/truetype/liberation/LiberationSans-Italic.ttf
HEXF=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf

# Live values — moment_chits 7d7457d2-3c96-47a9-b326-66bd9d901076 (is_active), 2026-08-03.
# Written to files and read with drawtext's `textfile=`: these strings contain an
# apostrophe, '#' and '·', and hand-escaping them into a filter_complex is how you get a
# graph that fails to parse — or worse, one that parses into something subtly wrong.
printf "%s" "Who's Gonna Carry The Boats"                  > "$T/title"
printf "%s" "Athlete"                                      > "$T/family"
printf "%s" "A"                                            > "$T/tier"
printf "%s" "8"                                            > "$T/cost"
printf "%s" "Spell-Moment — Athlete"                       > "$T/type"
printf "%s" "Battlecry: Give +6 ATK to this creature."     > "$T/rules"
printf "%s" "The moment the whole arena rose to its feet." > "$T/flavor"
printf "%s" "Minted from @nora · Platform"                 > "$T/footl"
printf "%s" "NORA-0228 · #1 of 1 · A-Tier"                 > "$T/footr"
printf "%s" "⬢"                                            > "$T/hex"

ACCENT=0xFF5A1F          # familyAccent['athlete']
LETTER=white             # _readableOn(#FF5A1F)

# Chrome colours sampled from the screenshot itself, so the patches are invisible.
BAR=0x202036             # title bar / type-line pill
ROW=0x1E1E32             # family row
BODY=0x121120            # rules + flavor area
FOOT=0x11101D            # footer strip
FOOTTX=0x7B7A8B
COSTFILL=0x6C63FF        # AppTheme.primary

ffmpeg -v error -i "$A/Card View.jpg" -i "$ART" -filter_complex "\
[0:v]crop=366:545:60:6,scale=732:1090:flags=lanczos,setsar=1[base];\
[1:v]crop=1848:1330:100:330,scale=640:460:flags=lanczos,setsar=1,\
drawbox=x=0:y=0:w=640:h=460:color=${ACCENT}@0.85:t=6[art];\
[base]\
drawbox=x=58:y=50:w=542:h=60:color=${BAR}:t=fill,\
drawbox=x=626:y=58:w=32:h=44:color=${COSTFILL}:t=fill,\
drawbox=x=58:y=132:w=330:h=60:color=${ROW}:t=fill,\
drawbox=x=56:y=688:w=634:h=40:color=${BAR}:t=fill,\
drawbox=x=56:y=748:w=634:h=88:color=${BODY}:t=fill,\
drawbox=x=44:y=1018:w=656:h=42:color=${FOOT}:t=fill,\
drawtext=fontfile=${SANS}:textfile=${T}/title:fontcolor=white:fontsize=32:x=66:y=64,\
drawtext=fontfile=${SANS}:textfile=${T}/cost:fontcolor=white:fontsize=26:x=641-tw/2:y=66,\
drawtext=fontfile=${HEXF}:textfile=${T}/hex:fontcolor=${ACCENT}:fontsize=62:x=87-tw/2:y=162-th/2,\
drawtext=fontfile=${SANS}:textfile=${T}/tier:fontcolor=${LETTER}:fontsize=24:x=87-tw/2:y=164-th/2,\
drawtext=fontfile=${SANS}:textfile=${T}/family:fontcolor=white:fontsize=30:x=124:y=148,\
drawtext=fontfile=${SANS}:textfile=${T}/type:fontcolor=white:fontsize=28:x=64:y=694,\
drawtext=fontfile=${SANS}:textfile=${T}/rules:fontcolor=white:fontsize=25:x=64:y=756,\
drawtext=fontfile=${ITAL}:textfile=${T}/flavor:fontcolor=0xB9B7C8:fontsize=23:x=64:y=794,\
drawtext=fontfile=${SANS}:textfile=${T}/footl:fontcolor=${FOOTTX}:fontsize=19:x=52:y=1028,\
drawtext=fontfile=${SANS}:textfile=${T}/footr:fontcolor=${FOOTTX}:fontsize=19:x=690-tw:y=1028[chrome];\
[chrome][art]overlay=48:205[v]" \
  -map "[v]" -frames:v 1 -y "$OUT"

echo "card face → $OUT"
