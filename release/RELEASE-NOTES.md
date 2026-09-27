# XCOM Mac Fix 0.5.1 — release candidate

This release packages the graphics fix used by the working XCOM: Enemy Within
setup on an M1 Max. Metal remains the default; `--renderer=gl` selects OpenGL.

- Include a clean rebuild of the modified mtld3d short-stride DLL with its zlib licence, source
  reference and patch. Fresh installs now receive the fog-of-war/move-highlight fix.
- Verify the actual DLL on each install, preserve the previous DLL as a backup,
  and repair an outdated copy even when a runtime version stamp is present.
- Refuse runtime updates while the target Wine session is running.
- Reject missing helper binaries during preflight.
- Correct the Wine minimum to macOS 15 and update outdated renderer instructions.

The game remains a 32-bit Windows executable running through Rosetta. A native
ARM Wine experiment is separate and is not included or claimed to work.

Gameplay evidence is limited to one M1 Max on macOS 27. The reported ~160 FPS
Metal versus ~65 FPS OpenGL comparison is a main-menu measurement, not a mission
benchmark. A clean install on a second account/Mac and a controlled tactical
benchmark are still needed before claiming broad compatibility.

See `VALIDATION.md` for checks performed on this candidate.
