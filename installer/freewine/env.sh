# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are used by the scripts that source this file
# Sourced by the other scripts: environment for the free-Wine XCOM setup (athei/wine-build cx-26.3.0-6).
# Everything lives in the folder this file is in; CrossOver is never used or touched.
F="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WINEPREFIX="$F/prefix" WINEARCH=win64 WINEMSYNC=1
export WINEDEBUG="${XCOM_WINEDEBUG:-fixme-all}"
# winemenubuilder: no Mac menu/Desktop shortcuts from Windows installers.
# steamerrorreporter: Steam.exe crashes on exit under Wine (CrossOver too); the reporter it then starts
# crashes in Wine's dbghelp (division by zero in the DWARF evaluator) and Wine shows a "Program Error" dialog.
export WINEDLLOVERRIDES="winemenubuilder.exe=d;steamerrorreporter64.exe=d;steamerrorreporter.exe=d"
export PATH="$F/wine/bin:$PATH"
unset ROSETTA_X87_PATH WINE_COMPATDB MTL_HUD_ENABLED MTL_HUD_LOG_ENABLED MTL_HUD_OPACITY XCOM_D3D XCOM_MTLHUD X87_LOGS SteamAppId SteamGameId XCOM_X87 XCOM_HUD XCOM_FPS XCOM_GAME_WINEDEBUG XCOM_OVERLAY
HUD_DEFAULT=1   # FPS box (bin/fpsbar) on by default; play.sh --no-hud hides it. Set to 0 to make it opt-in (--hud).
FPS_DEFAULT=1   # Wine's fps trace for the game + per-session CSV/summary; play.sh --no-fps turns both off.
FPS_DIR="$HOME/Library/Logs/xcom-mac-fix"   # fps-<mode>-<time>.csv and -summary.txt, shared with CrossOver mode
OVERLAY_DEFAULT=0   # Steam in-game overlay off by default (see steam_env); play.sh --overlay turns it on.
STEAM_EXE='C:\Program Files (x86)\Steam\Steam.exe'
APPID=200510
GAME_WIN='C:\Program Files (x86)\Steam\steamapps\common\XCom-Enemy-Unknown\XEW\Binaries\Win32\XComEW.exe'
GAME_UNIX="$WINEPREFIX/drive_c/Program Files (x86)/Steam/steamapps/common/XCom-Enemy-Unknown/XEW/Binaries/Win32"
STEAM_LOGS="$WINEPREFIX/drive_c/Program Files (x86)/Steam/logs"
LAUNCH_LOG="$HOME/Documents/My Games/XCOM - Enemy Within/XComGame/Logs/Launch.log"
_re() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g'; }
WS_PAT="$(_re "$F/wine/").*wineserver"          # this setup's wineserver
OTHER_WS_PAT='CrossOver\.app/Contents/SharedSupport/CrossOver/.*wineserver|/cxroot/.*wineserver'
SC_PAT="$(_re "$F/bin/x87sidecar")"
FB_PAT="$(_re "$F/bin/fpsbar")"
MH_PAT="$(_re "$F/mtlhud-fps.sh")"
mkdir -p "$F/logs"

ws_running()    { pgrep -f "$WS_PAT" >/dev/null 2>&1; }
other_running() { pgrep -f "$OTHER_WS_PAT" >/dev/null 2>&1; }
# processes whose executable image lives in this setup's wine tree (lsof txt), matching an awk regex on args
fw_pids() {
  local p
  for p in $(ps -axo pid=,stat=,args= | awk -v re="$1" 'tolower($0) ~ re && $2 !~ /Z/ && $0 !~ /awk/ {print $1}'); do
    lsof -a -p "$p" -d txt -Fn 2>/dev/null | grep -qF "$F/wine/" && echo "$p"
  done
}
game_pids()  { fw_pids '(xcomew|xcomgame|xcomlauncher)\.exe'; }
steam_pids() { fw_pids 'steam\.exe'; }
steam_ready() {  # Steam writes ActiveUser (non-zero) once an account is logged in, and 0 on exit
  local v
  v="$(wine reg query 'HKCU\Software\Valve\Steam\ActiveProcess' /v ActiveUser 2>/dev/null | awk '/ActiveUser/{print $NF}' | tr -d '\r')"
  [ -n "$v" ] && [ "$v" != 0x0 ] && [ "$v" != 0 ]
}
# Quit Steam cleanly, fall back to wineserver -k, then remove leftovers (sidecars). Returns 0 when nothing is left.
# Steam.exe under Wine crashes late in its own shutdown (CrossOver too); with the error reporter disabled its
# crash handler then hangs, so a new crash dump after -shutdown means: stop waiting and end the session.
shutdown_all() {
  local d="$WINEPREFIX/drive_c/Program Files (x86)/Steam/dumps" mark="$F/logs/.shutdown-mark"
  if [ -n "$(steam_pids)" ]; then
    echo "Closing Steam..."
    touch "$mark"
    wine "$STEAM_EXE" -shutdown >/dev/null 2>&1 &
    for _ in $(seq 1 30); do
      ws_running || break
      if [ -n "$(find "$d" -maxdepth 1 -name 'crash_*.dmp' -newer "$mark" 2>/dev/null | head -1)" ]; then sleep 2; break; fi
      sleep 1
    done
    rm -f "$mark"
  fi
  if ws_running; then
    wineserver -k >/dev/null 2>&1
    for _ in $(seq 1 10); do ws_running || break; sleep 1; done
  fi
  pkill -f "$SC_PAT" 2>/dev/null; pkill -f "$FB_PAT" 2>/dev/null; pkill -f "$MH_PAT" 2>/dev/null
  sleep 1
  if ws_running || pgrep -f "$SC_PAT" >/dev/null 2>&1; then
    pkill -9 -f "$WS_PAT" 2>/dev/null; pkill -9 -f "$SC_PAT" 2>/dev/null; sleep 1
  fi
  sweep_orphans
  find "$d" -maxdepth 1 -name 'crash_*.dmp' -size 0 -delete 2>/dev/null   # empty dumps from the exit crash
  rm -f "$SETTINGS_FILE" "$STEAMLOG_FILE"
  ! ws_running
}
# Wine processes of this setup that outlived their wineserver (e.g. when Steam hung while quitting and the
# wineserver had to be killed). They spin at full CPU and write "server_register_wait" errors to the Steam
# log at several MB per second, so they are killed. Only processes whose executable is in $F/wine/.
sweep_orphans() {
  local o
  ws_running && return 0
  o="$(fw_pids '[.]exe|wineserver|/wine/' | tr '\n' ' ')"
  [ -n "${o// /}" ] || return 0
  echo "Removing leftover Wine processes of this setup (pids $o)"
  # shellcheck disable=SC2086
  kill -9 $o 2>/dev/null; sleep 1
}
# Settings Steam is started with. They are inherited down to the game; bin/x87filter applies the sidecar,
# FPS trace and debug channels to XComEW.exe only, and the WINE_COMPATDB rule matches only XComEW.exe.
# Overlay off: Steam's in-game overlay is loaded into the game (gameoverlayrenderer) and Steam starts
# gameoverlayui64.exe 7 times per game start under this Wine (6 of them exit at once). One test run closed
# itself 0.15 s after the 7th overlay process exited; the overlay is disabled by default so nothing of it runs.
# D3D: mtld3d = athei's d3d9 on Metal (default for XCOM, --renderer=gl falls back to wined3d on OpenGL).
# With mtld3d, Wine's +fps trace does not exist, so the game gets Apple's Metal HUD logging instead
# (XCOM_MTLHUD, applied by bin/x87filter to XComEW.exe only).
# steam_env X87(0/1) FPS(0/1) D3D(wined3d|mtld3d) OVERLAY(0/1) [DEBUG]
steam_env() {
  export ROSETTA_X87_PATH="$F/bin/x87filter" XCOM_X87="$1" XCOM_FPS="$2" XCOM_OVERLAY="$4" XCOM_D3D="$3"
  if [ "$3" = wined3d ]; then export WINE_COMPATDB=$'v=3\nname=xcom-ew-wined3d;exe=XComEW.exe;d3d9=wined3d'
  else unset WINE_COMPATDB; fi
  if [ "$3" = mtld3d ] && [ "$2" = 1 ]; then export XCOM_MTLHUD=1; else unset XCOM_MTLHUD; fi
  [ "$4" = 1 ] || export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;gameoverlayrenderer=d;gameoverlayrenderer64=d;gameoverlayui.exe=d;gameoverlayui64.exe=d"
  if [ -n "${5:-}" ]; then export XCOM_GAME_WINEDEBUG="$5"; else unset XCOM_GAME_WINEDEBUG; fi
}
settings_sig() { printf 'x87=%s fps=%s d3d=%s ovl=%s dbg=%s' "$1" "$2" "$3" "$4" "${5:-}"; }
SETTINGS_FILE="$F/logs/.steam-settings"      # settings the running Steam was started with
STEAMLOG_FILE="$F/logs/.steam-log"           # log file of the running Steam (the game's output goes there too)
start_steam() {  # start_steam LOGFILE [steam args...]: current environment is inherited
  local log="$1"; shift
  settings_sig "${XCOM_X87:-}" "${XCOM_FPS:-}" "${XCOM_D3D:-}" "${XCOM_OVERLAY:-}" "${XCOM_GAME_WINEDEBUG:-}" > "$SETTINGS_FILE"
  printf '%s\n' "$log" > "$STEAMLOG_FILE"
  ( cd "$F" && nohup wine "$STEAM_EXE" "$@" > "$log" 2>&1 & )
}
# wait_steam_ready [TIMEOUT_S]: 0 = an account is logged in, 1 = the Wine session ended, 2 = timeout
wait_steam_ready() {
  local t=0
  until steam_ready; do
    if ! ws_running; then sleep 3; ws_running || return 1; fi
    [ "$t" = 45 ] && echo "  If Steam asks you to log in, do it now (tick 'Remember me'); this continues as soon as you are logged in."
    [ "$t" -ge "${1:-900}" ] && return 2
    sleep 3; t=$((t+3))
  done
}
# validate_game: Steam's "Verify integrity of game files" (steam://validate). Needed once after copying/cloning
# the game from another install: the copy-protected (CEG) .exe files are rejected until Steam re-fetches them.
validate_game() {
  local c="$STEAM_LOGS/content_log.txt" off t=0
  off=$(( $(wc -c < "$c" 2>/dev/null || echo 0) + 1 ))
  echo "[$(date '+%H:%M:%S')] Verifying game files (Steam re-fetches the copy-protected .exe files if needed; ~1-3 min)..."
  wine "$STEAM_EXE" "steam://validate/$APPID" >/dev/null 2>&1 &
  until tail -c +"$off" "$c" 2>/dev/null | grep -a -q "AppID $APPID scheduler finished"; do
    sleep 5; t=$((t+5)); [ "$t" -ge 1800 ] && { echo "  Verification did not finish in 30 minutes."; return 1; }
  done
  tail -c +"$off" "$c" | grep -a -E 'Validation: full scan|scheduler finished' | sed 's/^/  /' | cut -c1-160
  echo "  (Steam may show a note that some files 'failed to validate and will be reacquired': that is expected.)"
  sleep 3
}
rotate_logs() { local pat f; for pat in play game steam fpsbar mtlhud; do
  find "$F/logs" -maxdepth 1 -name "$pat-*.log" | sort -r | tail -n +11 | while IFS= read -r f; do rm -f "$f"; done; done; }
