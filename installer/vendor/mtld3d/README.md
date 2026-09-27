# XCOM short-stride mtld3d build

This is an altered build of Alexander Theissen's mtld3d, distributed under the
included zlib licence. It is not an official upstream release.

`d3d9.dll` is an i386 Wine builtin rebuilt on 27 September 2026 from the
source fix used for the confirmed tactical test on 26 September. Build paths
are remapped so the release does not disclose local user directories. SHA-256:
`03bee1a57ab20c30345501a2bc7aad9f4c8093e01e4e0c7c6b60a695cc48f7a1`.
The release installer applies it over the pinned upstream v0.11.0 runtime.
It retains the existing DLL under the install's `dl/` directory before replacing it.
Re-running the installer checks the DLL itself, not just a version stamp.

## Source and provenance

- Base: https://github.com/athei/mtld3d/releases/tag/v0.11.0
- Fix source: https://github.com/Hlbkomer/mtld3d/commit/d351032f52e42b32068977658a073e9bd4011c14
- Review: https://github.com/athei/mtld3d/pull/872
- `short-stride.patch`: exact source delta from v0.11.0 to that fix commit.
- Original test: `make test-e2e-i686 FILTER=stride_below_a_consumed` passed,
  followed by an in-game tactical visual check, recorded in TECHNICAL.md section 16.

The original tactical-test DLL has SHA-256 `677cb1e791fbe79ec4cd786ee818e761e37224de05c6c9334759cd94e7ea02a1`.
The release rebuild passed `streams::stride_below_a_consumed_attribute_still_places_the_triangle`
(1 passed, 0 failed) in an isolated Wine SDK/prefix. It has not yet been checked
in a fresh tactical game session. Bit-for-bit reproduction is not claimed. The later XCOM automatic
profile commit was not part of the tested build. The launcher supplies those
settings explicitly in `mtld3d.conf`.

## Rebuilding

`source.tar.gz` is the exact git archive of the fix commit, with SHA-256
`6b027f803449ed315f71031d7610c41e80b568954d2cbbdf59a9642b1da415f1`.
`../../../tools/rebuild-mtld3d.sh` records the release build recipe: Rust 1.98.1,
release profile, i686 MSVC target, path remapping, then Wine builtin marking.
It builds only the modified d3d9 DLL; the shim and Unix module come from the pinned
upstream runtime. It needs the upstream prerequisites and does not install them.


Check out the fix commit in a separate checkout and follow its README and
CONTRIBUTING.md for Rust, the Windows SDK and Wine SDK requirements. Build the
32-bit Windows component with `make windows-i686 WINE_SDK=/absolute/path/to/sdk`.
The upstream install target applies the Wine builtin marking and renames the
output; use an isolated SDK (`ISOLATED=1`) for install and graphics tests. Do not
replace a live game runtime while it is running. Rebuilt binaries require a new
checksum and a new tactical test before release.
