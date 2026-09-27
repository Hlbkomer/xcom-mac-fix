#!/bin/bash
# One-time fix for "the game quits about 2 seconds after starting": runs Steam's "Verify integrity of game files"
# for XCOM in this prefix. Needed after the game was copied/cloned from another install, because Steam's copy
# protection (CEG) rejects the copied .exe files until Steam re-fetches them. Only files in THIS prefix change.
# Usage: validate.sh [--keep-steam]
# shellcheck source-path=SCRIPTDIR source=env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
other_running && { echo "Another Wine Steam (CrossOver) is running. Quit it first: only one Steam at a time."; exit 1; }
STARTED=0
if [ -z "$(steam_pids)" ]; then
  ws_running && shutdown_all >/dev/null
  echo "Starting Steam..."
  steam_env 1 "$FPS_DEFAULT" wined3d "$OVERLAY_DEFAULT"
  start_steam "$F/logs/steam-$(date +%Y%m%d-%H%M%S).log"; STARTED=1
fi
echo "Waiting for Steam to be logged in..."
wait_steam_ready 1800; r=$?
[ "$r" = 1 ] && { echo "Steam exited before it was ready."; exit 1; }
[ "$r" = 2 ] && { echo "Steam was not logged in after 30 minutes."; exit 1; }
sleep 3
validate_game; r=$?
if [ "$STARTED" = 1 ] && [ "${1:-}" != --keep-steam ]; then shutdown_all >/dev/null && echo "Steam closed."; fi
exit "$r"
