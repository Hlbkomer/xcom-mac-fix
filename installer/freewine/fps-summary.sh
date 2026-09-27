#!/bin/bash
# FPS summary of one session CSV written by bin/fpsbar ("time,elapsed_s,fps", one sample per ~1.5 s from Wine's
# +fps trace, or per ~1 s from the Metal HUD with --renderer=mtld3d).
# Copyright (c) 2026 Hlbkomer. MIT License.
# Usage: fps-summary.sh [--kv] FILE.csv [SKIP_SECONDS]
#   SKIP_SECONDS: samples from the first N seconds after the game appeared are ignored (loading, intro
#   movies). Default 10, or $XCOM_FPS_SKIP. --kv prints key=value lines (used by compare-fps.sh).
# Each sample is an average over ~1-1.5 s, so "1% low" here is the 1st percentile of those averages
# (with fewer than 100 samples it equals the minimum). It is not a frame-time 1% low.
# Exact 0.00 values are ignored: wined3d's first report of a session is always "approx 0.00fps" (its interval
# timer starts at zero); a real stall still prints a small non-zero number once the next frame is presented.
KV=0; [ "${1:-}" = --kv ] && { KV=1; shift; }
f="${1:-}"; skip="${2:-${XCOM_FPS_SKIP:-10}}"
[ -f "$f" ] || { echo "usage: fps-summary.sh [--kv] FILE.csv [SKIP_SECONDS]"; exit 2; }
name="$(basename "$f" .csv)"; mode="${name#fps-}"; mode="${mode%-*-*}"   # fps-<mode>-<date>-<time>, mode e.g. free-mtld3d
awk -F, -v s="$skip" 'NR > 1 && $2 + 0 >= s && $3 + 0 > 0 { print $2, $3 }' "$f" | sort -k2,2n | awk \
  -v kv="$KV" -v name="$name" -v mode="$mode" -v skip="$skip" '
  { el[NR] = $1; v[NR] = $2; sum += $2
    if (NR == 1 || $1 < t0) t0 = $1
    if (NR == 1 || $1 > t1) t1 = $1 }
  END {
    n = NR
    if (n == 0) { if (kv) print "samples=0"; else printf "%s: no samples after the first %s s\n", name, skip; exit 1 }
    mean = sum / n
    med = (n % 2) ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2
    i = int(n * 0.01 + 0.999999); if (i < 1) i = 1
    iv = (n > 1) ? (t1 - t0) / (n - 1) : 1.5; dur = t1 - t0 + iv
    if (kv) {
      printf "name=%s\nmode=%s\nsamples=%d\nduration_s=%.0f\navg=%.1f\nmedian=%.1f\np1=%.1f\nmin=%.1f\nmax=%.1f\n", \
        name, mode, n, dur, mean, med, v[i], v[1], v[n]
    } else {
      printf "FPS summary (%s)\n", name
      printf "  mode %s | %d samples of ~%.1f s | %.0f s measured (first %s s skipped)\n", mode, n, iv, dur, skip
      printf "  average %.1f | median %.1f | 1%% low %.1f | min %.1f | max %.1f\n", mean, med, v[i], v[1], v[n]
    }
  }'
