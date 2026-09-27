# shellcheck shell=bash
# Sourced by free-mode.sh. Uses its checked paths and install helpers.
install_mtld3d_fix() {
  local src="$HERE/vendor/mtld3d/d3d9.dll" dst="$M3/i386-windows/d3d9.dll" old backup
  [ -f "$src" ] && [ "$(sha256 "$src")" = "$MTLD3D_XCOM_SHA" ] || die "XCOM mtld3d payload checksum mismatch"
  if [ -f "$dst" ] && [ "$(sha256 "$dst")" = "$MTLD3D_XCOM_SHA" ]; then
    info "XCOM short-stride fix verified (actual DLL checksum)"
  else
    if [ -L "$dst" ]; then die "refusing to replace a symlink: $dst"; fi
    if [ -f "$dst" ]; then
      old="$(sha256 "$dst")"
      backup="$DIR/dl/mtld3d-before-xcom-$old.dll"
      [ -e "$backup" ] || run cp -p "$dst" "$backup" || die "cannot back up existing mtld3d DLL"
      info "previous DLL preserved at $backup"
    fi
    run cp -p "$src" "$dst.xcom-tmp" || die "cannot stage XCOM mtld3d DLL"
    if [ "$DRY" = 0 ]; then
      [ "$(sha256 "$dst.xcom-tmp")" = "$MTLD3D_XCOM_SHA" ] || die "staged mtld3d checksum mismatch"
    fi
    run mv -f "$dst.xcom-tmp" "$dst" || die "cannot install XCOM mtld3d DLL"
    info "XCOM short-stride fix installed"
  fi
  run cp -p "$HERE/vendor/mtld3d/LICENSE" "$M3/LICENSE.xcom-fix" || die "cannot install mtld3d licence"
}
