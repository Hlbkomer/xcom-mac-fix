# Release candidate validation — 27 September 2026

## Completed

- Seven offline regression tests pass: fresh renderer install, idempotent rerun,
  repair despite a stale stamp, byte-preserving dry run, corrupt-payload refusal,
  symlink refusal, plus payload hash and shell syntax checks (seven test methods;
  fresh/rerun and backup checks share methods).
- Real free-mode installer dry run: zero failed checks. Checked pinned public
  download availability and the existing game clone source; no install performed.
- Optional CrossOver installer dry run: zero failed checks; no install performed.
- Rebuilt the graphics DLL from commit `d351032f52e42b32068977658a073e9bd4011c14`
  using Rust 1.98.1, release/i686-msvc with remapped build paths and Wine builtin
  marking. No local user paths found in the resulting DLL.
- Graphics regression in a separate cloned Wine SDK/prefix:
  `streams::stride_below_a_consumed_attribute_still_places_the_triangle`:
  **1 passed, 0 failed**, 859 other tests filtered out. This exercised the rebuilt
  DLL; it did not launch Steam or XCOM.

- The included rebuild script also completed successfully in a second clean directory.
  Its output has a different hash (tool/link metadata is not deterministic), so the
  release records the exact distributed hash and does not promise bit-identical rebuilds.

- Release ZIP CRC and every file in its SHA256SUMS manifest were verified.
- Prebuilt first-party helpers and the release DLL contain no local user paths.

## Still required before broader compatibility claims

- Fresh install on another account/Mac, including Steam login and game verification.
- Tactical gameplay with the release rebuild. The original DLL from the same
  source fix was checked in-game on 26 September; this rebuild has a new checksum.
- Controlled same-save mission benchmark and longer save/load/gameplay session.
- Fullscreen FPS display and compatibility with older supported macOS versions.
- Full upstream renderer suite. Only the specific regression was rerun here;
  no claim that all 860 graphics tests passed.


The candidate remains experimental. Packaging checks do not substitute for a
clean Steam installation or a game benchmark. The working daily-driver install
and its saves were not modified by this release work.

Native ARM runtime research is separate and deferred. Its tests and diagnostics are not release acceptance evidence for this Rosetta package.

## Publication check — 27 September 2026

The seven installer regressions were rerun successfully. A new free-mode dry run reports zero failed checks. The public archive now uses PUBLIC-FILES.json (46 reviewed files), excluding native experiments, probes, runtime prefixes, account data and saves. CRC, exact file membership and all SHA-256 entries pass. The GitHub release is labelled prerelease; the outstanding gameplay and second-Mac checks above still apply.
