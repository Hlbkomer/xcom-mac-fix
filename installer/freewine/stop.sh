#!/bin/bash
# Stop XCOM on the free-Wine setup, then close Steam (clean -shutdown, falling back to wineserver -k),
# so nothing is left running. Never touches CrossOver.
# Usage: stop.sh [--game-only]   (--game-only: stop just the game, keep Steam running)
# shellcheck source-path=SCRIPTDIR source=env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
ONLY=0; [ "${1:-}" = "--game-only" ] && ONLY=1
read -r -a P <<< "$(game_pids | tr '\n' ' ')"
if [ "${#P[@]}" -gt 0 ]; then
  echo "Closing XCOM (pids ${P[*]})..."
  wine taskkill /im XComEW.exe >/dev/null 2>&1   # like closing the window: the game shuts down normally
  for _ in $(seq 1 20); do [ -z "$(game_pids)" ] && break; sleep 1; done
  read -r -a P <<< "$(game_pids | tr '\n' ' ')"
  [ "${#P[@]}" -gt 0 ] && { echo "Not closing; stopping it."; kill -TERM "${P[@]}" 2>/dev/null; sleep 3; }
  read -r -a P <<< "$(game_pids | tr '\n' ' ')"
  [ "${#P[@]}" -gt 0 ] && { kill -KILL "${P[@]}" 2>/dev/null; sleep 1; }
  pkill -f "$SC_PAT.*[Xx][Cc][Oo][Mm]" 2>/dev/null; pkill -f "$FB_PAT" 2>/dev/null
  read -r -a P <<< "$(game_pids | tr '\n' ' ')"
  [ "${#P[@]}" -gt 0 ] && echo "Could not stop: ${P[*]}" || echo "XCOM stopped."
else echo "XCOM is not running."; fi
if [ "$ONLY" = 0 ]; then
  if ws_running || pgrep -f "$SC_PAT" >/dev/null 2>&1; then shutdown_all && echo "Steam closed; nothing left running."
  else sweep_orphans; echo "Steam is not running."; fi
fi
[ -t 0 ] && [ -t 1 ] && [ -z "${NOWAIT:-}" ] && read -r -t 10 -p "Done (closes in 10 s)." _
exit 0
