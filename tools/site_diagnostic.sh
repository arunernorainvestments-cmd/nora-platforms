#!/usr/bin/env bash
# tools/site_diagnostic.sh — repeatable launch-surface diagnostic for noraplatforms.com.
# Checks routing, TLS/redirects, payload budget, and the index.html/manifest launch
# hygiene items tracked in PLAN.md (UX shell phase). Run before/after web deploys.
#
#   bash tools/site_diagnostic.sh [base-url]   # default https://noraplatforms.com
#
# Exit code = number of failed checks (0 = all green).

set -u
BASE="${1:-https://noraplatforms.com}"
UA="Mozilla/5.0 (site-diagnostic)"
FAILS=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILS=$((FAILS + 1)); }

echo "== Routing =="
for path in / /home /mint /market /collection /battle /privacy /terms; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -A "$UA" "$BASE$path")
  [ "$code" = "200" ] && pass "$path -> 200" || fail "$path -> $code (want 200)"
done

echo "== Domain plumbing =="
www_code=$(curl -s -o /dev/null -w '%{http_code}' -A "$UA" "https://www.noraplatforms.com")
[ "$www_code" = "308" ] || [ "$www_code" = "301" ] \
  && pass "www redirects ($www_code)" || fail "www -> $www_code (want 308 redirect to apex)"

echo "== Payload budget =="
js_bytes=$(curl -s -o /dev/null -w '%{size_download}' -H 'Accept-Encoding: gzip' -A "$UA" "$BASE/main.dart.js")
js_mb=$(python3 -c "print(f'{$js_bytes/1048576:.2f}')")
# Budget: 1.5 MB gzipped. Raise deliberately, never silently (PLAN UX phase item C).
if [ "$js_bytes" -gt 0 ] && [ "$js_bytes" -lt 1572864 ]; then
  pass "main.dart.js ${js_mb}MB gzipped (< 1.5MB budget)"
else
  fail "main.dart.js ${js_mb}MB gzipped (budget 1.5MB)"
fi

echo "== index.html launch hygiene =="
html=$(curl -s -A "$UA" "$BASE/")
check_html() { # $1 = grep pattern, $2 = label
  echo "$html" | grep -qE "$1" && pass "$2" || fail "$2"
}
check_html '<meta name="viewport"' 'viewport meta present'
check_html 'property="og:' 'Open Graph tags present'
check_html 'name="twitter:' 'Twitter card tags present'
check_html 'id="nora-splash"|class="nora-splash"' 'branded loading splash present'
if echo "$html" | grep -qiE 'prediction market'; then
  fail 'title/description still pre-v3 ("prediction market") — update for Moments card-battler'
else
  pass 'title/description updated past pre-v3 copy'
fi

echo "== manifest.json hygiene =="
manifest=$(curl -s -A "$UA" "$BASE/manifest.json")
echo "$manifest" | grep -q '"nora_platforms"' \
  && fail 'manifest still stock ("nora_platforms") — brand name/short_name' \
  || pass 'manifest name branded'
echo "$manifest" | grep -q 'A new Flutter project' \
  && fail 'manifest description is stock Flutter' \
  || pass 'manifest description branded'
echo "$manifest" | grep -q '#0175C2' \
  && fail 'manifest theme_color is Flutter blue — want #6C63FF / bg #0A0A0F' \
  || pass 'manifest theme_color branded'

echo
if [ "$FAILS" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
else
  echo "$FAILS CHECK(S) FAILED"
fi
exit "$FAILS"
