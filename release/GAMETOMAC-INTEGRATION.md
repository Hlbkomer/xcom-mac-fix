# Enemy Within integration notes

Target: Steam app 200510, expansion executable
`XEW/Binaries/Win32/XComEW.exe`, 32-bit Direct3D 9 / Unreal Engine 3.
The base Enemy Unknown executable has not been validated by this project.

## Runtime recipe

1. Use a Wine runtime containing athei's NX fix. The package pins
   `athei/wine-build cx-26.3.0-6`; exact URLs and hashes are in `installer/install.sh`.
2. Attach x87sidecar only to `XComEW.exe`, using the filter and environment recipe
   in `installer/freewine/`. Do not attach it to Steam or its web helpers.
3. Use mtld3d v0.11.0 plus the included i386 short-stride DLL. Read
   `installer/vendor/mtld3d/README.md` for source/build provenance and checksums.
4. Put this config beside `XComEW.exe`:

```ini
adapter.spoof = nvidia
color.hdr.enable = false
color.space = accurate
```

5. Keep Ambient Occlusion enabled. Start the game through Steam so its lifecycle
   and copy protection work. Verify copied game files once in Steam.
6. Disable the Steam overlay and error reporter as the launcher does. Preserve
   user saves, wait for Steam Cloud on exit, and keep Wine prefixes independent.

No changes to the game's executable or DRM bypass are included. Users supply
their own game and Steam account. Wine's OpenGL d3d9 is the tested fallback.

## Evidence and test scope

The original investigation records ~76,000 faults/s before the NX fix, falling
to about 40 at the menu afterwards. The x87 synthetic speedup is not an FPS
speedup. The renderer comparison (~160 Metal / ~65 OpenGL median) is menu-only.
The confirmed tactical picture uses the short-stride fix and explicit config.
See `installer/TECHNICAL.md`, sections 15–17, for conditions and caveats.

Before claiming GameToMac support, check a fresh Steam installation, a tactical
save, fog edges, move highlights, lighting, audio, input, save/load, clean exit,
fullscreen FPS display, and a longer gameplay session on more than one Mac.

## Native ARM status

The current release uses x86_64 Wine/Rosetta. `docs/NATIVE-ROADMAP.md` records
the separate ARM host / FEX investigation. Neither a native game port nor a
working Rosetta-free Enemy Within runtime is claimed.
