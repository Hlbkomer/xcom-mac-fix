# XCOM Mac Fix

Run the Steam Windows version of **XCOM: Enemy Within** on Apple Silicon using Wine, Rosetta 2 and Metal. The default setup needs **no CrossOver**. You need your own copy of XCOM: Enemy Unknown with the Enemy Within expansion and a Steam account.

**0.5.1 is an experimental prerelease.** The working setup was tested on one M1 Max running macOS 27. The bundled graphics DLL was rebuilt from the tactically tested fix and passed its focused graphics regression; that exact rebuild still needs a fresh tactical gameplay check. Enemy Unknown without the expansion is not validated.

## Download and install

Download `xcom-mac-fix-0.5.1.zip` and its `.sha256` file from the [0.5.1 release](https://github.com/Hlbkomer/xcom-mac-fix/releases/tag/v0.5.1). In Terminal, from the download directory:

```bash
shasum -a 256 -c xcom-mac-fix-0.5.1.zip.sha256
unzip xcom-mac-fix-0.5.1.zip
cd xcom-mac-fix-0.5.1/installer
./install.sh --dry-run
./install.sh
```

Requires Apple Silicon, macOS 15 or newer, Rosetta 2, internet access and sufficient disk space (about 26 GB for a full game download). Only macOS 27 has been tested. Sign in directly in Steam when it opens. The installer does not ask for your password.

See the [installation and play guide](installer/README.md) for launchers, game verification, options, troubleshooting and uninstalling. Optional CrossOver mode uses your own licensed installation.

## What it fixes

- Wine disabling data-execution prevention when older game DLLs load: uses athei's Wine NX fix.
- Slow x87 floating-point translation: applies athei's x87sidecar to XCOM only.
- Direct3D 9 rendering: uses mtld3d with NVIDIA adapter spoofing, SDR settings and an included short-vertex-stride fix for fog-of-war and movement overlays.
- Launch and cleanup: Steam activation, overlay controls, launch/stop scripts and per-session FPS logging.

Keep Ambient Occlusion enabled. Metal is the default; `play.sh --renderer=gl` selects the OpenGL fallback. No game executable, Steam account data or DRM bypass is distributed.

## Evidence and limitations

The earlier main-menu comparison was approximately 160 FPS with Metal versus 65 with OpenGL on the test machine. **These are menu results, not a mission benchmark or a performance promise.** A second-Mac installation and longer gameplay/save-load validation remain outstanding.

- [Validation record](release/VALIDATION.md) and [release notes](release/RELEASE-NOTES.md)
- [Technical investigation](installer/TECHNICAL.md) and [diagnostic methodology](METHODOLOGY.md)
- [GameToMac integration recipe](release/GAMETOMAC-INTEGRATION.md)
- [Graphics patch provenance and rebuild instructions](installer/vendor/mtld3d/README.md)
- [Separate native ARM research roadmap](docs/NATIVE-ROADMAP.md)

This release **uses Rosetta**. The experimental no-Rosetta Wine/FEX runtime is not included. An ARM64 runtime does not recompile the proprietary game into an ARM64 game.

## Reporting problems

[Open an issue](https://github.com/Hlbkomer/xcom-mac-fix/issues) with your Mac chip, macOS version, release version, renderer and reproduction steps. Describe whether the problem is in the menu, loading or a mission. Redact account names and personal paths from any log excerpt; do not upload Steam account files or game files.

## Development and credits

```bash
python3 -m unittest discover -s tests -v
python3 tools/package-release.py
```

The archive uses an explicit public file list and includes checksums, installer source and the modified renderer's source archive. See [rebuild-mtld3d.sh](tools/rebuild-mtld3d.sh) for the graphics build recipe.

Thanks to Alexander Theissen (athei), Wine contributors, x87sidecar contributors and mtld3d contributors. Original game by Firaxis/2K; this is an independent community project.

Installer and project documentation: [MIT](LICENSE), © 2026 Hlbkomer. Third-party components retain their own licences; see [licence notes](installer/LICENSE-NOTE.md). The modified mtld3d DLL is clearly marked as an altered zlib-licensed build.
