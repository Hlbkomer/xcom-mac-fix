# shellcheck shell=bash
# shellcheck disable=SC2154  # helpers and option variables come from install.sh
# FREE mode of xcom-mac-fix (the default). Sourced by install.sh; not run directly.
DIR="${DIR%/}"
case "$DIR" in /*) ;; *) die "--dir must be an absolute path";; esac
case "$DIR" in "$HOME"|/|/Applications|"$HOME/Library"|"$HOME/Documents"|"$HOME/Desktop") die "refusing to use $DIR as the install folder";; esac
MANIFEST="$DIR/install.manifest"
DESK_PLAY="$HOME/Desktop/XCOM Enemy Within (free Wine).command"
DESK_KILL="$HOME/Desktop/XCOM (free Wine) - stop.command"
FW_WS_PAT="$(esc_re "$DIR/wine/").*wineserver"
OTHER_WS_PAT='CrossOver\.app/Contents/SharedSupport/CrossOver/.*wineserver|/cxroot/.*wineserver'
STEAMDIR="$DIR/prefix/drive_c/Program Files (x86)/Steam"
# shellcheck source=/dev/null
fw() { ( . "$DIR/env.sh" && "$@" ); }        # run a command/function in the free-Wine environment
fwrun() { if [ "$DRY" = 1 ]; then run "$@"; else fw "$@"; fi; }
logf() { if [ "$DRY" = 1 ]; then echo /dev/null; else echo "$DIR/logs/$1"; fi; }   # nothing is written in a dry run

say "xcom-mac-fix $VERSION — free mode: $MODE$([ "$DRY" = 1 ] && echo ' (DRY RUN: nothing will be changed)')"
say "  install folder: $DIR"

# ---------- uninstall ----------
if [ "$MODE" = uninstall ]; then
  [ -d "$DIR" ] || { say "Nothing installed at $DIR."; exit 0; }
  grep -qx 'mode=free' "$MANIFEST" 2>/dev/null || die "$DIR has no free-mode install.manifest; not removing it automatically."
  if pgrep -f "$FW_WS_PAT" >/dev/null 2>&1; then
    say "Stopping XCOM and its Steam first..."
    if [ -x "$DIR/stop.sh" ]; then run env NOWAIT=1 "$DIR/stop.sh"; else check_fail "Steam from $DIR is running; quit it first"; fi
  fi
  say "This deletes $DIR ($(du -sh "$DIR" 2>/dev/null | awk '{print $1}')): the Wine build, the prefix with its Steam login"
  say "and the game copy inside it. Your saves/settings in ~/Documents/My Games and CrossOver are NOT touched."
  if [ "$DRY" = 0 ] && [ "$YES" = 0 ]; then
    [ -t 0 ] || die "not interactive; re-run with --yes to confirm"
    read -r -p "  ? Delete it? [y/N] " a; case "$a" in [yY]*) ;; *) die "cancelled";; esac
  fi
  while IFS='=' read -r k v; do
    case "$k" in
      desktop) if [ -f "$v" ] && grep -qF -e "$MARKER" -e "$OLD_MARKER" "$v"; then info "$v"; run rm -f "$v"
               elif [ -e "$v" ]; then warn "not removing $v (it was changed, no marker)"; fi;;
      ini_backup) [ -n "$v" ] && say "  Note: XComEngine.ini is left as it is. Your pre-install copy: $v";;
    esac
  done < "$MANIFEST"
  info "$DIR"; run rm -rf "$DIR"
  say "Done."
  exit 0
fi

# ---------- checks ----------
say ""; say "[1/9] System checks"
system_checks
for t in curl shasum tar perl lsof pgrep cp; do command -v "$t" >/dev/null 2>&1 || check_fail "'$t' not found"; done
RESUME=0
if [ -e "$DIR" ]; then
  if grep -qx 'mode=free' "$MANIFEST" 2>/dev/null; then RESUME=1; info "existing free-mode install found: continuing it (finished steps are skipped)"
  else check_fail "$DIR exists and is not a free-mode install of this tool (choose another --dir)"; fi
fi
PARENT="$DIR"; while [ ! -d "$PARENT" ]; do PARENT="$(dirname "$PARENT")"; done
FREE_KB="$(df -Pk "$PARENT" | awk 'NR==2{print $4}')"
info "free space: $((FREE_KB/1024/1024)) GB on $(df -P "$PARENT" | awk 'NR==2{print $NF}')"

say ""; say "[2/9] Other Steam, launchers, game source"
if pgrep -f "$OTHER_WS_PAT" >/dev/null 2>&1; then check_fail "CrossOver's Wine (or the CrossOver-mode fix) is running. Quit its Steam (Steam menu > Exit) first: only one Steam at a time."
else info "no other Wine Steam running"; fi
if pgrep -f "$FW_WS_PAT" >/dev/null 2>&1; then check_fail "This install has a running Wine session. Quit its game and Steam before updating runtime files."; fi
if [ "$DESKTOP" = 1 ]; then
  for f in "$DESK_PLAY" "$DESK_KILL"; do
    if [ -e "$f" ] && ! grep -qF -e "$MARKER" -e "$OLD_MARKER" "$f" 2>/dev/null; then check_fail "$f exists and was not created by this installer (use --no-desktop or move it)"
    elif [ -e "$f" ]; then info "will replace $(basename "$f") (made by this tool)"; fi
  done
fi
SRC_APPS=""; SRC_GAME=""; GAME_MODE=download
if [ -f "$STEAMDIR/steamapps/appmanifest_$STEAM_APPID.acf" ] && [ -f "$STEAMDIR/steamapps/common/XCom-Enemy-Unknown/XEW/Binaries/Win32/XComEW.exe" ]; then
  GAME_MODE=present; info "game: already in this prefix"
else
  case "$GAME_FROM" in
    download) ;;
    auto) for b in "$BOTTLES_DIR/$BOTTLE" "$BOTTLES_DIR"/*; do
            [ -d "$b/drive_c" ] || continue
            if r="$(find_game "$b")"; then SRC_APPS="${r%%|*}"; SRC_GAME="${r#*|}"; break; fi
          done;;
    *) [ -d "$GAME_FROM" ] || check_fail "--game-from: $GAME_FROM is not a folder"
       if r="$(find_game "$GAME_FROM")"; then SRC_APPS="${r%%|*}"; SRC_GAME="${r#*|}"
       else check_fail "--game-from: no XCOM with Enemy Within (app $STEAM_APPID, XEW/Binaries/Win32/XComEW.exe) found under $GAME_FROM"; fi;;
  esac
  if [ -n "$SRC_GAME" ]; then
    GAME_MODE=clone
    info "game: copy-on-write clone of $SRC_GAME (read only; the original is never changed)"
    if [ "$(df -P "$SRC_GAME" | awk 'NR==2{print $1}')" != "$(df -P "$PARENT" | awk 'NR==2{print $1}')" ]; then
      GAME_MODE=copy; warn "the game is on another volume: an APFS clone is impossible, a full copy needs ~20 GB"
    fi
  else info "game: will be downloaded by this Steam (~20 GB)"; fi
fi
NEED_GB=4; case "$GAME_MODE" in download|copy) NEED_GB=26;; esac
[ "$FREE_KB" -gt $((NEED_GB*1024*1024)) ] || check_fail "about $NEED_GB GB free space needed"
for u in "$WINE_URL" "$MONO_URL" "$SIDECAR_URL" "$MTLD3D_URL" "$STEAM_URL"; do
  curl -sfIL --max-time 20 -o /dev/null "$u" || check_fail "cannot reach $u"
done
info "download sources reachable (Wine build, Wine Mono, x87sidecar, mtld3d, Steam)"
[ -f "$HERE/freewine/play.sh" ] || check_fail "installer files incomplete: $HERE/freewine missing"
if [ ! -f "$HERE/freewine/bin/xclick.exe" ] || [ "$(sha256 "$HERE/freewine/bin/xclick.exe")" != "$XCLICK_SHA" ]; then check_fail "freewine/bin/xclick.exe does not match its pinned sha256"; fi
if [ ! -f "$HERE/freewine/bin/fpsbar" ] || [ "$(sha256 "$HERE/freewine/bin/fpsbar")" != "$FPSBAR_SHA" ]; then check_fail "freewine/bin/fpsbar does not match its pinned sha256"; fi
if [ ! -f "$HERE/vendor/mtld3d/d3d9.dll" ] || [ "$(sha256 "$HERE/vendor/mtld3d/d3d9.dll")" != "$MTLD3D_XCOM_SHA" ]; then check_fail "bundled XCOM mtld3d DLL missing or checksum mismatch"; fi
[ -f "$HERE/vendor/mtld3d/LICENSE" ] || check_fail "mtld3d licence missing"
if [ "$DRY" = 1 ] && [ "$FAILS" -gt 0 ]; then
  say ""; say "Dry run: $FAILS check(s) failed; a real install would stop at the first one. Planned actions follow anyway:"
fi

# ---------- install ----------
say ""; say "[3/9] Wine (athei/wine-build cx-26.3.0-6: CrossOver 26.3 sources + NX fix + x87 hook, LGPL)"
run mkdir -p "$DIR/dl" "$DIR/bin" "$DIR/logs"
if [ "$DRY" = 0 ] && [ "$RESUME" = 0 ]; then
  printf 'mode=free\nversion=%s\ndate=%s\ndir=%s\n' "$VERSION" "$(date '+%F %T')" "$DIR" > "$MANIFEST"
fi
if [ -x "$DIR/wine/bin/wine" ]; then info "already installed"
else
  fetch "$WINE_URL" "$DIR/dl/wine.tar.xz" "$WINE_SHA"
  run rm -rf "$DIR/wine-extract"; run mkdir -p "$DIR/wine-extract"
  run tar -xJf "$DIR/dl/wine.tar.xz" -C "$DIR/wine-extract" || die "unpacking Wine failed"
  if [ "$DRY" = 0 ]; then
    W="$(find "$DIR/wine-extract" -maxdepth 4 -path '*/bin/wine' | head -1)"
    [ -n "$W" ] || die "no bin/wine in the Wine archive"
    mv "$(dirname "$(dirname "$W")")" "$DIR/wine" || die "cannot move Wine into place"
    rm -rf "$DIR/wine-extract" "$DIR/dl/wine.tar.xz"
  else info "[dry-run] would move the unpacked tree to $DIR/wine"; fi
fi

say ""; say "[4/9] Wine Mono 10.4.1 (for the XCOM launcher, a .NET program)"
if [ -d "$DIR/wine/share/wine/mono/wine-mono-10.4.1" ]; then info "already installed"
else
  fetch "$MONO_URL" "$DIR/dl/wine-mono.tar.xz" "$MONO_SHA"
  run mkdir -p "$DIR/wine/share/wine/mono"
  run tar -xJf "$DIR/dl/wine-mono.tar.xz" -C "$DIR/wine/share/wine/mono" || die "unpacking Wine Mono failed"
  run rm -f "$DIR/dl/wine-mono.tar.xz"
fi

say ""; say "[5/9] x87sidecar v1.7.0 (athei, MIT), mtld3d v0.11.0 (athei, zlib) and the launch scripts"
if [ -x "$DIR/bin/x87sidecar" ] && [ -f "$DIR/bin/.x87sidecar-$SIDECAR_SHA" ]; then info "x87sidecar already installed"
else
  fetch "$SIDECAR_URL" "$DIR/dl/x87sidecar.tar.xz" "$SIDECAR_SHA"
  run tar -xJf "$DIR/dl/x87sidecar.tar.xz" -C "$DIR/bin" x87sidecar || die "unpacking x87sidecar failed"
  run chmod 755 "$DIR/bin/x87sidecar"; run rm -f "$DIR/dl/x87sidecar.tar.xz"
  [ "$DRY" = 0 ] && touch "$DIR/bin/.x87sidecar-$SIDECAR_SHA"
fi
if [ "$DRY" = 0 ]; then
  "$DIR/bin/x87sidecar" --probe > "$DIR/logs/probe.log" 2>&1
  grep -qx 'supported' "$DIR/logs/probe.log" || { cat "$DIR/logs/probe.log"; die "x87sidecar --probe: this Rosetta version is not supported"; }
  info "x87sidecar --probe: supported"
else info "[dry-run] would run: x87sidecar --probe (must print 'supported')"; fi
# mtld3d v0.11.0 (athei, zlib): d3d9 on Metal, the default renderer (play.sh --renderer=gl falls back to wined3d).
# The Wine build bundles mtld3d v0.7.0, which fails XCOM's fp16-blending check ("Your video card does not support
# alpha blending with floating point render targets..."); v0.11.0 passes it. The bundled tree is kept in dl/.
M3="$DIR/wine/lib/wine/d3d9/mtld3d"
if [ -f "$M3/.mtld3d-$MTLD3D_SHA" ]; then info "mtld3d v0.11.0 already installed"
else
  fetch "$MTLD3D_URL" "$DIR/dl/mtld3d.tar.xz" "$MTLD3D_SHA"
  run rm -rf "$DIR/dl/mtld3d-extract"; run mkdir -p "$DIR/dl/mtld3d-extract"
  run tar -xJf "$DIR/dl/mtld3d.tar.xz" -C "$DIR/dl/mtld3d-extract" || die "unpacking mtld3d failed"
  if [ -d "$M3" ] && [ ! -e "$DIR/dl/mtld3d-bundled-v0.7.0" ]; then run mv "$M3" "$DIR/dl/mtld3d-bundled-v0.7.0" || die "cannot move the bundled mtld3d aside"; fi
  run rm -rf "$M3"; run mkdir -p "$M3"
  for a in i386-windows x86_64-windows x86_64-unix; do
    run cp -R -p "$DIR/dl/mtld3d-extract/wine/$a" "$M3/" || die "cannot install mtld3d ($a)"
  done
  run cp -p "$DIR/dl/mtld3d-extract/LICENSE" "$M3/LICENSE"
  run rm -rf "$DIR/dl/mtld3d-extract" "$DIR/dl/mtld3d.tar.xz"
  [ "$DRY" = 0 ] && touch "$M3/.mtld3d-$MTLD3D_SHA"
fi
# Recheck the actual DLL on every install; a version stamp alone cannot prove the fix is present.
. "$HERE/mtld3d-fix.sh"
install_mtld3d_fix
for f in env.sh play.sh stop.sh steam.sh validate.sh kill-xcom.sh fps-summary.sh compare-fps.sh mtlhud-fps.sh bin/x87filter bin/xclick.exe bin/fpsbar; do
  run cp -p "$HERE/freewine/$f" "$DIR/$f" || die "cannot copy $f"
done
run chmod 755 "$DIR/play.sh" "$DIR/stop.sh" "$DIR/steam.sh" "$DIR/validate.sh" "$DIR/kill-xcom.sh" "$DIR/fps-summary.sh" "$DIR/compare-fps.sh" "$DIR/mtlhud-fps.sh" "$DIR/bin/x87filter" "$DIR/bin/fpsbar"
# fpsbar (the FPS counter) is a small Mac program built from tools/fpsbar.m and ad-hoc signed; a downloaded
# zip marks it as quarantined, which would block it, so the mark is removed from the installed copy only.
run xattr -d com.apple.quarantine "$DIR/bin/fpsbar" 2>/dev/null || true

say ""; say "[6/9] Wine prefix and Steam"
if [ -f "$DIR/prefix/system.reg" ]; then info "prefix already exists"
else
  info "creating the prefix (Windows 10, 64-bit; about a minute)"
  [ "$DRY" = 1 ] && info "[dry-run] would run: wineboot -i  (WINEPREFIX=$DIR/prefix, WINEDLLOVERRIDES=mshtml=d;winemenubuilder.exe=d)"
  fwrun env WINEDLLOVERRIDES="mshtml=d;winemenubuilder.exe=d" wineboot -i > "$(logf wineboot.log)" 2>&1 || die "wineboot failed (see $DIR/logs/wineboot.log)"
  fwrun wineserver -w
fi
if [ "$DRY" = 1 ]; then info "[dry-run] would run: wine reg add HKCU\\Software\\Wine\\WineDbg /v ShowCrashDialog /t REG_DWORD /d 0"
else fw wine reg add 'HKCU\Software\Wine\WineDbg' /v ShowCrashDialog /t REG_DWORD /d 0 /f >/dev/null 2>&1; fi
info "Wine crash dialog disabled in this prefix (Steam.exe's harmless exit crash would otherwise show one)"
if [ -f "$STEAMDIR/steam.exe" ] || [ -f "$STEAMDIR/Steam.exe" ]; then info "Steam already installed"
else
  say "  Licence note: SteamSetup.exe is installed silently (/S), which skips its licence page. Installing Steam means"
  say "  you accept Valve's Steam Subscriber Agreement (https://store.steampowered.com/subscriber_agreement/). XCOM's own"
  say "  licence agreement is shown by Steam at the first game start. Wine and Wine Mono are free software (LGPL and others)."
  if [ "$DRY" = 0 ] && [ "$YES" = 0 ] && [ -t 0 ]; then
    read -r -p "  ? Continue? [Y/n] " a; case "$a" in [nN]*) die "cancelled";; esac
  fi
  fetch "$STEAM_URL" "$DIR/dl/SteamSetup.exe"
  if [ "$DRY" = 0 ]; then [ "$(head -c 2 "$DIR/dl/SteamSetup.exe")" = MZ ] || die "SteamSetup.exe is not a Windows program"; fi
  info "installing Steam silently"
  [ "$DRY" = 1 ] && info "[dry-run] would run: wine SteamSetup.exe /S  (in $DIR/prefix)"
  fwrun wine "$DIR/dl/SteamSetup.exe" /S > "$(logf steamsetup.log)" 2>&1
  fwrun wineserver -w
  [ "$DRY" = 1 ] || [ -f "$STEAMDIR/steam.exe" ] || [ -f "$STEAMDIR/Steam.exe" ] || die "Steam did not install (see $DIR/logs/steamsetup.log)"
  run rm -f "$DIR/dl/SteamSetup.exe"
fi

say ""; say "[7/9] Steam login (you)"
if [ "$DRY" = 1 ]; then info "[dry-run] would start Steam and wait until you have logged in (Steam Guard if asked, tick 'Remember me')"
else
  if ! fw steam_ready 2>/dev/null; then
    say "  A Steam window opens now (first start updates Steam: 1-3 min). Log in with your account"
    say "  (Steam Guard if asked, tick 'Remember me'). The installer continues by itself once you are logged in."
  fi
  fw "$DIR/steam.sh" >/dev/null
  fw wait_steam_ready 3600; r=$?
  [ "$r" = 1 ] && die "Steam exited before you were logged in. Re-run the installer to continue."
  [ "$r" = 2 ] && die "Not logged in after an hour. Re-run the installer to continue."
  info "logged in"
fi

say ""; say "[8/9] The game"
case "$GAME_MODE" in
  present) info "already in the prefix";;
  clone|copy)
    info "closing Steam for the copy"; fwrun shutdown_all >/dev/null
    run mkdir -p "$STEAMDIR/steamapps/common"
    if [ "$GAME_MODE" = clone ]; then
      info "APFS clone (copy-on-write, uses almost no space): $SRC_GAME"
      run cp -c -R -p "$SRC_GAME" "$STEAMDIR/steamapps/common/" || { run rm -rf "$STEAMDIR/steamapps/common/$(basename "$SRC_GAME")"; die "APFS clone failed; nothing was changed in the source"; }
    else
      if [ "$DRY" = 0 ] && ! { [ "$YES" = 1 ] || ask_yes "Copy the whole game (~20 GB) from the other volume?"; }; then die "cancelled; re-run with --game-from download to let Steam download it instead"; fi
      run cp -R -p "$SRC_GAME" "$STEAMDIR/steamapps/common/" || die "copy failed"
    fi
    run cp -p "$SRC_APPS/appmanifest_$STEAM_APPID.acf" "$STEAMDIR/steamapps/" || die "cannot copy the appmanifest"
    if [ "$VALIDATE" = 1 ]; then
      info "one-time 'Verify integrity of game files' (the copied copy-protected .exe files are rejected until Steam re-fetches them)"
      fwrun "$DIR/validate.sh" || die "verification failed; run $DIR/validate.sh later"
    else warn "skipping verification (--no-validate): if the game quits ~2 s after start, run $DIR/validate.sh"; fi;;
  download)
    if [ "$DRY" = 1 ]; then info "[dry-run] would ask Steam to install app $STEAM_APPID and wait until it is fully installed"
    else
      say "  Steam shows an install dialog for XCOM: click Install (the default location is fine). ~20 GB."
      fw wine 'C:\Program Files (x86)\Steam\Steam.exe' "steam://install/$STEAM_APPID" >/dev/null 2>&1 &
      t=0
      until grep -q '"StateFlags"[[:space:]]*"4"' "$STEAMDIR/steamapps/appmanifest_$STEAM_APPID.acf" 2>/dev/null \
            && [ -f "$STEAMDIR/steamapps/common/XCom-Enemy-Unknown/XEW/Binaries/Win32/XComEW.exe" ]; do
        sleep 30; t=$((t+30))
        [ $((t % 300)) = 0 ] && info "still downloading ($((t/60)) min; $(du -sh "$STEAMDIR/steamapps" 2>/dev/null | awk '{print $1}') so far)"
        pgrep -f "$FW_WS_PAT" >/dev/null || die "Steam was closed during the download. Re-run the installer to continue."
      done
      info "downloaded and installed"
    fi;;
esac

say ""; say "[9/9] Launchers and game settings"
if [ "$DESKTOP" = 1 ]; then
  for pair in "$DESK_PLAY|play.sh" "$DESK_KILL|stop.sh"; do
    d="${pair%%|*}"; t="${pair##*|}"
    { printf '#!/bin/bash\n%s (Desktop launcher; removed by install.sh --uninstall)\n' "$MARKER"
      printf 'exec %q "$@"\n' "$DIR/$t"; } | write_file "$d" 755
    [ "$DRY" = 0 ] && ! grep -qxF "desktop=$d" "$MANIFEST" && printf 'desktop=%s\n' "$d" >> "$MANIFEST"
  done
fi
game_config "$MANIFEST" "$DIR/prefix"
fwrun shutdown_all >/dev/null
say ""
if [ "$DRY" = 1 ]; then
  say "DRY RUN complete: nothing was changed. Checks failed: $FAILS."
  [ "$FAILS" -gt 0 ] && exit 1
  exit 0
fi
say "Installed. Double-click '$(basename "$DESK_PLAY")' on your Desktop."
say "  First launch: Steam may show XCOM's license agreement (accept it) and install DirectX/VC++ once."
say "  The FPS counter is on by default (testing default; play.sh --no-hud hides it, HUD_DEFAULT in env.sh flips it)."
say "  Options: \"$DIR/play.sh\" --help    Stop everything: '$(basename "$DESK_KILL")'"
say "  Uninstall: ./install.sh --uninstall"
exit 0
