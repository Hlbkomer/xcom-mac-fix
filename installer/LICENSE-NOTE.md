# Licences

## This project: MIT
The installer and everything written for it (`install.sh`, `free-mode.sh`, `crossover-mode.sh`, `uninstall.sh`,
`freewine/*` scripts including `fps-summary.sh` and `compare-fps.sh`, `tools/fpsbar.m` and the `freewine/bin/fpsbar`
built from it, and the documentation including `../METHODOLOGY.md`) are
released under the **MIT License**, Copyright (c) 2026 Hlbkomer. The full text is in [LICENSE](LICENSE).

Exception: `tools/xclick.c` and the `freewine/bin/xclick.exe` built from it are dedicated to the public domain
(**CC0**).

The project ships two small binaries it built itself from the sources in `tools/`: `xclick.exe` (a Windows
program, cross-compiled with mingw-w64) and `fpsbar` (a macOS arm64 program, built with Apple clang and
ad-hoc signed). Both are sha256-pinned in `install.sh`, and you can rebuild them from `tools/` (the build
commands are at the top of each source file). The altered mtld3d i386 DLL is also bundled, under its own zlib licence; see `vendor/mtld3d/README.md` for its checksum, source commit, patch and test provenance.

## Third-party components

| Component | License (as found) | How the installer uses it | Notes |
|---|---|---|---|
| athei/wine-build `cx-26.3.0-6` (release tarball, sha256 `11cb278a…ce37`) | Wine built from CodeWeavers' open-source CrossOver 26.3 sources plus athei's patches, so **LGPL-2.1-or-later** (the wine-build repo itself has no license file) | **downloaded** from the official GitHub release by the user's installer; not bundled | Nothing is redistributed by us. If a bundle is ever shipped, the LGPL requires offering the corresponding source (CodeWeavers' CrossOver source tarball + athei/wine commits). The tarball also contains Metal/GPTK-related d3d components (`mtld3d` v0.7.0, `gptk` dxgi); the game doesn't use them (the installer replaces the bundled mtld3d with v0.11.0, next row). Their exact terms weren't reviewed, which is one more reason to keep downloading rather than bundling. |
| athei/wine (commit 539aa62) | LGPL-2.1-or-later | included in the build above; referenced in docs | – |
| athei/x87sidecar v1.7.0 (commit 4048fcf), release asset `x87sidecar.tar.xz` | **MIT** (`LICENSE`: "Copyright (c) 2025 Lifeisawful"; README "License: MIT") | free mode: **prebuilt release binary downloaded** (sha256-pinned); CrossOver mode: cloned and built from source on the user's Mac | Not bundled. If ever bundled, include its LICENSE text. |
| athei/mtld3d v0.11.0, release asset `mtld3d.tar.xz` (sha256 `c4535f3b…4304`) | **zlib** (`LICENSE` in the tarball: zlib licence text, copyright 2026 by the author, athei) | free mode: **downloaded** (sha256-pinned) and installed into the Wine tree in place of the bundled v0.7.0; the default d3d9 for the game (`play.sh --renderer=gl` falls back to wined3d) | The base runtime is downloaded. The altered XCOM i386 DLL is bundled separately with its licence and patch in `vendor/mtld3d/`; the installer applies it and keeps the previous DLL as a backup. |
| Wine Mono 10.4.1 | MIT plus other open-source licences (see its release) | downloaded (sha256-pinned) into the Wine tree | – |
| Steam (SteamSetup.exe) | Valve proprietary; Steam Subscriber Agreement | downloaded from Valve and installed silently in the user's own prefix | The installer shows a licence note before the silent install, because `/S` skips Steam's own licence page. |
| CrossOver 26.0 (CrossOver mode only) | proprietary (CodeWeavers), includes LGPL Wine components | cloned locally from the user's licensed install; the Wine `ntdll.dll` in that local clone is patched | Nothing is redistributed. **Unverified:** whether CrossOver's EULA restricts modifying a local copy. The owner may want to read the EULA or ask CodeWeavers. Free mode avoids the question. |
| fpsbar (this project) | MIT (this project) | shipped as a prebuilt macOS binary, built from `tools/fpsbar.m` | uses only Apple system frameworks (AppKit, CoreGraphics) |
| xclick (this project) | CC0 | shipped as a prebuilt Windows binary, built from `tools/xclick.c` | – |
| DXVK / MoltenVK | zlib / Apache-2.0 | not used or shipped | credited only |
| XCOM (Firaxis/2K) | proprietary | not touched except `XComEngine.ini` (optional, with backup); the game comes from the user's own Steam account | – |
