# Security and trust boundaries

## Installer fixes in 0.5.2

Version 0.5.1 used a predictable temporary DLL filename. A pre-existing local
symlink could redirect that write to another file accessible by the user. Its
uninstall protection also compared unnormalized path strings, allowing aliases
to bypass protected-folder checks. Uninstall still required a manifest and
confirmation or `--yes`. No remote exploit or privilege escalation was established.

0.5.2 uses mktemp-created staging files for DLLs and generated scripts, rejects
symlink write paths, resolves install directories, and requires the free-mode
manifest directory to match before removal. Launcher cleanup accepts only its
expected paths. Use 0.5.2 or later. These checks do not create a security boundary
against a process already running as the same user. Use a dedicated installation
directory you control, not a shared writable folder. Symlinked write locations
are refused; old alias-based manifests may need manual review before uninstall.

## Runtime permissions

- Installation runs as your account and refuses root. It does not globally
  disable SIP or Gatekeeper.
- CrossOver mode ad-hoc signs its copied Wine loader with `get-task-allow` so the
  x87 sidecar can attach as a debugger. This relaxes debugging restrictions on
  that copy. It does not re-sign the original CrossOver application.
- The installer removes the quarantine attribute from its installed, hash-checked
  FPS helper. The bundled helpers are not represented as Apple-notarized apps.
- Wine is not a sandbox. Windows programs run with access available to the user;
  the Wine prefix is a compatibility environment, not filesystem isolation.
- Steam stores login state inside the prefix. Do not publish your installed
  prefix, account files or raw diagnostic logs. Review logs before sharing.

## Downloads and release checks

Most runtime downloads and the included graphics DLL have pinned SHA-256 checks.
Steam's changing installer is fetched from Valve over HTTPS; the installer checks
its executable header but does not pin its hash or verify its publisher signature.
HTTPS is required for downloads and redirects. Checksums detect changes relative
to recorded bytes; they do not establish that an upstream program is benign.

Release packaging uses an explicit file allowlist. The reviewed 0.5.1 archive
and nested source had no detected credential patterns, and GitHub reported no
secret-scanning alerts at review time. This was a targeted review, not exhaustive
third-party source or binary analysis or a security certification.

GitHub Actions uses a read-only token, a pinned checkout commit and no persisted
checkout credentials. Gameplay validation limitations remain in release/VALIDATION.md.

## Reporting

Report reproducible installer issues through this repository's issue tracker,
but do not include credentials, Steam account files or unredacted personal logs.
For a potentially exploitable issue, use GitHub's private vulnerability reporting
when available rather than posting exploitation details publicly.
