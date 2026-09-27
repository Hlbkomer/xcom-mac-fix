# XCOM Mac Fix 0.5.2 — security hardening prerelease

Use this release instead of 0.5.1. The game runtime and graphics DLL are unchanged.

- Replace predictable DLL/script staging names with securely created temporary files.
- Refuse symlink destinations and parent components for these writes, backups,
  manifests and downloads, including a DLL symlink with an otherwise valid checksum.
- Resolve install directories before use; reject ambiguous and protected paths.
  Free-mode uninstall requires a matching directory in its manifest.
- Restrict manifest-based launcher deletion to the two expected launchers.
- Restrict downloads and redirects to HTTPS; pin the CI checkout action commit
  and disable persistence of checkout credentials.
- Document debugging entitlements, quarantine handling and upstream trust limits
  in SECURITY.md. Eighteen offline regression tests pass locally.

These changes address local filesystem and accidental deletion risks. They do not
make Wine a sandbox or claim to protect against another process running with the
same account's privileges. Install into a dedicated directory you control. An old
installation using an alias path may need its manifest reviewed before uninstall;
the installer refuses a mismatched manifest rather than guessing.

## Existing runtime changes and validation limits


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
