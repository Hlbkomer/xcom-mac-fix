# shellcheck shell=bash
# shellcheck disable=SC2154  # helpers and option variables come from install.sh
# CrossOver mode of xcom-mac-fix (./install.sh --crossover ...). Sourced by install.sh; not run directly.
# Patches an APFS clone of YOUR CrossOver's Wine (1-byte NX fix), builds athei/x87sidecar from a pinned commit,
# and routes only XComEW.exe through it. CrossOver.app and your bottle are never modified.
PIN_REPO="https://github.com/athei/x87sidecar.git"
PIN_COMMIT="4048fcf436876f26c799ba2fa340ec73f4cca95e"      # = x87sidecar v1.7.0
VERIFIED_CX_VERSIONS="26.0"              # CrossOver short versions this was tested on
# sha256 of lib/wine/i386-windows/ntdll.dll: "<stock sha> <patched sha> <label>"
KNOWN_NTDLL="b8e3de7bf9820239a0f9f7bb1b0623fa8b3df1b2efe4ce530905c96c0e85ae3b e0026730cae9aa9cfb20b20531a81875b08eba54d6bedb22adf6d0700ab3c59a CrossOver-26.0.0.39794"
PREFIX="$HOME/Library/Application Support/xcom-x87-fix"
DESK_PLAY="$HOME/Desktop/XCOM Enemy Within (CrossOver fix).command"
DESK_KILL="$HOME/Desktop/XCOM (CrossOver fix) - stop.command"
case "$BOTTLE" in ""|*/*|.|..) die "invalid bottle name: '$BOTTLE'";; esac
MANIFEST="$PREFIX/install.manifest"
CXROOT="$PREFIX/cxroot"
WS_PAT="$(esc_re "$CXROOT/").*wineserver"
CX_WS_PAT='CrossOver\.app/Contents/SharedSupport/CrossOver/.*wineserver'

say "xcom-mac-fix $VERSION — CrossOver mode: $MODE$([ "$DRY" = 1 ] && echo ' (DRY RUN: nothing will be changed)')"

# ---------- uninstall ----------
if [ "$MODE" = uninstall ]; then
  [ -d "$PREFIX" ] || { say "Nothing installed at $PREFIX."; exit 0; }
  [ -f "$MANIFEST" ] || die "$PREFIX exists but has no install.manifest; not removing it automatically. Inspect and delete it by hand if it is yours."
  if pgrep -f "$WS_PAT" >/dev/null 2>&1; then
    check_fail "Steam/XCOM is still running from the fixed copy. Quit Steam (Steam menu > Exit) first."
  fi
  say "Removing:"
  while IFS='=' read -r k v; do
    case "$k" in
      desktop)
        if [ -f "$v" ] && grep -qF -e "$MARKER" -e "$OLD_MARKER" "$v"; then info "$v"; run rm -f "$v"
        elif [ -e "$v" ]; then warn "not removing $v (it was changed, no marker)"; fi;;
      ini_backup) [ -n "$v" ] && say "  Note: XComEngine.ini is left as it is. Your pre-install copy: $v";;
    esac
  done < "$MANIFEST"
  case "$PREFIX" in */xcom-x87-fix) info "$PREFIX (clone, sidecar source/binary, launchers, logs)"; run rm -rf "$PREFIX";;
    *) die "refusing to delete unexpected path $PREFIX";; esac
  say "Done. CrossOver.app and your bottle were never modified by this installer."
  exit 0
fi

# ---------- preflight ----------
say ""; say "[1/8] System checks"
MACOS="$(sw_vers -productVersion 2>/dev/null)"; MAJ="${MACOS%%.*}"
info "macOS $MACOS"
if [ -z "$MAJ" ] || [ "$MAJ" -lt 14 ]; then check_fail "macOS 14 or newer is required (x87sidecar deployment target)"; fi
[ -n "$MAJ" ] && [ "$MAJ" -gt 27 ] && warn "macOS $MAJ is newer than tested (27). Apple said full Rosetta 2 remains through macOS 27; the x87 sidecar may not work."
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; then info "Apple Silicon: yes ($(sysctl -n machdep.cpu.brand_string 2>/dev/null))"
else check_fail "Apple Silicon Mac required (this fixes Rosetta 2 behaviour)"; fi
if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then info "Rosetta 2: installed"
else check_fail "Rosetta 2 is not installed (run: softwareupdate --install-rosetta)"; fi

say ""; say "[2/8] CrossOver"
if [ -z "$CXAPP" ]; then
  for c in "/Applications/CrossOver.app" "$HOME/Applications/CrossOver.app"; do [ -d "$c" ] && { CXAPP="$c"; break; }; done
fi
if [ -z "$CXAPP" ] || [ ! -d "$CXAPP" ]; then die "CrossOver.app not found (use --crossover-app /path/to/CrossOver.app)"; fi
CXSRC="$CXAPP/Contents/SharedSupport/CrossOver"
CXVER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$CXAPP/Contents/Info.plist" 2>/dev/null)"
CXBUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$CXAPP/Contents/Info.plist" 2>/dev/null)"
info "CrossOver $CXVER ($CXBUILD) at $CXAPP"
NTDLL_REL="lib/wine/i386-windows/ntdll.dll"
LOADER_REL="lib/wine/x86_64-unix/wine"
for f in bin/wine bin/wineserver "$NTDLL_REL" "$LOADER_REL"; do [ -e "$CXSRC/$f" ] || die "unexpected CrossOver layout: $CXSRC/$f missing"; done
file -b "$CXSRC/$LOADER_REL" | grep -q 'Mach-O' || die "$CXSRC/$LOADER_REL is not a Mach-O loader (unexpected CrossOver layout)"
case " $VERIFIED_CX_VERSIONS " in
  *" $CXVER "*) info "version verified";;
  *) if [ "$FORCE" = 1 ]; then warn "CrossOver $CXVER is not verified (tested: $VERIFIED_CX_VERSIONS); continuing because of --force"
     else check_fail "CrossOver $CXVER is not verified (tested: $VERIFIED_CX_VERSIONS). Re-run with --force to try anyway."; fi;;
esac
if pgrep -f "$CX_WS_PAT" >/dev/null 2>&1; then
  check_fail "CrossOver's Wine is running. Quit all CrossOver apps (Steam menu > Exit) and try again."
else info "CrossOver's Wine: not running"; fi
df -P "$HOME" | awk 'NR==2{exit !($4 > 2*1024*1024)}' || warn "less than ~2 GB free; the clone is cheap on APFS but the sidecar build needs some space"

say ""; say "[3/8] Bottle '$BOTTLE' and XCOM"
BDIR="$BOTTLES_DIR/$BOTTLE"
[ -f "$BDIR/cxbottle.conf" ] || die "bottle not found: $BDIR (use --bottle NAME / --bottles-dir DIR)"
ARCH="$(awk -F'"' '/^"WineArch"/{print $4; exit}' "$BDIR/cxbottle.conf")"
[ -z "$ARCH" ] && ARCH="$(sed -n 's/^#arch=//p' "$BDIR/system.reg" 2>/dev/null | head -1)"
if [ "$ARCH" = win64 ]; then info "bottle arch: win64"; else check_fail "bottle '$BOTTLE' is '$ARCH', a win64 bottle is required"; fi
STEAM_DIR=""; STEAM_WIN=""
for rel in "Program Files (x86)/Steam" "Program Files/Steam"; do
  if [ -f "$BDIR/drive_c/$rel/steam.exe" ]; then STEAM_DIR="$BDIR/drive_c/$rel"; STEAM_WIN="C:\\$(printf '%s' "$rel" | tr '/' '\134')\\steam.exe"; break; fi
done
[ -n "$STEAM_DIR" ] || die "steam.exe not found in bottle '$BOTTLE'"
info "Steam: $STEAM_WIN"
# Steam libraries from libraryfolders.vdf ("path" "D:\\Games\\Steam"), mapped through the bottle's dosdevices
win2mac() {
  local p drive rest target
  p="$(printf '%s' "$1" | sed 's/\\\\/\\/g')"          # unescape \\ -> \
  drive="$(printf '%s' "${p%%:*}" | tr '[:upper:]' '[:lower:]')"; rest="${p#*:}"
  target="$BDIR/dosdevices/$drive:"
  [ -e "$target" ] || return 1
  printf '%s%s' "$target" "$(printf '%s' "$rest" | tr '\134' '/')"
}
LIBS=""
for vdf in "$STEAM_DIR/steamapps/libraryfolders.vdf" "$STEAM_DIR/config/libraryfolders.vdf"; do
  [ -f "$vdf" ] || continue
  while IFS= read -r wp; do
    m="$(win2mac "$wp")" || continue
    case "
$LIBS
" in *"
$m
"*) ;; *) LIBS="$LIBS
$m";; esac
  done <<EOF
$(sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$vdf")
EOF
done
LIBS="$LIBS
$STEAM_DIR"
GAME_DIR=""
while IFS= read -r lib; do
  if [ -z "$lib" ] || [ ! -f "$lib/steamapps/appmanifest_$STEAM_APPID.acf" ]; then continue; fi
  idir="$(sed -n 's/^[[:space:]]*"installdir"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$lib/steamapps/appmanifest_$STEAM_APPID.acf" | head -1)"
  [ -n "$idir" ] && [ -d "$lib/steamapps/common/$idir" ] && { GAME_DIR="$lib/steamapps/common/$idir"; break; }
done <<EOF
$LIBS
EOF
if [ -n "$GAME_DIR" ] && [ -f "$GAME_DIR/XEW/Binaries/Win32/XComEW.exe" ]; then
  info "XCOM: Enemy Within found: $GAME_DIR/XEW/Binaries/Win32/XComEW.exe"
else check_fail "XCOM (app $STEAM_APPID) with Enemy Within (XEW/Binaries/Win32/XComEW.exe) not found in this bottle's Steam libraries"; fi

say ""; say "[4/8] Build tools and NX patch site"
for t in git cmake clang perl codesign shasum; do command -v "$t" >/dev/null 2>&1 || check_fail "'$t' not found (install Xcode Command Line Tools: xcode-select --install; cmake: https://cmake.org or Homebrew)"; done
if command -v cmake >/dev/null 2>&1; then
  CMV="$(cmake --version | awk 'NR==1{print $3}')"; info "cmake $CMV"
  printf '%s\n3.27\n' "$CMV" | sort -t. -k1,1n -k2,2n -k3,3n | head -1 | grep -qx '3.27' || check_fail "cmake >= 3.27 required (found $CMV)"
fi
SRC_SHA="$(sha256 "$CXSRC/$NTDLL_REL")"
EXPECT_PATCHED=""
while read -r k_stock k_patched k_label; do
  [ -n "$k_stock" ] || continue
  if [ "$SRC_SHA" = "$k_stock" ]; then EXPECT_PATCHED="$k_patched"; info "ntdll.dll sha256 known: $k_label"; fi
done <<EOF
$KNOWN_NTDLL
EOF
if [ -z "$EXPECT_PATCHED" ]; then
  if [ "$FORCE" = 1 ]; then warn "unknown ntdll.dll (sha256 $SRC_SHA); relying on the pattern match because of --force"
  else check_fail "unknown ntdll.dll (sha256 $SRC_SHA). Re-run with --force to rely on the pattern match alone."; fi
fi
# Pattern (32-bit Wine ntdll, alloc_module()):
#   F6 /0 modrm(disp8) 5F 01   test byte [reg+0x5f],1   ; high byte of DllCharacteristics: NX_COMPAT (0x100)
#   75 xx                      jne  keep_nx             ; <- patched to EB (jmp): never disable no-exec
#   C7 45 xx 02 00 00 00       mov  [ebp-x],2           ; flags = MEM_EXECUTE_OPTION_ENABLE (or C7 44 24 xx for esp)
# plus, within the next 64 bytes, the ProcessExecuteFlags (0x22) argument to NtSetInformationProcess.
# Prints "<count> <offset-of-jcc> <already_patched 0/1>".
nx_scan() {
  perl -e '
    local $/; open(my $f, "<:raw", $ARGV[0]) or die "open: $!"; my $d = <$f>; close $f;
    my @hits;
    while ($d =~ /\xF6[\x40-\x43\x45-\x47]\x5F\x01([\x75\xEB])[\x00-\x7F](?:\xC7\x45.|\xC7\x44\x24.)\x02\x00\x00\x00/gs) {
      my $s = $-[0]; my $j = $1; my $w = substr($d, $s, 80);
      next unless $w =~ /(?:\xC7\x44\x24\x04\x22\x00\x00\x00|\x6A\x22)/s;
      push @hits, [$s + 4, ($j eq "\xEB") ? 1 : 0];
      pos($d) = $s + 1;
    }
    printf "%d %d %d\n", scalar(@hits), (@hits ? $hits[0][0] : -1), (@hits ? $hits[0][1] : 0);
  ' "$1"
}
read -r NX_N NX_OFF NX_DONE <<EOF
$(nx_scan "$CXSRC/$NTDLL_REL")
EOF
if [ "$NX_N" = 1 ] && [ "$NX_DONE" = 0 ]; then info "NX decision site: exactly 1 match, jne at file offset $(printf '0x%x' "$NX_OFF")"
elif [ "$NX_N" = 1 ]; then check_fail "CrossOver's own ntdll.dll already looks patched; refusing (reinstall CrossOver to get a clean file)"
else check_fail "NX pattern matched $NX_N times in ntdll.dll (need exactly 1); refusing to patch"; fi

for f in bin/fpsbar bin/xclick.exe fps-summary.sh compare-fps.sh; do
  [ -f "$HERE/freewine/$f" ] || check_fail "freewine/$f is missing from the installer folder"
done
if [ -f "$HERE/freewine/bin/fpsbar" ] && [ "$(sha256 "$HERE/freewine/bin/fpsbar")" != "$FPSBAR_SHA" ]; then check_fail "freewine/bin/fpsbar does not match its pinned sha256"; fi
if [ -f "$HERE/freewine/bin/xclick.exe" ] && [ "$(sha256 "$HERE/freewine/bin/xclick.exe")" != "$XCLICK_SHA" ]; then check_fail "freewine/bin/xclick.exe does not match its pinned sha256"; fi

say ""; say "[5/8] Existing install"
if [ -e "$PREFIX" ]; then
  check_fail "$PREFIX already exists. Run './install.sh --crossover --uninstall' first (it keeps your game and bottle)."
else info "install location: $PREFIX (free)"; fi
if [ "$DESKTOP" = 1 ]; then
  for f in "$DESK_PLAY" "$DESK_KILL"; do
    if [ -e "$f" ] && ! grep -qF -e "$MARKER" -e "$OLD_MARKER" "$f" 2>/dev/null; then check_fail "$f exists and was not created by this installer (use --no-desktop or move it)"; fi
  done
fi
if [ "$DRY" = 1 ] && [ "$FAILS" -gt 0 ]; then
  say ""; say "Dry run: $FAILS check(s) failed; a real install would stop at the first one. Planned actions follow anyway:"
fi

# ---------- install ----------
say ""; say "[6/8] Clone CrossOver's Wine and patch it"
run mkdir -p "$PREFIX/bin" "$PREFIX/src" "$PREFIX/logs"
if [ "$DRY" = 0 ]; then
  printf 'mode=crossover\nversion=%s\ndate=%s\ncrossover=%s %s\nbottle=%s\nbottles_dir=%s\n' "$VERSION" "$(date '+%F %T')" "$CXVER" "$CXBUILD" "$BOTTLE" "$BOTTLES_DIR" > "$MANIFEST"
else info "[dry-run] would write $MANIFEST"; fi
info "APFS clone (copy-on-write; uses almost no extra space): $CXSRC -> $CXROOT"
run cp -c -R -p "$CXSRC" "$CXROOT" || die "APFS clone failed (is your home folder on APFS?). Nothing inside CrossOver.app was touched."
N="$CXROOT/$NTDLL_REL"
run cp -p "$N" "$N.orig"
info "patch 1 byte at $(printf '0x%x' "$NX_OFF"): 75 (jne) -> EB (jmp) = no-exec stays on for the whole process"
if [ "$DRY" = 0 ]; then
  perl -e 'open(my $f, "+<:raw", $ARGV[0]) or die "open: $!"; seek($f,$ARGV[1],0); read($f,my $b,1); die "unexpected byte\n" unless $b eq "\x75"; seek($f,$ARGV[1],0); print $f "\xEB"; close $f or die;' "$N" "$NX_OFF" || die "patch failed"
  read -r c o d <<EOF
$(nx_scan "$N")
EOF
  if [ "$c" != 1 ] || [ "$d" != 1 ] || [ "$o" != "$NX_OFF" ]; then die "patch verification failed"; fi
  if [ -n "$EXPECT_PATCHED" ]; then [ "$(sha256 "$N")" = "$EXPECT_PATCHED" ] || die "patched ntdll.dll hash mismatch"; info "patched hash verified"; fi
fi

say ""; say "[7/8] Build athei/x87sidecar @ $PIN_COMMIT"
S="$PREFIX/src/x87sidecar"
run git clone --quiet "$PIN_REPO" "$S" || die "git clone failed"
run git -C "$S" -c advice.detachedHead=false checkout --quiet "$PIN_COMMIT" || die "pinned commit not found"
if [ "$DRY" = 0 ]; then
  [ "$(git -C "$S" rev-parse HEAD)" = "$PIN_COMMIT" ] || die "checked-out commit is not $PIN_COMMIT"
  info "commit verified: $(git -C "$S" log -1 --format='%h %ci %s')"
fi
run cmake -S "$S" -B "$S/build" -DCMAKE_BUILD_TYPE=Release || die "cmake configure failed"
# target x87sidecar only; its POST_BUILD step ad-hoc signs x87sidecar_entitled with rosetta_loader/entitlements.plist
# (com.apple.security.cs.debugger + get-task-allow)
run cmake --build "$S/build" --target x87sidecar -j "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" || die "build failed"
run cp -p "$S/build/bin/x87sidecar_entitled" "$PREFIX/bin/x87sidecar_entitled"
if [ "$DRY" = 0 ]; then
  codesign -d --entitlements - --xml "$PREFIX/bin/x87sidecar_entitled" 2>/dev/null | grep -q 'com.apple.security.cs.debugger' || die "x87sidecar_entitled lacks its entitlements"
  "$PREFIX/bin/x87sidecar_entitled" --probe > "$PREFIX/logs/probe.log" 2>&1
  grep -qx 'supported' "$PREFIX/logs/probe.log" || { cat "$PREFIX/logs/probe.log"; die "x87sidecar --probe: this Rosetta version is not supported"; }
  info "x87sidecar --probe: supported"
else info "[dry-run] would run: x87sidecar_entitled --probe (must print 'supported')"; fi

say ""; say "[8/8] Wrapper loader, launchers, game config"
L="$CXROOT/$LOADER_REL"
REAL="$L.x87real"
ENT="$PREFIX/src/loader-entitlements.plist"
info "keep CrossOver's loader as $REAL, re-sign it ad-hoc with its own entitlements + get-task-allow (needed for the sidecar to attach)"
run mv "$L" "$REAL"
if [ "$DRY" = 0 ]; then
  codesign -d --entitlements - --xml "$REAL" > "$ENT" 2>/dev/null
  [ -s "$ENT" ] || printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict/></plist>\n' > "$ENT"
  /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$ENT" >/dev/null 2>&1
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.get-task-allow bool true' "$ENT" || die "cannot edit entitlements"
else info "[dry-run] would extract the loader's entitlements to $ENT and add com.apple.security.get-task-allow"; fi
run codesign --force --sign - --options runtime --entitlements "$ENT" "$REAL" || die "re-signing the cloned loader failed"

{ printf '#!/bin/bash\n%s (wrapper loader)\n' "$MARKER"
  printf '# CrossOver execs this file for every new Wine process. Only XComEW.exe goes through x87sidecar.\n'
  printf 'REAL=%q\nSC=%q\nL=%q\n' "$REAL" "$PREFIX/bin/x87sidecar_entitled" "$PREFIX/logs"
  cat <<'EOF'
shopt -s nocasematch
PAT="${X87_MATCH:-XComEW.exe}"
if [[ "$*" == *"$PAT"* && "$*" != *winewrapper.exe* ]]; then
  GL="$L/game-$(date +%Y%m%d-%H%M%S).log"
  echo "$(date '+%F %T') pid $$ $([ -n "${X87_OFF:-}" ] && echo 'no-x87' || echo 'x87') log=$GL" >> "$L/wrapper.log"
  [ -n "${X87_XCOM_DEBUG:-}" ] && export WINEDEBUG="$X87_XCOM_DEBUG"
  [ "${X87_FPS:-0}" = 1 ] && export WINEDEBUG="${WINEDEBUG:+$WINEDEBUG,}+fps"   # fps trace for bin/fpsbar
  printf '%s\n' "$GL" > "$L/.last-game-log"
  exec >> "$GL" 2>&1
  if [[ -z "${X87_OFF:-}" && -x "$SC" ]]; then
    [ -z "${X87_QUIET:-}" ] && export X87_LOGS=1
    exec "$SC" "$REAL" "$@"
  fi
  exec "$REAL" "$@"
fi
exec "$REAL" "$@"
EOF
} | write_file "$L" 755

{ printf '#!/bin/bash\n%s (play launcher)\n' "$MARKER"
  printf 'PREFIX=%q\nBOTTLES=%q\nBOTTLE=%q\nSTEAM_WIN=%q\nAPPID=%q\nROOT=%q\n' \
    "$PREFIX" "$BOTTLES_DIR" "$BOTTLE" "$STEAM_WIN" "$STEAM_APPID" "$CXROOT/"
  cat <<'EOF'
# XCOM: Enemy Within with x87sidecar + NX patch + CrossOver built-in d3d9 (this session only).
# Options: --no-hud (no FPS box)  --no-fps (no fps trace, box or log)  --no-x87 (without the sidecar)
#          --launcher (don't press Enemy Within automatically)  --debug=CHANNELS (WINEDEBUG for the game only)
# Every session writes ~/Library/Logs/xcom-mac-fix/fps-crossover-<time>.csv and prints an FPS summary when the
# game exits (compare with free mode: compare-fps.sh in this folder).
HUD=1; FPS=1; NOX87=0; AUTO=1; DBG=""
for a in "$@"; do case "$a" in
  --no-hud) HUD=0;; --hud) HUD=1;; --no-fps) FPS=0; HUD=0;; --fps) FPS=1;; --no-x87) NOX87=1;; --launcher) AUTO=0;;
  --debug=*) DBG="${a#--debug=}";;
  -h|--help) sed -n '10,14p' "$0"; exit 0;; *) echo "unknown option: $a"; exit 2;; esac; done
CXW="$PREFIX/cxroot/bin/wine"; L="$PREFIX/logs"; B="$PREFIX/bin"; FPS_DIR="$HOME/Library/Logs/xcom-mac-fix"
fail()  { echo "$1"; [ -t 0 ] && read -r -p "Press Enter to close." _; exit 1; }
pause() { [ -t 0 ] && read -r -t "$1" -p "(this window closes in $1 s)" _; echo; }
ts()    { date '+%H:%M:%S'; }
# shellcheck disable=SC2009
servers() { ps -axo comm= | grep -E '(^|/)wineserver$'; }   # by executable path: a shell/editor whose arguments mention it never counts
own_ws()  { servers | grep -qF "$ROOT"; }
xcom_running() {  # any XComEW.exe process that is not just a shell or text tool mentioning the name
  local p c
  for p in $(ps -axo pid=,args= | awk 'tolower($0) ~ /xcomew\.exe/ {print $1}'); do
    c=$(ps -o comm= -p "$p" 2>/dev/null)
    case "${c##*/}" in ""|*sh|grep|pgrep|awk|sed|tail|less|more|vi|vim|nano|cat|osascript|ps) ;; *) return 0;; esac
  done; return 1; }
game_pid() {  # the game process of THIS copy (its executable is in the clone), not CrossOver's own
  local p
  for p in $(ps -axo pid=,stat=,args= | awk 'tolower($0) ~ /xcomew\.exe/ && $2 !~ /Z/ && $0 !~ /awk/ {print $1}'); do
    lsof -a -p "$p" -d txt -Fn 2>/dev/null | grep -qF "$ROOT" && { echo "$p"; return 0; }
  done; return 1; }
if [ ! -x "$CXW" ] || [ ! -x "$B/x87sidecar_entitled" ]; then fail "xcom-x87-fix is incomplete; re-run the installer."; fi
servers | grep -vF "$ROOT" | grep -q . && fail "Another Wine is running (Steam in CrossOver itself, or the free-mode XCOM setup). Quit that Steam first (Steam menu > Exit, or its stop launcher): only one Steam at a time."
xcom_running && fail "XCOM is already running (use 'XCOM (CrossOver fix) - stop' if it is stuck)."
export CX_BOTTLE_PATH="$BOTTLES"
if own_ws; then   # settings are inherited from Steam: restart it so they apply
  echo "Restarting Steam (fixed copy) so the settings apply, ~20 s..."
  "$CXW" --bottle "$BOTTLE" --no-update "$STEAM_WIN" -shutdown >/dev/null 2>&1
  for _ in $(seq 1 45); do own_ws || break; sleep 2; done
  own_ws && fail "Steam did not exit; quit it (Steam menu > Exit) and try again."
fi
unset X87_OFF X87_XCOM_DEBUG X87_LOGS X87_FPS MTL_HUD_ENABLED
export X87_QUIET=1
[ "$NOX87" = 1 ] && export X87_OFF=1
[ "$FPS" = 1 ] && export X87_FPS=1
[ -n "$DBG" ] && export X87_XCOM_DEBUG="$DBG"
mkdir -p "$L"
for pat in play game xclick fpsbar; do find "$L" -maxdepth 1 -name "$pat-*.log" | sort -r | tail -n +11 | while IFS= read -r f; do rm -f "$f"; done; done   # keep last 10
STAMP="$(date +%Y%m%d-%H%M%S)"; LOG="$L/play-$STAMP.log"; rm -f "$L/.last-game-log"
onoff() { if [ "$1" = 1 ]; then echo on; else echo off; fi; }
echo "Starting Steam in bottle '$BOTTLE' (x87 sidecar $([ "$NOX87" = 1 ] && echo OFF || echo ON), built-in d3d9, FPS box $(onoff "$HUD"), FPS log $(onoff "$FPS"))."
nohup "$CXW" --bottle "$BOTTLE" --no-update --no-wait --dll d3d9=b "$STEAM_WIN" -applaunch "$APPID" >"$LOG" 2>&1 &
if [ "$AUTO" = 1 ] && [ -f "$B/xclick.exe" ]; then
  ( "$CXW" --bottle "$BOTTLE" --no-update "$B/xclick.exe" ew 900 > "$L/xclick-$STAMP.log" 2>&1 & )
  echo "Enemy Within will be selected in the XCOM launcher automatically."
else echo "In the XCOM launcher, choose Enemy Within (upper button)."; fi
echo "The first launch after login may show a macOS password prompt (developer tools access for x87sidecar)."
echo "[$(ts)] Waiting for Enemy Within to start..."
t=0; until GP="$(game_pid)"; do sleep 2; t=$((t+2)); [ "$t" -ge 900 ] && fail "Enemy Within did not start within 15 minutes (log: $LOG)."; done
echo "[$(ts)] Game running. Leave this window open: it prints the FPS summary when the game exits."
echo "        Closing this window does not stop the game. If it freezes: 'XCOM (CrossOver fix) - stop' on the Desktop."
FBP=""; CSV=""
if [ "$FPS" = 1 ] && [ -x "$B/fpsbar" ]; then
  for _ in 1 2 3 4 5; do [ -s "$L/.last-game-log" ] && break; sleep 1; done
  GL="$(cat "$L/.last-game-log" 2>/dev/null)"
  if [ -n "$GL" ] && mkdir -p "$FPS_DIR"; then
    CSV="$FPS_DIR/fps-crossover-$STAMP.csv"
    HID=(); [ "$HUD" = 1 ] || HID=(--hidden)
    nohup "$B/fpsbar" "${HID[@]}" --csv "$CSV" --status "$L/fpsbar-status.txt" "$GL" "$GP" > "$L/fpsbar-$STAMP.log" 2>&1 &
    FBP=$!
    [ "$HUD" = 1 ] && echo "        FPS counter: small box in the game window's top-left corner ('FPS -' until the first number)."
    echo "        FPS log: $CSV"
  fi
fi
while game_pid >/dev/null; do sleep 5; done
[ -n "$FBP" ] && kill "$FBP" 2>/dev/null
echo "[$(ts)] Game exited. Steam keeps running (quit it from its menu when you are done)."
if [ -n "$CSV" ] && [ -f "$CSV" ]; then
  echo; "$B/fps-summary.sh" "$CSV" | tee "${CSV%.csv}-summary.txt"; echo
  find "$FPS_DIR" -maxdepth 1 -name 'fps-crossover-*' | sort -r | tail -n +101 | while IFS= read -r f; do rm -f "$f"; done
  pause 120
else pause 15; fi
exit 0
EOF
} | write_file "$PREFIX/bin/xcom-play.sh" 755

{ printf '#!/bin/bash\n%s (stop helper)\n' "$MARKER"
  printf 'ROOT=%q\n' "$CXROOT/"
  cat <<'EOF'
# Stops only XCOM processes started from the fixed copy (Steam keeps running). A game held "traced" by
# x87sidecar cannot die until the sidecar exits, so the sidecar parent is stopped if needed.
list() {
  for p in $(ps -axo pid=,stat=,args= | awk 'tolower($0) ~ /(xcomew|xcomgame|xcomlauncher)\.exe/ && $2 !~ /Z/ && $0 !~ /awk|xcom-kill/ {print $1}'); do
    lsof -a -p "$p" -d txt -Fn 2>/dev/null | grep -qF "$ROOT" && echo "$p"
  done
}
sidecars() { for p in "$@"; do pp=$(ps -o ppid= -p "$p" | tr -d ' '); ps -o args= -p "$pp" 2>/dev/null | grep -q x87sidecar_entitled && echo "$pp"; done; }
getpids() { read -r -a P <<< "$(list | tr '\n' ' ')"; }
getpids
if [ "${#P[@]}" -eq 0 ]; then echo "No XCOM processes from xcom-x87-fix are running."; else
  echo "Stopping XCOM (pids: ${P[*]})"
  read -r -a SC <<< "$(sidecars "${P[@]}" | tr '\n' ' ')"
  kill -TERM "${P[@]}" 2>/dev/null; sleep 3
  getpids; if [ "${#P[@]}" -gt 0 ]; then kill -KILL "${P[@]}" 2>/dev/null; sleep 1; fi
  getpids; if [ "${#P[@]}" -gt 0 ] && [ "${#SC[@]}" -gt 0 ]; then kill -TERM "${SC[@]}" 2>/dev/null; sleep 2; kill -KILL "${SC[@]}" 2>/dev/null; sleep 1; fi
  getpids; if [ "${#P[@]}" -eq 0 ]; then echo "XCOM stopped."; else echo "Could not stop: ${P[*]}"; fi
fi
[ -t 0 ] && [ -z "${NOWAIT:-}" ] && read -r -t 10 -p "Done (closes in 10 s)." _
exit 0
EOF
} | write_file "$PREFIX/bin/xcom-kill.sh" 755
# FPS counter/log helpers and the launcher click helper, shared with free mode
for f in bin/fpsbar bin/xclick.exe fps-summary.sh compare-fps.sh; do
  run cp -p "$HERE/freewine/$f" "$PREFIX/bin/$(basename "$f")" || die "cannot copy $f"
done
run chmod 755 "$PREFIX/bin/fpsbar" "$PREFIX/bin/fps-summary.sh" "$PREFIX/bin/compare-fps.sh"
run xattr -d com.apple.quarantine "$PREFIX/bin/fpsbar" 2>/dev/null || true

if [ "$DESKTOP" = 1 ]; then
  for pair in "$DESK_PLAY|xcom-play.sh" "$DESK_KILL|xcom-kill.sh"; do
    d="${pair%%|*}"; t="${pair##*|}"
    { printf '#!/bin/bash\n%s (Desktop launcher; removed by install.sh --uninstall)\n' "$MARKER"
      printf 'exec %q "$@"\n' "$PREFIX/bin/$t"; } | write_file "$d" 755
    [ "$DRY" = 0 ] && printf 'desktop=%s\n' "$d" >> "$MANIFEST"
  done
fi

# Optional game config: AmbientOcclusion=True (with AO off, mission start crashed under CrossOver's built-in d3d9)
INI=""
for c in "$BDIR"/drive_c/users/*/Documents/"My Games/XCOM - Enemy Within/XComGame/Config/XComEngine.ini" \
         "$HOME/Documents/My Games/XCOM - Enemy Within/XComGame/Config/XComEngine.ini"; do
  case "$c" in */users/Public/*) continue;; esac
  [ -f "$c" ] && { INI="$c"; break; }
done
if [ -z "$INI" ]; then info "XComEngine.ini not found yet (start the game once); skipping game config"
else
  AO="$(awk '/^\[/{s=($0 ~ /^\[SystemSettings\]/)} s && /^AmbientOcclusion=/{sub(/^AmbientOcclusion=/,""); print; exit}' "$INI" | tr -d '\r')"
  info "XComEngine.ini: AmbientOcclusion=${AO:-<missing>}"
  if [ "$GAMECFG" = ask ]; then
    if [ "$DRY" = 1 ]; then GAMECFG=no; info "[dry-run] would ask whether to back up XComEngine.ini and set AmbientOcclusion=True"
    elif ask_yes "Back up XComEngine.ini and set AmbientOcclusion=True (recommended)?"; then GAMECFG=yes; else GAMECFG=no; fi
  fi
  if [ "$GAMECFG" = yes ]; then
    if [ "$AO" = True ]; then info "already True; nothing to change"
    else
      B="$INI.bak-xcom-x87-fix-$(date +%Y%m%d-%H%M%S)"
      run cp -p "$INI" "$B"
      run perl -pi -e 'if (/^\[/) { $s = /^\[SystemSettings\]\s*$/ } s/^AmbientOcclusion=.*/AmbientOcclusion=True/ if $s' "$INI"
      [ "$DRY" = 0 ] && printf 'ini_backup=%s\n' "$B" >> "$MANIFEST"
    fi
  fi
fi

say ""
if [ "$DRY" = 1 ]; then
  say "DRY RUN complete: nothing was changed. Checks failed: $FAILS."
  [ "$FAILS" -gt 0 ] && exit 1
  exit 0
fi
say "Installed. Quit Steam in CrossOver, then double-click '$(basename "$DESK_PLAY")' on your Desktop."
say "Options (run from Terminal): \"$PREFIX/bin/xcom-play.sh\" --no-hud | --no-fps | --no-x87 | --launcher"
say "Compare FPS with free mode: \"$PREFIX/bin/compare-fps.sh\""
say "Uninstall: ./install.sh --crossover --uninstall"
