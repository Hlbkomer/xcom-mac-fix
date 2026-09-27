# shellcheck shell=bash
# Sourced by free-mode.sh. Uses its checked paths and install helpers.
install_mtld3d_fix() {
  local src="$HERE/vendor/mtld3d/d3d9.dll" dst="$M3/i386-windows/d3d9.dll" old backup
  [ -f "$src" ] && [ "$(sha256 "$src")" = "$MTLD3D_XCOM_SHA" ] || die "XCOM mtld3d payload checksum mismatch"
  check_write_path "$dst"
  if [ -f "$dst" ] && [ "$(sha256 "$dst")" = "$MTLD3D_XCOM_SHA" ]; then
    info "XCOM short-stride fix verified (actual DLL checksum)"
  else
    if [ -L "$dst" ]; then die "refusing to replace a symlink: $dst"; fi
    if [ -f "$dst" ]; then
      old="$(sha256 "$dst")"
      backup="$DIR/dl/mtld3d-before-xcom-$old.dll"
      check_write_path "$backup"
      [ -e "$backup" ] || write_file "$backup" 644 < "$dst" || die "cannot back up existing mtld3d DLL"
      info "previous DLL preserved at $backup"
    fi
    write_file "$dst" 644 < "$src" || die "cannot install XCOM mtld3d DLL"
    if [ "$DRY" = 0 ]; then
      [ "$(sha256 "$dst")" = "$MTLD3D_XCOM_SHA" ] || die "installed mtld3d checksum mismatch"
    fi
    info "XCOM short-stride fix installed"
  fi
  write_file "$M3/LICENSE.xcom-fix" 644 < "$HERE/vendor/mtld3d/LICENSE" || die "cannot install mtld3d licence"
}
