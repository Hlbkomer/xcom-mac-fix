#!/bin/bash
# Rebuild the release DLL in a NEW, isolated build directory. No installs.
set -euo pipefail
if [ "$#" -ne 3 ]; then
  echo "Usage: $0 NEW_BUILD_DIR WINE_SDK XWIN_SDK" >&2; exit 2
fi
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$1"; SDK="$2"; XWIN="$3"
for p in "$BUILD" "$SDK" "$XWIN"; do
  case "$p" in /*) ;; *) echo "All paths must be absolute" >&2; exit 2;; esac
done
[ ! -e "$BUILD" ] || { echo "Build directory already exists; choose a new one" >&2; exit 2; }
[ -x "$SDK/bin/winebuild" ] || { echo "Wine SDK lacks winebuild" >&2; exit 2; }
[ -d "$XWIN/crt/include" ] || { echo "XWIN SDK missing" >&2; exit 2; }
echo '6b027f803449ed315f71031d7610c41e80b568954d2cbbdf59a9642b1da415f1  '"$HERE/installer/vendor/mtld3d/source.tar.gz" | shasum -a 256 -c -
mkdir -p "$BUILD"
tar -xzf "$HERE/installer/vendor/mtld3d/source.tar.gz" -C "$BUILD"
export CARGO_TARGET_DIR="$BUILD/target"
# Generate TOML safely: TOML literal strings preserve backslashes and spaces.
# A single quote in a path needs a different encoding; reject it explicitly.
case "$HOME$BUILD$XWIN" in *"'"*) echo "Paths containing single quotes are unsupported" >&2; exit 2;; esac
cat > "$BUILD/release-config.toml" <<EOF
[target.'cfg(all())']
rustflags = [
 '--remap-path-prefix=$HOME=/build/user',
 '--remap-path-prefix=$BUILD/mtld3d-source=/build/mtld3d',
 '-Lnative=$XWIN/crt/lib/x86',
 '-Lnative=$XWIN/sdk/lib/um/x86',
 '-Lnative=$XWIN/sdk/lib/ucrt/x86',
]
EOF
INC="-march=nehalem -fno-omit-frame-pointer -idirafter \"$XWIN/crt/include\" -idirafter \"$XWIN/sdk/include/ucrt\" -idirafter \"$XWIN/sdk/include/um\" -idirafter \"$XWIN/sdk/include/shared\" -ffile-prefix-map=$HOME=/build/user"
cd "$BUILD/mtld3d-source/windows"
env CC_SHELL_ESCAPED_FLAGS=1 "CFLAGS_i686-pc-windows-msvc=$INC" "CXXFLAGS_i686-pc-windows-msvc=$INC" \
  cargo +1.98.1 build -p d3d9 --locked --release --target i686-pc-windows-msvc --config "$BUILD/release-config.toml"
cp "$CARGO_TARGET_DIR/i686-pc-windows-msvc/release/d3d9.dll" "$BUILD/d3d9.dll"
"$SDK/bin/winebuild" --builtin "$BUILD/d3d9.dll"
shasum -a 256 "$BUILD/d3d9.dll"
echo "Built $BUILD/d3d9.dll. Run graphics and tactical checks before updating the release checksum."
