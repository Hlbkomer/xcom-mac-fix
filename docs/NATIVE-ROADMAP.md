# Native ARM research — deferred

The published 0.5.1 installer uses Rosetta. A separate private ARM64 Wine/FEX experiment has loaded Enemy Within saves, but performance is inadequate and loading freezes remain intermittent. It is not included in this release and is not ready for distribution.

The original game remains i386. The experimental pipeline also translates the i386 D3D9 frontend and encoder; its Metal backend is ARM64. Native host components do not guarantee that renderer CPU work runs natively.

Next research steps:

1. Freeze a known baseline and benchmark the same save/camera/settings under Rosetta and FEX, with no debugger during timed captures.
2. Use a performance-enabled renderer build to separate API, encoder, submission, presentation and GPU costs; validate timing calibration under FEX.
3. Use a repeatable renderer-only workload to separate game translation from renderer translation.
4. Fix the measured bottleneck, considering native encoder work only if translated encoding dominates. Do not disable required code validation globally.
5. Validate repeated load/play/save/reload and audio independently, then replace private binary diagnostics with maintainable source fixes and reproducible builds.

No native performance target or release date is promised. The Rosetta release proceeds independently.
