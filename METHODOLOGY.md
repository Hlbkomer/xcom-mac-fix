# Fixing a slow or broken Windows game on Apple Silicon (without VMs)

A step-by-step method, written after making XCOM: Enemy Within go from ~5 fps to playable (details:
`installer/TECHNICAL.md`). It is meant for the **next** game: the steps are in the order we would apply them, with
the commands that worked and the traps we hit. It assumes Wine-based runners (CrossOver or a free Wine build) on
an Apple Silicon Mac with Rosetta 2. No virtual machines, no system-wide changes, no admin rights unless noted.

Copyright (c) 2026 Hlbkomer, MIT License (see `installer/LICENSE`).

## Contents

1. [Ground rules: backups and safe side-by-side setups](#1-ground-rules-backups-and-safe-side-by-side-setups)
2. [Identify the game](#2-identify-the-game)
3. [Baseline: fps, CPU, page faults, rwx regions](#3-baseline-fps-cpu-page-faults-rwx-regions)
4. [Classify the problem](#4-classify-the-problem)
5. [NX / no-exec fault storm](#5-nx--no-exec-fault-storm)
6. [x87 floating point under Rosetta](#6-x87-floating-point-under-rosetta)
7. [Graphics: d3d renderer switching, freezes, black screens](#7-graphics-d3d-renderer-switching-freezes-black-screens)
8. [Hangs and crashes: sample, lldb, Wine debug channels, game logs](#8-hangs-and-crashes-sample-lldb-wine-debug-channels-game-logs)
9. [DRM and cloned prefixes (Steam CEG and friends)](#9-drm-and-cloned-prefixes-steam-ceg-and-friends)
10. [Where to run it: patched CrossOver clone or a free Wine build](#10-where-to-run-it-patched-crossover-clone-or-a-free-wine-build)
11. [Launcher hygiene: Steam, overlay, crash dialogs, leftovers](#11-launcher-hygiene-steam-overlay-crash-dialogs-leftovers)
12. [Measure the result and compare fairly](#12-measure-the-result-and-compare-fairly)
13. [Document, redact, report upstream](#13-document-redact-report-upstream)
14. [Gotchas (short list)](#14-gotchas-short-list)

---

## 1. Ground rules: backups and safe side-by-side setups

Do these **before** touching anything:

- **Never modify the originals.** Treat `/Applications/CrossOver.app` and the user's working bottle as read-only.
  Work on copies:
  - APFS clones cost almost no space and never change the source: `cp -cR SRC DST` (clonefile). Clone
    `CrossOver.app/Contents/SharedSupport/CrossOver` to patch Wine; clone a game folder for a second prefix.
  - A separate prefix (`WINEPREFIX=…`) or a separate CrossOver bottle for experiments.
- **Timestamped backups of anything you edit** that is not a clone: launchers, scripts, game `.ini` files.
  `mkdir -p backup-$(date +%Y%m%d-%H%M) && cp -p FILE… backup-…/`. For patched binaries, keep `FILE.orig` next to
  the patched file and record both sha256s.
- **Patch by pattern, verify by hash.** Find the bytes by a pattern, refuse unless there is exactly one match,
  check the file's hash against known versions, and keep the original.
- **One Steam (one Wine session using the same account) at a time.** Two Steam clients under two Wines fight over
  the account, the cloud saves and the game files. Before every live test, check that nothing from either setup
  runs, and never kill anything while someone might be playing (check user idle time:
  `ioreg -c IOHIDSystem | awk '/HIDIdleTime/{print int($NF/1e9); exit}'` seconds).
- **Saves live outside the prefix** for many games (`~/Documents/My Games/…` is often shared by both setups).
  Back them up before experiments.
- **Keep a log of every step**: what you changed, the command, the result, the time. The final documentation is
  mostly this log cleaned up.

## 2. Identify the game

| Question | How | Why it matters |
|---|---|---|
| 32-bit or 64-bit? | `file Game.exe` (`PE32` = 32-bit, `PE32+` = 64-bit), or the PE `Machine` field (0x14c i386, 0x8664 x64) | 32-bit games run through Wine's WoW64 and Rosetta; old 32-bit compilers use x87 (section 6) |
| Which graphics API? | imports: `objdump -p Game.exe \| grep -i 'DLL Name'` (Xcode's llvm-objdump reads PE), or `strings -a Game.exe \| grep -iE 'd3d(8|9|10|11|12)\|opengl32\|vulkan'` | picks the renderer options (section 7) |
| Engine and year | `strings`, the game's log folder, `*.ini` | known issues per engine (e.g. UE3 = 32-bit x87, D3D9) |
| NX_COMPAT on the exe **and every DLL** | the script below | one DLL without it can trigger the fault storm (section 5) |
| DRM | Steam CEG, SteamStub, Denuvo, launcher programs | cloned prefixes may fail (section 9) |
| Launcher program? | what Steam starts first (often a .NET launcher) | needs Wine Mono; may need automating |

PE NX_COMPAT check (DllCharacteristics bit 0x0100; offset 70 in the optional header for both PE32 and PE32+):

```bash
python3 - "$GAME_DIR" <<'EOF'
import os, struct, sys
for root, _, files in os.walk(sys.argv[1]):
    for n in files:
        if not n.lower().endswith(('.exe', '.dll')): continue
        p = os.path.join(root, n)
        try:
            with open(p, 'rb') as f:
                d = f.read(4096)
            o = struct.unpack_from('<I', d, 0x3C)[0]
            if d[o:o+4] != b'PE\0\0': continue
            mach = struct.unpack_from('<H', d, o + 4)[0]
            dllch = struct.unpack_from('<H', d, o + 24 + 70)[0]
            print(f"{'NX ' if dllch & 0x100 else 'NO-NX'}  {hex(mach)}  {os.path.relpath(p, sys.argv[1])}")
        except Exception:
            pass
EOF
```

Any `NO-NX` DLL that the game actually loads is a suspect. (XCOM: four `NO-NX` DLLs in the folder; the two that
are loaded, `cudart32_30_9.dll` and `PhysXExtensions.dll`, showed up in `warn+module` as `disabling no-exec
because of …`.)

## 3. Baseline: fps, CPU, page faults, rwx regions

Measure the unmodified setup first, in a repeatable spot (the main menu is fine for pathologies; not for fps
comparisons).

- **Find the game process.** Under Wine, `ps -axo pid,args` shows Windows paths (`C:\…\Game.exe`). If two Wines
  are installed, confirm which one owns it: `lsof -a -p PID -d txt -Fn` prints the executable image path.
- **CPU, page faults, context switches, Mach messages:**
  `top -l 5 -s 1 -c d -pid PID -stats pid,cpu,faults,csw,msgsent` (`-c d` = per-interval deltas). A healthy game
  at a menu shows tens of faults/s; **tens of thousands per second with one core pinned** means a fault storm.
- **Writable+executable regions:** `vmmap PID | grep -c ' rwx/'` (and sum the sizes). A few (JIT, thunks) is
  normal; hundreds is not. Compare with a well-behaved process in the same prefix (e.g. `steam.exe`).
- **fps**: see section 12 for how to get numbers on each renderer.
- Save each measurement with the time and the setup it came from.

## 4. Classify the problem

| Observation | Likely class | Go to |
|---|---|---|
| Very low fps, one core ~100%, huge page-fault rate, many rwx regions | NX fault storm | 5 |
| Low fps, normal faults, CPU-bound in translated code, 32-bit pre-2013 game | x87 emulation | 6 |
| Black screen, missing effects, freeze at the first 3D scene, GPU timeouts in the game log | renderer | 7 |
| Hang (0% CPU or a thread spinning), crash, crash dialog | debugging | 8 |
| Game exits cleanly 2–5 s after start, empty game log | DRM / copied files | 9 |
| Game works but Steam hangs, dialogs on exit, processes left over | launcher plumbing | 11 |

Fix one class at a time and re-measure after each fix; several can stack (XCOM had NX, x87 and a renderer
freeze, then a settings-dependent crash).

## 5. NX / no-exec fault storm

**Mechanism.** Wine's loader turns data-execution prevention off for the **whole process** as soon as it loads
any module without `NX_COMPAT` (`alloc_module()` in `dlls/ntdll/loader.c`; this is upstream Wine behaviour). With
no-exec off, Wine maps readable memory as executable too. Rosetta must watch writable+executable pages for
self-modifying code, so writes to them cost a Mach exception round trip. The game spends its time in fault
handling.

**Confirm:**
- `WINEDEBUG=warn+module` → `disabling no-exec because of <dll>`.
- The rwx count and fault rate from section 3.
- The NX script from section 2 names the DLLs.

**Fix options:**
- A Wine build with a source fix. athei's commit
  [539aa62](https://github.com/athei/wine/commit/539aa62220ad23a390ce9f2a1c99ee5d3831907b) lets only the main
  executable decide and keeps no-exec on under Rosetta (`WINE_DISABLE_NX_COMPAT=0` turns that off).
- In a **clone** of CrossOver: a 1-byte patch in the i386 `ntdll.dll` (`jne` → `jmp` after the
  `test byte [reg+0x5f],1` NX_COMPAT test), found by pattern, exactly one match, `.orig` kept. This ignores even
  the main exe's flag, so it is a targeted workaround, not a general fix.
- Not a fix: setting NX_COMPAT in the DLL headers (changes game files, breaks signatures/DRM).

**Verify:** rwx regions drop to a handful, faults to tens per second, and load times fall sharply.

**Gotcha:** games whose **exe** needs executable data (old SteamStub `.bind` sections) do need no-exec off; that
is why the main executable's flag must still be honoured by a general fix.

## 6. x87 floating point under Rosetta

**Detect:**
- 32-bit games built with older MSVC (`/arch:IA32` default before VS2012) or engines of that era use the x87 FPU.
- Count x87 instructions in the code (a heuristic; takes a while for big files):
  ```bash
  objdump -d --no-show-raw-insn Game.exe | awk '{print $2}' \
    | grep -cE '^f(ld|st|stp|add|sub|mul|div|xch|com|ucom|chs|abs|sqrt|sin|cos|patan|ild|ist|istp)[a-z]*$'
  ```
  Compare with SSE (`grep -cE '^(movs[sd]|adds[sd]|muls[sd])$'`). Tens of thousands of x87 instructions in a
  hot engine is a strong hint (XCOM's `XComEW.exe`: ~97,000 x87 vs ~175,000 of those SSE instructions; ~6 s on
  an M1 Max). Xcode's objdump prints AT&T mnemonics (`flds`, `fstpl`), hence the `[a-z]*` suffix.
- After the NX fix, the game is still CPU-bound in translated code.

**Fix:** [x87sidecar](https://github.com/athei/x87sidecar) (MIT) patches Rosetta's x87 translation inside the
target process. `x87sidecar --probe` must say `supported` for your Rosetta version.
- In athei's Wine build: a cooperative hook (`ROSETTA_X87_PATH`) for 32-bit processes. Point it at a small filter
  script so **only the game** gets the sidecar (Steam passes its environment to every child).
- In a CrossOver clone: wrap `lib/wine/x86_64-unix/wine` with a script that execs the sidecar for the game only;
  the real loader must be re-signed ad hoc with `get-task-allow` for `task_for_pid` attach (macOS may ask for the
  developer-tools password once per login).

**Verify:** a micro-benchmark (XCOM: synthetic x87 loop 10,993 ms → 159 ms), then fps in the game. Re-check
after macOS updates: the sidecar depends on Rosetta internals (`--no-x87`-style fallback in every launcher).

## 7. Graphics: d3d renderer switching, freezes, black screens

Renderers for D3D8/9/10/11 under Wine on macOS (availability depends on the Wine build):

| Renderer | Path | How to select |
|---|---|---|
| wined3d (built-in) | D3D → OpenGL → Apple's GL-on-Metal (or Vulkan if the build has it) | CrossOver: `--dll d3d9=b` per session, or the bottle's DLL overrides; generic: `WINEDLLOVERRIDES=d3d9=b` |
| DXVK / d9vk | D3D → Vulkan → MoltenVK → Metal | native `d3d9.dll` in `syswow64`/`system32` + `d3d9=native,builtin` |
| D3DMetal (GPTK), DXMT, mtld3d | D3D → Metal directly | CrossOver bottle graphics setting; athei's build: compatdb rule, e.g. `WINE_COMPATDB=$'v=3\nname=rule;exe=Game.exe;d3d9=wined3d'` |

Method:
1. Try every renderer the build offers for this D3D version, **per game exe only** (don't change Steam's).
2. Note black screens, freezes, missing effects and fps for each; read the game's own log (e.g. UE3
   `Launch.log`: `Timed out while waiting for GPU to catch up`).
3. Re-test renderers after fixing CPU problems: a renderer that "fixed" a black screen earlier may no longer be
   needed, and one that failed may work.
4. **Check what the build really contains before planning.** Look for `winevulkan`/`vulkan-1` and `libMoltenVK`
   in the Wine tree (and the build's configure flags, e.g. `--without-vulkan`): without them, DXVK and wined3d's
   Vulkan renderer are impossible, whatever the docs of other builds say. Check which D3D versions each Metal
   layer covers (D3DMetal and DXMT: d3d10/11/12 only; mtld3d: d3d9).
5. **A "doesn't work" may be a version problem.** Translation layers move fast: XCOM refused the Wine build's
   bundled mtld3d v0.7.0 but ran with the current v0.11.0 at twice the menu fps. Check the layer's
   releases (and which Wine build its CI tests against) before writing a renderer off. Never write down "froze"
   or "broken" without a log or sample that shows it.
6. **Capability checks look like crashes.** Old games query formats at start
   (`CheckDeviceFormat(… D3DUSAGE_QUERY_POSTPIXELSHADER_BLENDING, D3DFMT_A16B16G16R16F)`) and quit with a message
   box when the answer is no. If the game "exits" right after start with every thread idle and the main thread in
   `wait_message`, look for a dialog: without Screen Recording permission, a tiny Windows program run in the same
   prefix can list the windows (`EnumWindows`, `GetWindowText` on the dialog and its children) and print the text.

Known trap: Metal and MoltenVK create their own threads (`com.Metal.CompletionQueueDispatch`) that have **no Wine
TEB**. Older Wine signal handlers fault on such threads and loop (a freeze with one thread spinning in the signal
handler). Upstream Wine added handling in 2026 (`0f82d287`, `5fe9b20f`); builds without it should stay on a
renderer that doesn't trigger it.

Also check game settings that interact with the renderer: turning effects *off* can crash (XCOM crashed at
mission start with Ambient Occlusion off under wined3d). Go back to the defaults before blaming the renderer.

Two further traps that showed up with mtld3d on an Unreal Engine 3 game, and that apply to other D3D9 engines:

7. **Vendor identity.** Engines pick a depth-copy path from `GetAdapterIdentifier` (NVIDIA: INTZ + a RESZ draw; AMD: a different one) and skip it for a vendor they do not know. Effects that reconstruct position from depth (dynamic lights, light shafts, ambient occlusion, depth of field) then read a buffer nothing writes. Compare `Launch.log` (or the equivalent) across renderers. If the working renderer reports NVIDIA or AMD and the broken one reports the real GPU, spoof the vendor the translation layer actually implements. mtld3d's key is `adapter.spoof = nvidia` in `mtld3d.conf` next to the exe.
8. **A stride warning is a picture bug until proved otherwise.** If the layer logs that it widened a vertex stride to cover a declaration the shader consumes, it is reading later vertices from the wrong offset. Overlays (fog of war, range highlights) blow up into fans while world meshes, which use another layout, stay fine. Screenshot the overlay and keep the log. Do not file the line as harmless because the game did not crash.

## 8. Hangs and crashes: sample, lldb, Wine debug channels, game logs

- **`/usr/bin/sample PID 5 -file /tmp/game.sample.txt`**: all threads' stacks for 5 s without stopping the game for long.
  Look for a thread at 100% in one place: Wine's signal handler (TEB-less thread), a spin on a critical section,
  Rosetta runtime frames. Take two samples a few seconds apart.
- **`lldb -p PID`**, then `thread list`, `bt all`, `detach`. It stops the process while attached. Attaching needs
  `task_for_pid`: binaries with the hardened runtime and no `get-task-allow` refuse; a cloned, ad-hoc re-signed
  loader with `get-task-allow` works. Expect partial stacks in translated x86 code.
- **Wine debug channels** (`WINEDEBUG`, restricted to the game process by the filter/wrapper, never globally
  under Steam, because the logs explode):
  - `warn+module`: DLL loading, `disabling no-exec because of …`
  - `+seh`: exceptions (access violations with addresses, handled vs unhandled)
  - `+loaddll`: which DLLs (native/builtin) load
  - `+fps`: wined3d/OpenGL frame rate every ~1.5 s (cheap; use it for measurement)
  - `+d3d`, `+relay`: very heavy, last resort, short runs only
- **Game crash dumps and logs**: minidumps (`*.dmp`) in the game's log folder; open the exception address and
  module. Wine's `winedbg` crash dialog text names the crashing program (it may not be the game).
- **Unified log** for macOS-side events: `/usr/bin/log show --last 5m --predicate 'process CONTAINS "wine"'`
  (in zsh, `log` is a builtin; use the full path).
- A clean `All Windows Closed`/`appRequestExit(0)`-style exit means the game was *asked* to quit (window close,
  quit request), not a crash; look at what else ran at that moment (e.g. overlay processes).

## 9. DRM and cloned prefixes (Steam CEG and friends)

- Steam **CEG** binds executables to the Steam install that delivered them. A game folder cloned into another
  prefix **exits cleanly 2–4 s after start** with an empty log (with `+seh`: one write access violation at the
  image base, then exit). The original install passes with any Wine.
- **Fix:** in the new prefix run `steam://validate/<appid>` (Verify integrity of game files) once: Steam reports
  some files "failed to validate", re-downloads the protected executables, and the game starts. Automate it and
  wait for `AppID <appid> scheduler finished` in `logs/content_log.txt`.
- Alternatively run the **real** bottle through the patched Wine (CrossOver-clone approach): no validation needed.
- **Direct launch** (`wine Game.exe` with `SteamAppId=SteamGameId=<appid>`, Steam running and logged in) can
  pass CEG, but Steam may lose track of the game (`BMainLoop appears to have stalled`). Launching through Steam
  (`steam -applaunch <appid>`) and clicking a game launcher automatically keeps Steam as the parent.
- Never hand-edit protected executables.

## 10. Where to run it: patched CrossOver clone or a free Wine build

**Patched CrossOver clone** (the user's licensed CrossOver): clone `SharedSupport/CrossOver`, patch the clone,
point the bottle's run at the clone's `bin/wine` with `CX_BOTTLE_PATH` and `--bottle NAME`. Pros: the real
bottle, no re-validation, CrossOver's tuned Wine. Cons: binary patches per CrossOver version, the EULA question,
re-apply after updates.

**Free Wine build.** Choose one that:
- contains the fixes you need in source (e.g. the NX fix, an x87 hook, TEB-less signal handling);
- supports 32-bit (WoW64) and your macOS version;
- publishes release archives you can **pin by sha256**, and states its licence (Wine is LGPL-2.1+);
- has a way to choose the renderer per exe (athei's `WINE_COMPATDB` rules; check its default compatdb choices in
  the log: `compatdb: d3d9 = …`);
- needs Wine Mono / Gecko versions you can also pin.
After download: `xattr -dr com.apple.quarantine <dir>`, then a fresh prefix, Steam's silent install
(`SteamSetup.exe /S`), and the user logs in themselves. Detect Steam login readiness from
`HKCU\Software\Valve\Steam\ActiveProcess\ActiveUser` (non-zero), not with fixed sleeps.

Running both side by side is fine: separate prefixes, one Steam at a time, shared saves.

## 11. Launcher hygiene: Steam, overlay, crash dialogs, leftovers

- **Settings travel with Steam.** Steam passes its environment to the game, so per-game settings must be in
  place when Steam starts. Record the settings a Steam was started with; restart Steam if they differ.
- **Per-process settings through one filter.** A wrapper (x87 hook target or loader wrapper) that matches the game
  exe applies the sidecar, `+fps` and debug channels to the game only.
- **Identify processes by executable path, not by name.** Windows names are the same in every Wine. Use
  `lsof -a -p PID -d txt -Fn` (image inside *this* setup's Wine) for game/Steam processes, and
  `ps -axo comm=` (full executable path on macOS) for wineservers. `pgrep -f wineserver` also matches any shell,
  editor or `tail` whose arguments contain the word, and can block a launcher by mistake.
- **Steam overlay:** under Wine it may start `gameoverlayui` repeatedly; in XCOM it lined up with the game closing
  itself once. Disable with `WINEDLLOVERRIDES=gameoverlayrenderer=d;gameoverlayrenderer64=d;gameoverlayui.exe=d;gameoverlayui64.exe=d`
  and offer an opt-in.
- **Crash-reporter dialogs on Steam exit:** Steam.exe can crash late in its shutdown; its reporter
  (`steamerrorreporter64.exe`) can then crash in Wine's dbghelp and pop a "Program Error" dialog. Disable the
  reporter (`steamerrorreporter64.exe=d;steamerrorreporter.exe=d`) and set
  `HKCU\Software\Wine\WineDbg\ShowCrashDialog=0` in the prefix.
- **Stopping:** ask first (`wine taskkill /im Game.exe` sends WM_CLOSE), then TERM/KILL, then `steam -shutdown`
  with a timeout, then `wineserver -k`.
- **Orphans:** after a killed wineserver, Wine processes can survive, spin at 100% CPU and write gigabytes of
  errors. When no wineserver of the setup runs, kill every process whose image is inside that setup's Wine
  (check with `lsof` first). Do it after shutdown and before each start.
- **Launcher automation:** a tiny helper (e.g. a Windows program run in the prefix) can press the game launcher's
  button; target only that window by title.

## 12. Measure the result and compare fairly

- **Getting fps on each renderer:**
  - wined3d: `WINEDEBUG=+fps` (game only) prints `@ approx NN.NNfps` about every 1.5 s. The first line of a
    session is `0.00fps` (timer starts at zero): ignore it. `wglSwapBuffers` and `wined3d_cs_exec_present` both
    report; count one source only.
  - DXVK: `DXVK_HUD=fps` (draws in the game).
  - Metal-native renderers (D3DMetal, DXMT, mtld3d): `MTL_HUD_ENABLED=1`. It draws **nothing** on the GL path
    (wined3d); don't rely on it there.
  - Metal HUD as a logger: `MTL_HUD_ENABLED=1 MTL_HUD_LOG_ENABLED=1` (game process only) writes about once per
    second to the macOS log, subsystem `com.apple.metal.hud`: `metal-HUD: <frame number>,<memory>,…<private>`.
    macOS redacts the frame timings as `<private>`, so compute fps from two lines: frame-number difference / time
    difference. Follow it with `/usr/bin/log stream --style compact --predicate 'processID == PID AND subsystem ==
    "com.apple.metal.hud"'`. `MTL_HUD_OPACITY=0` hides the overlay while logging goes on. It's also available
    after the fact: `/usr/bin/log show --start … --predicate …` rebuilds a session's fps.
  - An overlay-free display: a small native window (borderless, click-through, non-activating, above the game)
    that reads the trace, e.g. this project's `fpsbar`. Without Screen Recording permission, verify it with the
    window list (`CGWindowListCopyWindowInfo`: box on screen, in front of the game window).
- **Log to CSV** (`time,elapsed_s,fps`), one line per sample, flushed per line (negligible cost). At the end,
  summarise: duration, average, median, 1% low (or min), max, samples; skip the first ~10 s of loading, and say
  that interval averages are not frame times.
- **Fair comparison protocol:** same save and spot, same settings and resolution, nothing else heavy running, on
  power, 2–3 minutes per run, alternating A B A B (2–3 rounds), compare medians and the spread across rounds.
  Menu numbers and single runs are not benchmarks (intro movies, transitions and load hitches dominate them).

## 13. Document, redact, report upstream

- Write down each problem with its evidence (commands, numbers, log lines), the fix, and how it was verified.
- **Redact** before sharing: user names, home paths, Steam account names and IDs, machine names, serials, IPs.
  Grep the whole package (including binaries: `strings`) for them.
- Draft bug reports for the right upstream (Wine, the Wine build's author, CodeWeavers) with minimal repro steps.
  Check upstream first: the fix may already exist (XCOM: TEB-less signal handling and the dbghelp division were
  already fixed upstream).
- Provide an installer with `--dry-run`, resumability, pinned downloads, a manifest, and an uninstaller that only
  removes unchanged files.

## 14. Gotchas (short list)

- One DLL without NX_COMPAT disables no-exec for the whole process (Wine); Rosetta makes that very expensive.
- `top` fault counts are cumulative unless you use delta mode (`-c d`).
- Cloned game folders fail Steam CEG until validated; the failure looks like a clean exit after 2–4 s.
- Steam's environment reaches every child: set per-game options through a filter, and restart Steam when they change.
- `pgrep -f NAME` matches unrelated shells; identify Wine processes by executable path.
- Metal HUD is invisible on wined3d/OpenGL; use Wine's `+fps` channel there. On Metal renderers its log works, but
  the per-frame timings are redacted: use the frame counter.
- A build without `winevulkan`/MoltenVK can't run DXVK; check the tree before testing.
- Bundled translation layers can be months behind their own releases; a newer release may fix a start-up check.
- A game that "exits" or "freezes" right after start may be showing a message box: list its windows.
- `sample` on the PATH may be a different program (a Python tool, say): use `/usr/bin/sample`.
- Background jobs started from a remote or scripted shell can die when that shell exits: start long-lived helpers
  from the launcher (e.g. a Terminal `.command` file), not from the controlling session.
- A game window that opens takes the keyboard focus: keystrokes meant for another app can reach the game menu.
  Measure with nobody typing.
- The first `+fps` sample is `0.00`; both `wglSwapBuffers` and `wined3d_cs_exec_present` print each interval.
- Turning graphics effects off can crash old engines under Wine; start from defaults.
- The Steam overlay and Steam's crash reporter cause trouble under Wine; disable them by DLL override.
- A killed wineserver can leave spinning orphans; sweep them.
- In zsh, `log` is a builtin: use `/usr/bin/log`.
- Attaching `lldb`/`task_for_pid` to hardened binaries fails; use an ad-hoc re-signed clone with `get-task-allow`.
- A fix that makes a renderer work may make an earlier workaround unnecessary; re-test old choices after each fix.
- Never kill a live session without checking that nobody is playing.
