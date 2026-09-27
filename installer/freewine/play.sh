#!/bin/bash
# XCOM: Enemy Within on free Wine (athei/wine-build cx-26.3.0-6: NX fix built in, cooperative x87sidecar hook).
# Starts Steam if needed, waits until you are logged in, asks Steam to launch XCOM and presses "Enemy Within"
# in the XCOM launcher for you. x87sidecar, mtld3d (d3d9 on Metal) and the FPS counter apply to the game only.
# The FPS counter is a small box in the top-left corner of the game window ("FPS 60"; bin/fpsbar). Every session
# also writes its fps samples to ~/Library/Logs/xcom-mac-fix/fps-free-<time>.csv and prints a summary at the end
# (compare with CrossOver mode: compare-fps.sh).
# When the game exits, Steam is closed too (clean -shutdown, falling back to wineserver -k): nothing left running.
#
# Usage: play.sh [options]
#   --no-hud      no FPS box (it is on by default, see HUD_DEFAULT in env.sh); the fps log stays on
#   --hud         show the FPS box (only needed if HUD_DEFAULT=0)
#   --no-fps      no fps trace, no box, no CSV/summary
#   --overlay     enable Steam's in-game overlay (off by default: see steam_env in env.sh)
#   --no-x87      without x87sidecar (slow; for comparison)
#   --renderer=R  d3d9 for the game: mtld3d (default: athei's d3d9 on Metal; FPS from Apple's Metal HUD log,
#                 CSV fps-free-mtld3d-<time>.csv) or gl (Wine's wined3d on OpenGL, CSV fps-free-<time>.csv).
#                 dxvk/vulkan/d3dmetal: not available in this build (no Vulkan)
#   --mtld3d      same as the default (--renderer=mtld3d)
#   --launcher    don't press Enemy Within automatically (pick it yourself in the XCOM launcher)
#   --direct      start XComEW.exe directly instead of through Steam (Steam then stalls; not recommended)
#   --keep-steam  leave Steam running after the game exits
#   --validate    first run Steam's "Verify integrity of game files" (fixes a game that quits after ~2 s)
#   --debug=CH    WINEDEBUG channels for the game process only (e.g. --debug=+seh)
# shellcheck source-path=SCRIPTDIR source=env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

X87=1; HUD=$HUD_DEFAULT; FPS=$FPS_DEFAULT; OVL=$OVERLAY_DEFAULT; D3D=mtld3d; AUTO=1; DIRECT=0; KEEP=0; VALIDATE=0; DBG=""
for a in "$@"; do case "$a" in
  --no-hud) HUD=0;; --hud) HUD=1;; --no-fps) FPS=0; HUD=0;; --fps) FPS=1;; --overlay) OVL=1;; --no-overlay) OVL=0;; --no-x87) X87=0;; --mtld3d) D3D=mtld3d;; --launcher) AUTO=0;;
  --renderer=gl|--renderer=wined3d|--renderer=opengl) D3D=wined3d;; --renderer=mtld3d|--renderer=metal) D3D=mtld3d;;
  --renderer=dxvk|--renderer=vulkan)
    echo "No Vulkan in this Wine build (athei/wine-build is built --without-vulkan: no winevulkan, vulkan-1 or MoltenVK),"
    echo "so neither DXVK nor wined3d's Vulkan renderer can run. Available: --renderer=mtld3d (default) or --renderer=gl."; exit 2;;
  --renderer=d3dmetal|--renderer=gptk)
    echo "Apple's D3DMetal has no Direct3D 9 (and is 64-bit only in this build). Available: --renderer=gl or --renderer=mtld3d."; exit 2;;
  --renderer=*) echo "unknown renderer: ${a#--renderer=} (gl or mtld3d)"; exit 2;;
  --direct) DIRECT=1;; --keep-steam) KEEP=1;; --validate) VALIDATE=1;; --debug=*) DBG="${a#--debug=}";;
  -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
  *) echo "unknown option: $a (see --help)"; exit 2;; esac; done

pause() { [ -t 0 ] && [ -t 1 ] && read -r -t "${1:-30}" -p "${2:-(this window closes in ${1:-30} s)}" _; echo; }
fail()  { echo; echo "$1"; pause 120 "Press Enter to close."; exit 1; }
ts()    { date '+%H:%M:%S'; }

[ -x "$F/wine/bin/wine" ] || fail "Wine is missing in $F/wine; re-run the installer."
[ -x "$F/bin/x87filter" ] || fail "bin/x87filter is missing; re-run the installer."
[ "$X87" = 0 ] || [ -x "$F/bin/x87sidecar" ] || fail "x87sidecar is missing in $F/bin; re-run the installer."
[ -d "$GAME_UNIX" ] || fail "Enemy Within is not installed in this prefix ($GAME_UNIX)."
# Stock mtld3d reports an Apple GPU and presents HDR. XCOM is Unreal Engine 3:
# it only copies scene depth for NVIDIA/AMD, and it has already tonemapped for
# an SDR monitor. The file is read at Direct3DCreate9. A future mtld3d with the
# xcom-ew profile sets the same three keys; a file here still wins, key by key.
# An existing file is left alone, so a hand edit is kept.
if [ "$D3D" = mtld3d ] && [ ! -f "$GAME_UNIX/mtld3d.conf" ]; then
  cat > "$GAME_UNIX/mtld3d.conf" << 'EOF'
# Written by play.sh --mtld3d. Delete this file to recreate it on the next launch.
adapter.spoof = nvidia
color.hdr.enable = false
color.space = accurate
EOF
  echo "  Wrote mtld3d.conf next to XComEW.exe (NVIDIA adapter, SDR present)."
fi
other_running && fail "Another Wine Steam (CrossOver or the CrossOver-mode fix) is running. Quit it (Steam menu > Exit) first: only one Steam at a time."
[ -n "$(game_pids)" ] && fail "XCOM is already running. If it is stuck, use stop.sh (or the Desktop 'stop' launcher)."
if ws_running && [ -z "$(steam_pids)" ]; then echo "Cleaning up a leftover Wine session..."; shutdown_all >/dev/null; fi
sweep_orphans
rotate_logs
STAMP="$(date +%Y%m%d-%H%M%S)"
SLOG="$F/logs/steam-$STAMP.log"
WANT="$(settings_sig "$X87" "$FPS" "$D3D" "$OVL" "$DBG")"
onoff() { if [ "$1" = 1 ]; then echo on; else echo off; fi; }

RNAME=gl; [ "$D3D" = mtld3d ] && RNAME=mtld3d
echo "XCOM: Enemy Within (free Wine)  x87 sidecar: $(onoff "$X87")  d3d9: $RNAME  FPS box: $(onoff "$HUD")  FPS log: $(onoff "$FPS")  Steam overlay: $(onoff "$OVL")"
for INI in "$WINEPREFIX"/drive_c/users/*/Documents/"My Games/XCOM - Enemy Within/XComGame/Config/XComEngine.ini"; do
  case "$INI" in */users/Public/*) continue;; esac
  if [ -f "$INI" ] && grep -a -q '^AmbientOcclusion=False' "$INI"; then
    echo "  Note: Ambient Occlusion is OFF in XComEngine.ini. With built-in d3d9 that crashed at mission start:"
    echo "        turn it on in the game's graphics options (or: install.sh --game-config)."
  fi
done
# Steam passes its environment down to the game, so it must run with these settings.
if [ -n "$(steam_pids)" ] && [ "$DIRECT" = 0 ] && [ "$(cat "$SETTINGS_FILE" 2>/dev/null)" != "$WANT" ]; then
  echo "[$(ts)] Restarting Steam so these settings apply..."; shutdown_all >/dev/null || fail "Steam did not exit."
fi
if [ -z "$(steam_pids)" ]; then
  wine reg add 'HKCU\Software\Valve\Steam\ActiveProcess' /v ActiveUser /t REG_DWORD /d 0 /f >/dev/null 2>&1
  echo "[$(ts)] Starting Steam..."
  ( steam_env "$X87" "$FPS" "$D3D" "$OVL" "$DBG"; start_steam "$SLOG" )
fi
echo "[$(ts)] Waiting for Steam to be logged in..."
wait_steam_ready 900; case $? in 1) fail "Steam exited before it was ready (log: $SLOG).";; 2) fail "Steam was not logged in after 15 minutes; giving up.";; esac
sleep 3
if [ "$VALIDATE" = 1 ]; then validate_game || fail "Verification failed."; fi
GLOG="$F/logs/game-$STAMP.log"
if [ "$DIRECT" = 1 ]; then
  echo "[$(ts)] Starting Enemy Within directly..."
  ( steam_env "$X87" "$FPS" "$D3D" "$OVL" "$DBG"; export SteamAppId=$APPID SteamGameId=$APPID
    cd "$GAME_UNIX" && exec nohup wine "$GAME_WIN" -FROMLAUNCHER -LANGUAGE=INT ) > "$GLOG" 2>&1 &
else
  echo "[$(ts)] Asking Steam to launch XCOM..."
  echo "  First launch only: Steam may show the game's license agreement (accept it) and install DirectX/VC++."
  wine "$STEAM_EXE" -applaunch "$APPID" >/dev/null 2>&1 &
  if [ "$AUTO" = 1 ]; then
    ( wine "$F/bin/xclick.exe" ew 900 > "$GLOG" 2>&1 ) &
    echo "[$(ts)] Enemy Within will be selected in the XCOM launcher automatically."
  else echo "[$(ts)] In the XCOM launcher, click Enemy Within (upper button)."; fi
fi

# wait for Enemy Within to appear, then for every XCOM process to exit
t=0; until [ -n "$(fw_pids 'xcomew\.exe' | head -1)" ]; do
  sleep 2; t=$((t+2)); [ "$t" -ge 900 ] && fail "Enemy Within did not start within 15 minutes (logs: $SLOG, $GLOG)."; done
T0=$(date +%s)
echo "[$(ts)] Game running. Leave this window open: it closes Steam after the game exits$([ "$KEEP" = 1 ] && echo ' (disabled: --keep-steam)')."
echo "        Closing this window does not stop the game."
FBP=""; CSV=""; MHP=""
if [ "$FPS" = 1 ]; then   # the game's output (with the +fps lines) goes to the log of the Steam that started it
  if [ "$DIRECT" = 1 ]; then OUT="$GLOG"; else OUT="$(cat "$STEAMLOG_FILE" 2>/dev/null)"; fi
  GP="$(fw_pids 'xcomew\.exe' | head -1)"
  MODE=free
  if [ "$D3D" = mtld3d ] && [ -n "$GP" ]; then   # no +fps in mtld3d: convert the Metal HUD's log lines instead
    MODE=free-mtld3d; OUT="$F/logs/mtlhud-$STAMP.log"
    nohup "$F/mtlhud-fps.sh" "$OUT" "$GP" > /dev/null 2>&1 &
    MHP=$!
  fi
  if [ ! -x "$F/bin/fpsbar" ]; then echo "  (FPS counter: bin/fpsbar is missing; re-run the installer)"
  elif [ -n "$OUT" ] && [ -n "$GP" ] && mkdir -p "$FPS_DIR"; then
    CSV="$FPS_DIR/fps-$MODE-$STAMP.csv"
    HID=(); [ "$HUD" = 1 ] || HID=(--hidden)
    nohup "$F/bin/fpsbar" "${HID[@]}" --csv "$CSV" --status "$F/logs/fpsbar-status.txt" "$OUT" "$GP" \
      > "$F/logs/fpsbar-$STAMP.log" 2>&1 &
    FBP=$!
    [ "$HUD" = 1 ] && echo "        FPS counter: small box in the game window's top-left corner ('FPS -' until the first number)."
    echo "        FPS log: $CSV"
  fi
fi
while [ -n "$(game_pids | head -1)" ]; do sleep 5; done
[ -n "$FBP" ] && kill "$FBP" 2>/dev/null
[ -n "$MHP" ] && kill "$MHP" 2>/dev/null
if [ -n "$CSV" ] && [ -f "$CSV" ]; then
  echo; "$F/fps-summary.sh" "$CSV" | tee "${CSV%.csv}-summary.txt"; echo
  find "$FPS_DIR" -maxdepth 1 -name 'fps-free-*' | sort -r | tail -n +101 | while IFS= read -r f; do rm -f "$f"; done
fi
DUR=$(( $(date +%s) - T0 ))
echo "[$(ts)] Game exited after ${DUR} s."
if [ "$DUR" -lt 15 ] && [ ! -s "$LAUNCH_LOG" ]; then
  echo "  It quit almost immediately with an empty Launch.log: usually Steam's copy protection (CEG) rejecting"
  echo "  copied .exe files. Fix (once): run  \"$F/validate.sh\"  (or play.sh --validate)"
fi
if [ "$KEEP" = 0 ]; then echo "[$(ts)] Waiting 10 s for Steam to finish (cloud saves)..."; sleep 10
  shutdown_all && echo "[$(ts)] Steam closed; nothing left running."; fi
if [ -n "$CSV" ]; then pause 120; else pause 15; fi
exit 0
