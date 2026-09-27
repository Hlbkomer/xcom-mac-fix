#!/bin/bash
# xcom-mac-fix — XCOM: Enemy Within on Apple Silicon Macs, fixed (NX fault storm, x87 under Rosetta, d3d9 freeze).
#
# FREE mode (default, no CrossOver needed): downloads athei's free Wine build (pinned sha256), Wine Mono and
# x87sidecar, creates a Wine prefix with Steam, lets you log in, brings in the game (APFS clone from a CrossOver
# bottle, or a normal Steam download), verifies it once, and adds play/stop launchers.
# CROSSOVER mode (--crossover): patches a clone of your own CrossOver's Wine instead (see README).
#
# Usage: ./install.sh [options]
#   --dir DIR            free mode install location (default: ~/Library/Application Support/xcom-mac-fix)
#   --game-from SRC      free mode game source: auto (default) | download | PATH
#                          auto:     clone it from a CrossOver bottle that has it, otherwise download via Steam
#                          download: install it with this Steam (about 20 GB)
#                          PATH:     a CrossOver bottle, a Steam folder or a Steam library folder that has it
#   --no-validate        skip the one-time "Verify integrity of game files" after cloning
#   --crossover          CrossOver mode instead of free mode
#   --bottle NAME        CrossOver bottle with Steam + XCOM (default: Steam; also the clone source in free mode)
#   --crossover-app PATH CrossOver.app location (CrossOver mode)
#   --bottles-dir DIR    CrossOver bottles directory (default: ~/Library/Application Support/CrossOver/Bottles)
#   --force              CrossOver mode: allow an unverified CrossOver version / unknown ntdll.dll
#   --dry-run            run every check, print every action, change nothing
#   --uninstall          remove what this installer created (use with --crossover for CrossOver mode)
#   --game-config        back up XComEngine.ini and set AmbientOcclusion=True (default: ask)
#   --no-game-config     skip the game-config step
#   --no-desktop         don't create the Desktop launchers
#   --yes                don't ask questions
#   -h, --help
#
# Copyright (c) 2026 Hlbkomer. MIT License (see LICENSE; third-party licences: LICENSE-NOTE.md). No warranty.
set -u
umask 022

VERSION="0.5.1"
STEAM_APPID="200510"                     # XCOM: Enemy Unknown (includes Enemy Within)
WINE_URL="https://github.com/athei/wine-build/releases/download/cx-26.3.0-6/wine-cx-26.3.0-6-macos-x86_64.tar.xz"
WINE_SHA="11cb278a82ba8c2e7563c02afd7fb369702ca193b0b3ebfc8db22e771900ce37"
MONO_URL="https://github.com/wine-mono/wine-mono/releases/download/wine-mono-10.4.1/wine-mono-10.4.1-x86.tar.xz"
MONO_SHA="a16606ef0724202e6a6848ece6e0cbba64d11e2f11aefe744af1d93c6d9f99bb"
SIDECAR_URL="https://github.com/athei/x87sidecar/releases/download/v1.7.0/x87sidecar.tar.xz"
SIDECAR_SHA="b768336e0ad556807156cecd533423285c8ec654f4fdb9c0623124d8b12c0865"
MTLD3D_URL="https://github.com/athei/mtld3d/releases/download/v0.11.0/mtld3d.tar.xz"   # d3d9 on Metal (zlib), --renderer=mtld3d
MTLD3D_SHA="c4535f3b4c62dcd880bb5062fdfac3fb74ffc9c316c7110ef444f46b1e324304"
MTLD3D_XCOM_SHA="03bee1a57ab20c30345501a2bc7aad9f4c8093e01e4e0c7c6b60a695cc48f7a1"
STEAM_URL="https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe"   # Valve updates it: not pinned
XCLICK_SHA="d0d616640daaaba9ff232c138f44f53535dca7681454895cc12c59bfe7c3ff7f"
FPSBAR_SHA="40c2ebae93cd07eb2fd7085391907f94823f63604b8a2c4d3ac248f05e127b97"   # freewine/bin/fpsbar, built from tools/fpsbar.m
MARKER="# xcom-mac-fix: generated file"
OLD_MARKER="# xcom-x87-fix: generated file"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DIR="$HOME/Library/Application Support/xcom-mac-fix"
GAME_FROM=auto; VALIDATE=1
BOTTLE="Steam"; CXAPP=""; BOTTLES_DIR="$HOME/Library/Application Support/CrossOver/Bottles"
DRY=0; MODE=install; FLAVOR=free; GAMECFG=ask; DESKTOP=1; FORCE=0; YES=0

# ---------- helpers (shared with crossover-mode.sh) ----------
say()  { printf '%s\n' "$*"; }
info() { printf '  - %s\n' "$*"; }
warn() { printf '  ! WARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
FAILS=0
check_fail() {  # in dry-run: record and continue; otherwise abort
  if [ "$DRY" = 1 ]; then printf '  X CHECK FAILED: %s\n' "$*" >&2; FAILS=$((FAILS+1)); else die "$*"; fi
}
# run CMD...: execute (or print in dry-run). Every change to disk goes through run/write_file.
run() {
  if [ "$DRY" = 1 ]; then printf '  [dry-run] would run:'; printf ' %q' "$@"; printf '\n'; return 0; fi
  "$@"
}
write_file() {  # write_file PATH MODE < content
  local path="$1" mode="$2" tmp
  if [ "$DRY" = 1 ]; then printf '  [dry-run] would write %s (%s bytes, mode %s)\n' "$path" "$(wc -c | tr -d ' ')" "$mode"; return 0; fi
  tmp="$path.tmp.$$"
  cat > "$tmp" || die "cannot write $tmp"
  if ! { chmod "$mode" "$tmp" && mv -f "$tmp" "$path"; }; then die "cannot install $path"; fi
}
ask_yes() { # ask_yes "question" -> 0 if yes
  [ "$YES" = 1 ] && return 1
  [ -t 0 ] || return 1
  local a; read -r -p "  ? $1 [y/N] " a; case "$a" in [yY]*) return 0;; *) return 1;; esac
}
usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
esc_re() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g'; }
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
# fetch URL FILE [SHA]: download (resumable, retried) and verify
fetch() {
  local url="$1" out="$2" want="${3:-}"
  if [ "$DRY" = 1 ]; then info "[dry-run] would download $url$([ -n "$want" ] && printf ' (sha256 %s…)' "${want:0:12}")"; return 0; fi
  if [ -n "$want" ] && [ -f "$out" ] && [ "$(sha256 "$out")" = "$want" ]; then info "already downloaded: $(basename "$out")"; return 0; fi
  curl -fL --retry 3 --connect-timeout 20 -C - -o "$out" "$url" || { rm -f "$out"; curl -fL --retry 3 --connect-timeout 20 -o "$out" "$url"; } \
    || die "download failed: $url"
  if [ -n "$want" ]; then
    [ "$(sha256 "$out")" = "$want" ] || { rm -f "$out"; die "sha256 mismatch for $(basename "$out") (expected $want); deleted it"; }
    info "sha256 verified: $(basename "$out")"
  fi
}
# Windows path in a Steam libraryfolders.vdf -> Mac path, through a bottle/prefix's dosdevices
win2mac() {  # win2mac BOTTLE_DIR 'D:\\Games\\Steam'
  local p drive rest target
  p="$(printf '%s' "$2" | sed 's/\\\\/\\/g')"
  drive="$(printf '%s' "${p%%:*}" | tr '[:upper:]' '[:lower:]')"; rest="${p#*:}"
  target="$1/dosdevices/$drive:"
  [ -e "$target" ] || return 1
  printf '%s%s' "$target" "$(printf '%s' "$rest" | tr '\134' '/')"
}
# find_game ROOT: print "<steamapps dir>|<game dir>" for app $STEAM_APPID under a bottle, Steam folder or library
find_game() {
  local root="$1" libs="" vdf wp m lib idir
  for lib in "$root" "$root/drive_c/Program Files (x86)/Steam" "$root/drive_c/Program Files/Steam"; do
    [ -d "$lib/steamapps" ] || continue
    libs="$libs
$lib"
    for vdf in "$lib/steamapps/libraryfolders.vdf" "$lib/config/libraryfolders.vdf"; do
      if [ ! -f "$vdf" ] || [ ! -d "$root/dosdevices" ]; then continue; fi
      while IFS= read -r wp; do
        [ -n "$wp" ] || continue
        m="$(win2mac "$root" "$wp")" && libs="$libs
$m"
      done <<EOT
$(sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$vdf")
EOT
    done
  done
  while IFS= read -r lib; do
    if [ -z "$lib" ] || [ ! -f "$lib/steamapps/appmanifest_$STEAM_APPID.acf" ]; then continue; fi
    idir="$(sed -n 's/^[[:space:]]*"installdir"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$lib/steamapps/appmanifest_$STEAM_APPID.acf" | head -1)"
    if [ -n "$idir" ] && [ -f "$lib/steamapps/common/$idir/XEW/Binaries/Win32/XComEW.exe" ]; then
      printf '%s|%s\n' "$lib/steamapps" "$lib/steamapps/common/$idir"; return 0
    fi
  done <<EOT
$libs
EOT
  return 1
}
ini_candidates() {  # XComEngine.ini locations to check, most likely first
  printf '%s\n' "$HOME/Documents/My Games/XCOM - Enemy Within/XComGame/Config/XComEngine.ini"
  local d; for d in "$@"; do
    for c in "$d"/drive_c/users/*/Documents/"My Games/XCOM - Enemy Within/XComGame/Config/XComEngine.ini"; do
      case "$c" in */users/Public/*) ;; *) [ -f "$c" ] && printf '%s\n' "$c";; esac
    done
  done
}
# game_config: optional XComEngine.ini backup + AmbientOcclusion=True (AO off crashed at mission start with built-in d3d9)
game_config() {  # game_config MANIFEST PREFIXDIR...
  local manifest="$1" INI="" c AO B; shift
  while IFS= read -r c; do [ -f "$c" ] && { INI="$c"; break; }; done <<EOT
$(ini_candidates "$@")
EOT
  if [ -z "$INI" ]; then info "XComEngine.ini not found yet (created at the first game start). If AmbientOcclusion is off later, turn it on in the game's graphics options."; return 0; fi
  AO="$(awk '/^\[/{s=($0 ~ /^\[SystemSettings\]/)} s && /^AmbientOcclusion=/{sub(/^AmbientOcclusion=/,""); print; exit}' "$INI" | tr -d '\r')"
  info "XComEngine.ini: AmbientOcclusion=${AO:-<missing>}"
  if [ "$AO" = True ]; then info "Ambient Occlusion is on (keep it on); nothing to change"; return 0; fi
  if [ "$GAMECFG" = ask ]; then
    if [ "$DRY" = 1 ]; then GAMECFG=no; info "[dry-run] would ask whether to back up XComEngine.ini and set AmbientOcclusion=True"
    elif ask_yes "Back up XComEngine.ini and set AmbientOcclusion=True (recommended)?"; then GAMECFG=yes; else GAMECFG=no; fi
  fi
  [ "$GAMECFG" = yes ] || return 0
  if [ "$AO" = True ]; then info "already True; nothing to change"; return 0; fi
  B="$INI.bak-xcom-mac-fix-$(date +%Y%m%d-%H%M%S)"
  run cp -p "$INI" "$B"
  run perl -pi -e 'if (/^\[/) { $s = /^\[SystemSettings\]\s*$/ } s/^AmbientOcclusion=.*/AmbientOcclusion=True/ if $s' "$INI"
  [ "$DRY" = 0 ] && printf 'ini_backup=%s\n' "$B" >> "$manifest"
  return 0
}
system_checks() {
  local MACOS MAJ
  MACOS="$(sw_vers -productVersion 2>/dev/null)"; MAJ="${MACOS%%.*}"
  info "macOS $MACOS"
  if [ -z "$MAJ" ] || [ "$MAJ" -lt 15 ]; then check_fail "macOS 15 or newer is required (pinned Wine deployment target; only macOS 27 tested)"; fi
  [ -n "$MAJ" ] && [ "$MAJ" -gt 27 ] && warn "macOS $MAJ is newer than tested (27). Apple said full Rosetta 2 remains through macOS 27; the x87 sidecar may not work."
  if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; then info "Apple Silicon: yes ($(sysctl -n machdep.cpu.brand_string 2>/dev/null))"
  else check_fail "Apple Silicon Mac required (this fixes Rosetta 2 behaviour)"; fi
  if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then info "Rosetta 2: installed"
  else check_fail "Rosetta 2 is not installed (run: softwareupdate --install-rosetta)"; fi
}

# ---------- args ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || die "--dir needs a path"; DIR="$2"; shift;;
    --dir=*) DIR="${1#--dir=}";;
    --game-from) [ $# -ge 2 ] || die "--game-from needs auto, download or a path"; GAME_FROM="$2"; shift;;
    --game-from=*) GAME_FROM="${1#--game-from=}";;
    --no-validate) VALIDATE=0;;
    --crossover) FLAVOR=crossover;;
    --crossover-app) [ $# -ge 2 ] || die "--crossover-app needs a path"; CXAPP="$2"; shift;;
    --crossover-app=*) CXAPP="${1#--crossover-app=}";;
    --bottle) [ $# -ge 2 ] || die "--bottle needs a name"; BOTTLE="$2"; shift;;
    --bottle=*) BOTTLE="${1#--bottle=}";;
    --bottles-dir) [ $# -ge 2 ] || die "--bottles-dir needs a path"; BOTTLES_DIR="$2"; shift;;
    --bottles-dir=*) BOTTLES_DIR="${1#--bottles-dir=}";;
    --dry-run|--check) DRY=1;;
    --uninstall) MODE=uninstall;;
    --game-config) GAMECFG=yes;;
    --no-game-config) GAMECFG=no;;
    --no-desktop) DESKTOP=0;;
    --force) FORCE=1;;
    --yes|-y) YES=1;;
    -h|--help) usage;;
    *) die "unknown option: $1 (see --help)";;
  esac
  shift
done
[ "$(uname -s)" = Darwin ] || die "this installer is for macOS"
[ "$(id -u)" != 0 ] || die "do not run this with sudo/root; it installs into your user account only"

if [ "$FLAVOR" = crossover ]; then
  # shellcheck source-path=SCRIPTDIR source=crossover-mode.sh
  . "$HERE/crossover-mode.sh"
  exit $?
fi
# shellcheck source-path=SCRIPTDIR source=free-mode.sh
. "$HERE/free-mode.sh"
