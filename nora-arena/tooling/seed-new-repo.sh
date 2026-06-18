#!/usr/bin/env bash
#
# Creates the standalone nora-arena GitHub repo and pushes this folder's contents
# as its first commit. The nora-arena handoff scaffold (docs + lib/ import flow +
# CI + pubspec) becomes the new repo as-is — no build, just "give it the files".
#
# WHY A SCRIPT: the Codespaces GITHUB_TOKEN is scoped to nora-platforms only and
# cannot create repos. Run this from a machine where `gh auth status` shows an
# account that CAN create repos (your own `gh auth login`, or a PAT with `repo`
# scope: `GH_TOKEN=ghp_xxx bash nora-arena/tooling/seed-new-repo.sh`).
#
# USAGE (from the nora-platforms repo root):
#   bash nora-arena/tooling/seed-new-repo.sh
#
set -euo pipefail

ORG=arunernorainvestments-cmd
NAME=nora-arena
VISIBILITY=--private              # change to --public if you want it public
SRC="$(cd "$(dirname "$0")/.." && pwd)"   # the nora-arena/ folder
TMP="$(mktemp -d)"

echo "Creating $ORG/$NAME ..."
gh repo create "$ORG/$NAME" $VISIBILITY \
  --description "N.O.R.A. Arena — mobile Arena/Battle app (shares the nora-platforms Supabase backend)."

echo "Seeding from $SRC ..."
cp -a "$SRC/." "$TMP/"
cd "$TMP"
git init -b main >/dev/null
git add -A
git commit -q -m "chore: seed nora-arena from nora-platforms handoff scaffold

Docs (AGENTS/BUILD_WORKFLOW/ARCHITECTURE/pipeline), the license-import lib/
scaffold, CI, and pubspec. Next: flutter create --platforms=ios,android (Phase 0)."
git remote add origin "https://github.com/$ORG/$NAME.git"
git push -u origin main

echo ""
echo "Done -> https://github.com/$ORG/$NAME"
echo "Next: clone it, then run  flutter create --platforms=ios,android --org com.noraplatforms ."
