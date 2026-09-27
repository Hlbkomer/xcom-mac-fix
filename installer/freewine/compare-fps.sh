#!/bin/bash
# Side-by-side FPS comparison of two sessions (CSV files written by the launchers' FPS logging).
# Copyright (c) 2026 Hlbkomer. MIT License.
# Usage: compare-fps.sh [A B] [--skip N]
#   A and B are CSV files or mode names (free, free-mtld3d, crossover: the newest file of that mode).
#   Default: free against crossover, in ~/Library/Logs/xcom-mac-fix (XCOM_FPS_DIR). --skip N: first N s (default 10).
# For a fair comparison, measure the same scene (same save, same camera spot) for 2-3 minutes in each mode.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUM="$here/fps-summary.sh"; [ -x "$SUM" ] || SUM="$here/../fps-summary.sh"
D="${XCOM_FPS_DIR:-$HOME/Library/Logs/xcom-mac-fix}"
SKIP="${XCOM_FPS_SKIP:-10}"; FILES=()
while [ $# -gt 0 ]; do case "$1" in
  --skip) SKIP="$2"; shift 2;; --skip=*) SKIP="${1#--skip=}"; shift;;
  -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
  *) FILES+=("$1"); shift;; esac; done
newest() { find "$D" -maxdepth 1 -name "fps-$1-*.csv" 2>/dev/null | grep -E "/fps-$1-[0-9]{8}-[0-9]{6}\.csv\$" | sort | tail -1; }
if [ "${#FILES[@]}" -eq 0 ]; then FILES=(free crossover); fi
for i in "${!FILES[@]}"; do [ -f "${FILES[$i]}" ] || FILES[i]="$(newest "${FILES[$i]}")"; done
if [ "${#FILES[@]}" -ne 2 ] || [ ! -f "${FILES[0]}" ] || [ ! -f "${FILES[1]}" ]; then
  echo "Need two session CSVs (found: '${FILES[0]:-}' '${FILES[1]:-}')."
  echo "Play once with each launcher (FPS logging is on by default), or pass two files."; exit 1
fi
kv() { "$SUM" --kv "$1" "$SKIP" | awk -F= -v k="$2" '$1 == k { print $2 }'; }
row() {  # label key
  local a b; a="$(kv "${FILES[0]}" "$2")"; b="$(kv "${FILES[1]}" "$2")"
  awk -v l="$1" -v a="$a" -v b="$b" -v k="$2" 'BEGIN {
    d = ""; if (a != "" && b != "" && k != "samples" && k != "duration_s") {
      d = sprintf("%+.1f", b - a); if (a + 0 > 0) d = d sprintf(" (%+.0f%%)", (b - a) * 100 / a) }
    printf "  %-12s %14s %14s   %s\n", l, a, b, d }'
}
echo "FPS comparison (first $SKIP s of each session skipped)"
printf "  %-12s %14s %14s   %s\n" "" "$(kv "${FILES[0]}" mode)" "$(kv "${FILES[1]}" mode)" "difference (2nd - 1st)"
row "samples" samples; row "measured s" duration_s; row "average" avg; row "median" median
row "1% low" p1; row "min" min; row "max" max
echo "  1st: $(basename "${FILES[0]}")"
echo "  2nd: $(basename "${FILES[1]}")"
