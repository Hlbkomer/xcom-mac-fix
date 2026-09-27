#!/bin/bash
# Start Steam alone in the free-Wine prefix (log in, library, updates), with the default game settings so
# play.sh can use it without a restart. Quit with Steam menu > Exit, or stop.sh.
# shellcheck source-path=SCRIPTDIR source=env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
other_running && { echo "Another Wine Steam (CrossOver) is running. Quit it first: only one Steam at a time."; exit 1; }
[ -n "$(steam_pids)" ] && { echo "Steam is already running."; exit 0; }
ws_running && shutdown_all >/dev/null
LOG="$F/logs/steam-$(date +%Y%m%d-%H%M%S).log"
steam_env 1 "$FPS_DEFAULT" wined3d "$OVERLAY_DEFAULT"
start_steam "$LOG" "$@"
echo "Steam starting (log: $LOG)"
