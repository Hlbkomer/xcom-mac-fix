#!/bin/bash
# FPS source for the Metal renderer (mtld3d): Wine's "+fps" trace exists only in wined3d, so play.sh
# --renderer=mtld3d runs the game with Apple's Metal Performance HUD logging (MTL_HUD_LOG_ENABLED=1). About once
# per second the HUD logs "metal-HUD: <first frame number>,<memory>,<memory>,<per-frame times...>" (subsystem
# com.apple.metal.hud). macOS redacts the per-frame part as <private>, so this script uses the public frame
# counter: fps = frames between two lines / seconds between their log timestamps. It appends wined3d-style lines
# ("0000:trace:fps:mtlhud @ approx 59.94fps") to OUTFILE, which bin/fpsbar reads exactly like Wine's trace, and
# exits when WATCH_PID exits.
# Copyright (c) 2026 Hlbkomer. MIT License.
# Usage: mtlhud-fps.sh OUTFILE WATCH_PID
out="${1:-}"; pid="${2:-}"
case "$pid" in ''|*[!0-9]*) echo "usage: mtlhud-fps.sh OUTFILE WATCH_PID"; exit 2;; esac
[ -n "$out" ] || { echo "usage: mtlhud-fps.sh OUTFILE WATCH_PID"; exit 2; }
: >> "$out" || exit 1
/usr/bin/log stream --style compact \
  --predicate "processID == $pid AND subsystem == \"com.apple.metal.hud\" AND eventMessage CONTAINS \"metal-HUD:\"" \
  > >(awk '{
    i = index($0, "metal-HUD:"); if (!i || $2 !~ /^[0-9]+:[0-9]+:[0-9.]+$/) next
    split($2, c, ":"); t = c[1] * 3600 + c[2] * 60 + c[3]
    s = substr($0, i + 10); sub(/^ +/, "", s); split(s, f, ","); fr = f[1] + 0
    if (!have) { have = 1; lt = t; lf = fr; next }
    dt = t - lt; if (dt < 0) dt += 86400; df = fr - lf
    if (df < 0) { lt = t; lf = fr; next }              # counter restarted (new device)
    if (dt < 0.5) next                                  # duplicate or too close: keep accumulating
    printf "0000:trace:fps:mtlhud @ approx %.2ffps\n", df / dt; fflush()
    lt = t; lf = fr
  }' >> "$out") 2>/dev/null &
lp=$!
trap 'kill "$lp" 2>/dev/null' EXIT INT TERM
while kill -0 "$pid" 2>/dev/null && kill -0 "$lp" 2>/dev/null; do sleep 2; done
