#!/bin/bash
# xcom-mac-fix uninstaller: same as ./install.sh --uninstall (free mode) or ./install.sh --crossover --uninstall.
# Usage: ./uninstall.sh [--crossover] [--dir DIR] [--dry-run] [--yes]
# Free mode deletes the install folder (Wine, prefix with its Steam login and game copy) and the Desktop launchers
# it made. Never touches CrossOver, your bottle, or your saves/settings in ~/Documents/My Games.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh" --uninstall "$@"
