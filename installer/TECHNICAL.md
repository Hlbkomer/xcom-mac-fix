# XCOM: Enemy Within on Apple Silicon: technical notes and evidence

This is the investigation behind xcom-mac-fix: what was measured, what was tried, and why the scripts work the way
they do. Everything was measured on **one machine**: MacBook Pro M1 Max (32 GB), macOS 27.0 (26A428), Rosetta 2.
The game was the Steam version of XCOM: Enemy Unknown + Enemy Within (app 200510, build 848157, UE3 "Version: 8917"),
`XEW/Binaries/Win32/XComEW.exe` (32-bit). Wine: CrossOver 26.0.0.39794 and athei/wine-build `cx-26.3.0-6`
(sha256 `11cb278a82ba8c2e7563c02afd7fb369702ca193b0b3ebfc8db22e771900ce37`), with athei's mtld3d v0.11.0 for the Metal
renderer tests (section 16). Times are rounded; "fps" statements are the
tester's observations unless marked as measured.

## Contents

0. [History: what was done, in order](#0-history-what-was-done-in-order)
1. [Symptom and baseline](#1-symptom-and-baseline)
2. [Root cause 1: NX (no-exec) fault storm](#2-root-cause-1-nx-no-exec-fault-storm)
3. [Root cause 2: x87 under Rosetta](#3-root-cause-2-x87-under-rosetta)
4. [Root cause 3: d3d9 freeze (DXVK/MoltenVK) and the d3d9 choice](#4-root-cause-3-d3d9-freeze-dxvkmoltenvk-and-the-d3d9-choice)
5. [Ambient Occlusion crash](#5-ambient-occlusion-crash)
6. [Steam CEG and cloned installs](#6-steam-ceg-and-cloned-installs)
7. [The error dialog after Steam > Exit](#7-the-error-dialog-after-steam--exit)
8. [Steam main-loop stalls, direct launch vs Steam launch](#8-steam-main-loop-stalls-direct-launch-vs-steam-launch)
9. [Free-mode launcher design](#9-free-mode-launcher-design)
10. [Test runs](#10-test-runs)
11. [CrossOver mode details](#11-crossover-mode-details)
12. [The game closing itself, and the Steam overlay](#12-the-game-closing-itself-and-the-steam-overlay)
13. [Leftover Wine processes after a killed wineserver](#13-leftover-wine-processes-after-a-killed-wineserver)
14. [FPS counter](#14-fps-counter)
15. [FPS in CrossOver mode, FPS logging and comparison](#15-fps-in-crossover-mode-fps-logging-and-comparison)
16. [Other d3d9 paths: Vulkan/DXVK, D3DMetal, mtld3d](#16-other-d3d9-paths-vulkandxvk-d3dmetal-mtld3d)
17. [Open questions](#17-open-questions)

## 0. History: what was done, in order

| # | Step | Outcome | Section |
|---|---|---|---|
| 1 | **Black screen** in CrossOver with the stock d3d9 | Before this investigation, a DXVK d3d9.dll ("d9vk", a DXVK 1.10.3 async macOS build) was put into the bottle's `syswow64` with `d3d9=native,builtin` (plus `DXVK_ASYNC=1`, `DXVK_HUD=fps` in `cxbottle.conf`). That made the game render. The cause of the black screen was not investigated. Today both modes use the built-in d3d9 (wined3d) together with the NX fix, and it renders. | 4 |
| 2 | **~5 fps**, one core pinned | Measured: ~76,000 page faults/s, 931 rwx regions | 1 |
| 3 | **NX fault storm** found | Two DLLs without `NX_COMPAT` switch no-exec off for the process; Rosetta pays for every write to a W+X page. Fixed by a 1-byte `ntdll.dll` patch in a CrossOver clone, and by athei's source fix in the free build | 2 |
| 4 | **x87 sidecar** | x87sidecar attached to `XComEW.exe` only (task_for_pid in CrossOver mode, cooperative hook in free mode) | 3 |
| 5 | **d9vk freeze** at the main menu | Wine's signal handler faulted on a macOS Metal thread without a TEB; switched the game to built-in d3d9 for the session | 4 |
| 6 | **Ambient Occlusion crash** at mission start | Keep AO (and DoF, light shafts, lens flares) on | 5 |
| 7 | **CEG and cloned bottles** | Cloned game folders quit after 2–4 s until Steam re-validates them; CrossOver mode runs the real bottle | 6 |
| 8 | **Free-Wine path** | athei/wine-build `cx-26.3.0-6` (NX fix + x87 hook built in), own prefix, installer, launchers | 9, 11 |
| 9 | **Crash-reporter dialog** after Steam > Exit | Steam's error reporter crashed in dbghelp; disabled, plus Wine crash dialog off | 7 |
| 10 | **Game closed itself** (overlay) | Steam overlay off by default | 12 |
| 11 | **Orphan cleanup** | Processes that outlived a killed wineserver are swept | 13 |
| 12 | **FPS box** (`fpsbar`) | Native AppKit box fed by wined3d's `+fps` trace; the user confirmed it is visible | 14 |
| 13 | **FPS in CrossOver mode + comparison logging** | Same box and a per-session CSV + summary in both modes; `compare-fps.sh` | 15 |
| 14 | **Other renderers** (v0.5.0) | No Vulkan in the build, so DXVK and wined3d-Vulkan are out; D3DMetal has no d3d9. The bundled mtld3d v0.7.0 fails XCOM's fp16-blending check; mtld3d **v0.11.0** runs the menu at ~160 fps vs ~65 with wined3d/GL (back-to-back, +145%). A tactical mission needs `mtld3d.conf` (NVIDIA spoof, SDR present) and the short-stride fix in mtld3d PR 872. Visuals confirmed; **mtld3d is the default**, `--renderer=gl` is the fallback | 16 |

The general method behind these steps, written for the next game, is in `../METHODOLOGY.md`.

## 1. Symptom and baseline

In CrossOver 26.0 (win64 bottle, Steam, stock settings), XCOM ran at roughly **5 fps** at the main menu and in
the game. `XComEW.exe` pinned one core at ~97%. `top -pid <pid> -stats pid,cpu,faults,csw,msgsent`:

| | before any fix | after the NX fix |
|---|---|---|
| page faults/s | **~76,000** | ~40 at the main menu (free build) |
| context switches/s | ~158,000 | – |
| Mach messages sent/s | ~300,000 | – |
| rwx regions (`vmmap <pid> \| grep -c ' rwx/'`) | **931 (~495 MB)** | **3 (~32 MB)** |

For comparison, `steam.exe` in the same bottle had 0 rwx regions.

## 2. Root cause 1: NX (no-exec) fault storm

### What Wine does

`alloc_module()` in `dlls/ntdll/loader.c` runs for every module that is loaded. Current upstream master
(checked 2026-09-26, lines 1597-1602):

```c
    if (!(nt->OptionalHeader.DllCharacteristics & IMAGE_DLLCHARACTERISTICS_NX_COMPAT))
    {
        ULONG flags = MEM_EXECUTE_OPTION_ENABLE;
        WARN( "disabling no-exec because of %s\n", debugstr_w(wm->ldr.BaseDllName.Buffer) );
        NtSetInformationProcess( GetCurrentProcess(), ProcessExecuteFlags, &flags, sizeof(flags) );
    }
```

So **one module without `NX_COMPAT` turns no-exec off for the whole process**, from then on. With no-exec off,
Wine's virtual memory code gives every readable mapping `PROT_EXEC` too. This is **upstream Wine behaviour**, not
something CrossOver added. CrossOver 26.0's i386 `ntdll.dll` contains the same logic (file offset `0x4113B`, RVA
`0x41D3B`: `test byte [eax+0x5f],1` / `jne` / `mov [ebp-0x14],2` / `NtSetInformationProcess(-1, 0x22, …)`).

Context: the call was made to work under WoW64 by [wine!500](https://gitlab.winehq.org/wine/wine/-/merge_requests/500)
(2022). Its stated purpose was old Steam DRM whose **EXE** entry point sits in a non-executable `.bind` section.
[wine!11253](https://gitlab.winehq.org/wine/wine/-/merge_requests/11253) (2026) added a WoW64 CPU-backend notification
for DEP changes at runtime (BioShock). Neither changes the rule that any DLL can switch no-exec off.

On Windows, the process DEP policy follows the **main executable's** `NX_COMPAT` flag (plus system policy).
Loading a DLL without the flag doesn't turn DEP off.

### Why it hurts under Rosetta

XCOM's `XComEW.exe` **has** NX_COMPAT. Two DLLs it loads don't: `cudart32_30_9.dll` and `PhysXExtensions.dll`
(`WINEDEBUG=warn+module` shows `disabling no-exec because of …`). From then on, heap and other writable mappings
are also executable. Under Rosetta 2, a page that is writable **and** executable must be watched for
self-modifying code, so the first write after translation costs a Mach exception round trip. The game spends
most of its time in fault handling (the numbers in section 1).

### Fixes

- **athei's source fix** [athei/wine@539aa62](https://github.com/athei/wine/commit/539aa62220ad23a390ce9f2a1c99ee5d3831907b),
  in wine-build `cx-26.3.0-6`, has two parts:
  1. `alloc_module()` only lets the **main executable** (`hModule == Peb->ImageBaseAddress`) turn no-exec off.
  2. Under Rosetta (`sysctl.proc_translated`), no-exec is `MEM_EXECUTE_OPTION_PERMANENT`, so
     `NtSetInformationProcess(ProcessExecuteFlags)` returns `STATUS_ACCESS_DENIED`.
     `WINE_DISABLE_NX_COMPAT=0` turns that off; any other value forces it on every host.
- **CrossOver mode:** a 1-byte diagnostic-style patch in a *clone* of CrossOver's i386 `ntdll.dll`: `jne` → `jmp`
  (`75`→`EB`) at `0x4113F` (found by pattern), so no-exec is never turned off. For XCOM the effect is the same as
  athei's fix. It is not a general fix: it ignores the main executable's flag.

After either fix: **3 rwx regions**, no fault storm, the main menu in ~10 s (Launch.log `Browse: XComShell` at
9.6–9.8 s in the free build), and ~40 page faults/s at the menu.

An upstream report/MR draft is in `bugreports/04-winehq-nx-compat-loader.md`.

## 3. Root cause 2: x87 under Rosetta

UE3 (2012) compiled for 32-bit x86 uses the x87 FPU. Rosetta translates x87 instructions slowly (software
80-bit emulation). [x87sidecar](https://github.com/athei/x87sidecar) (athei, MIT; started as a fork of
Lifeisawful's rosettax87_jit) patches Rosetta's runtime in the target process to use a faster x87 translation.

- Micro-benchmark (synthetic 32-bit x87 loop, 3000 iterations, in athei's Wine build, `--cooperative`):
  **10,993 ms → 159 ms (~68×)**. This measures x87 throughput, not game fps.
- Tester: sidecar alone (before the NX fix) 4–8 fps. All fixes: "fps fine" in the briefing and first mission
  (CrossOver mode), and "worked pretty well, comparable to CrossOver" (free mode).
- `x87sidecar --probe` on this Mac: `supported` (libRosettaRuntime `translate_insn 0x19d9c`,
  `decode_opcode 0x4cb60`, opcode table 733 entries).

### How the sidecar is attached (free mode)

athei's Wine build has a cooperative hook. When `ROSETTA_X87_PATH` is set, ntdll's process start execs
`[ROSETTA_X87_PATH, --cooperative, <wine loader>, <args…>]` **for i386 (32-bit) processes only**. The loader then
handshakes with the sidecar. That handshake is a no-op unless `X87_SIDECAR_BOOTSTRAP` names the process, so a
plain `exec` of the loader behaves normally.

Steam passes its environment to everything it starts, and the variable must be set when Steam starts. So
`ROSETTA_X87_PATH` points at a **filter** (`bin/x87filter`), not at the sidecar:

```bash
shopt -s nocasematch
if [[ "$*" == *xcomew.exe* ]]; then            # the game
  [ -n "${XCOM_GAME_WINEDEBUG:-}" ] && export WINEDEBUG="$XCOM_GAME_WINEDEBUG"
  [ "${XCOM_FPS:-0}" = 1 ] && export WINEDEBUG="${WINEDEBUG:+$WINEDEBUG,}+fps"   # FPS box/log (sections 14-15)
  if [ "${XCOM_X87:-1}" = 1 ]; then exec "$(dirname "$0")/x87sidecar" "$@"; fi
fi
shift   # drop --cooperative
exec "$@"                                       # everything else: run the Wine loader unchanged
```

Result (test 4): among Steam, steamwebhelper, the XCOM launcher (32-bit .NET) and the game, **only `XComEW.exe` had
a sidecar** (and, at the time, the Metal HUD library `libMTLHud.dylib`, which was loaded only there). Wine still prints its
`attaching rosettax87` ERR line for each 32-bit process, because the hook runs before the filter decides.

## 4. Root cause 3: d3d9 freeze (DXVK/MoltenVK) and the d3d9 choice

**Background (black screen).** Before this investigation the game showed a black screen in the CrossOver bottle
with the stock d3d9. The workaround in place was DXVK's d3d9 ("d9vk", a DXVK v1.10.3 async build for macOS) in the
bottle's `syswow64`, with `d3d9=native,builtin` and `DXVK_ASYNC=1`/`DXVK_HUD=fps` in `cxbottle.conf`. The cause of
the black screen was not investigated. CrossOver mode leaves that bottle setting alone and overrides d3d9 to
built-in for its own session only (`--dll d3d9=b`); with the NX fix, built-in d3d9 renders the game.

With a DXVK d3d9.dll ("d9vk") in the CrossOver bottle, the game froze at the main menu. `Launch.log` showed
`Timed out while waiting for GPU to catch up`. Sampling showed the Metal completion thread
(`com.Metal.CompletionQueueDispatch`, created by macOS, **no Wine TEB**) looping in Wine's signal handler, which
faults on a thread without a TEB. This also happened in unmodified CrossOver 26.0 with the same DXVK d3d9.dll.
Upstream Wine has since started handling signals on TEB-less threads (Julliard, 2026-05-11: `0f82d287`
"ntdll: Handle signals in thread without a TEB." and `5fe9b20f` "ntdll: Don't raise an exception for threads without a
TEB."). We have not re-tested DXVK with a build that contains them. athei's `cx-26-patched` branch (the source of
`cx-26.3.0-6`) does not contain them (checked for v0.5.0, section 16), and the build has no Vulkan anyway.

In free mode, the build's compatibility database picks `d3d9 = mtld3d` and `dxgi = gptk` by default (log:
`compatdb: d3d9 = mtld3d (from …/lib/wine/d3d9/mtld3d)`). For XCOM we use **Wine's built-in wined3d** instead,
through an environment rule that matches only the game:

```
WINE_COMPATDB=$'v=3\nname=xcom-ew-wined3d;exe=XComEW.exe;d3d9=wined3d'
```

wined3d renders via OpenGL, which macOS implements on Metal (`AppleMetalOpenGLRenderer`). `play.sh --renderer=mtld3d`
selects athei's d3d9-on-Metal instead (opt-in, section 16). Earlier versions of this document said `--mtld3d` "froze in
XCOM"; that was never measured and is wrong. The bundled mtld3d v0.7.0 actually refuses to start (section 16).

## 5. Ambient Occlusion crash

With built-in d3d9 and AO, depth of field, light shafts and lens flares off in `XComEngine.ini`, the game crashed
entering the first mission (UE3 minidumps `unreal-v8917-*.dmp`: NULL read in the renderer's resolve-target copy
used by the AO/fog-of-war passes). With all four turned back on, it worked. We didn't isolate which of the four
matters, so the advice is simply "keep AO (and the others) on". The installer can set `AmbientOcclusion=True`
(backup first), and `play.sh` warns if it finds `AmbientOcclusion=False`.

## 6. Steam CEG and cloned installs

XCOM's executables are protected by Steam CEG, which binds them to the Steam install they were delivered to.
Observations:

- A game folder **APFS-cloned** into another prefix (CrossOver 26.0 or the free build) made `XComEW.exe` exit
  cleanly **2–4 s after start** with an empty `Launch.log`. With `+seh`: one write access violation at
  the image base (`info[0]=1, info[1]=00400000`), handled by the game, then exit. The original bottle passed with
  both Wines, so this is about the copy, not the Wine build.
- **`steam://validate/200510`** (Verify integrity of game files) in the new prefix fixes it: Steam reports some
  files "failed to validate and will be reacquired" (the protected executables), fetches them, and the game starts.
  `validate.sh` automates it and waits for `AppID 200510 scheduler finished` in `logs/content_log.txt`.
- Launching `XComEW.exe` **directly** (section 8) passes CEG as long as Steam is running and logged in and
  `SteamAppId=200510` is set.

## 7. The error dialog after Steam > Exit

Report: "one error, but only after I did Exit in Steam" (free mode; dialog text not captured).

**Chain of events** (reconstructed from the Wine/Steam logs of every exit before the fix):

1. **Steam.exe crashes late in its own shutdown.** This happens under CrossOver too: the CrossOver bottle has
   ~110 KB `crash_*.dmp` files from exits. In the free prefix the dump file is 0 bytes.
2. Steam starts its crash reporter: `steamerrorreporter64.exe -pid=<n>`.
3. The reporter walks the crashed process' stacks with `dbghelp` and parses DWARF debug info. Wine logs
   `fixme:dbghelp_dwarf … Unhandled attr op`, then **"Unhandled division by zero at 00006FFFF7B2F152"** in the reporter.
   That address is builtin `dbghelp.dll` + `0xF152`: the `divl` in `compute_location()`, the `DW_OP_div` case of
   dbghelp's DWARF expression evaluator, which in this build divides without checking for zero. (Upstream Wine
   added that check on 2026-07-14: `28526110` "dbghelp/dwarf: Report errors when attempting to divide by zero." The
   CrossOver 26.3 sources the build is based on predate it.)
4. The unhandled exception starts `winedbg`, which shows Wine's crash dialog: **"Program Error – The program
   steamerrorreporter64.exe has encountered a serious problem and needs to close."** This is almost certainly the
   dialog the tester saw. It appeared on every Steam exit in the logs.

**Fix (free mode):**

- `WINEDLLOVERRIDES` contains `steamerrorreporter64.exe=d;steamerrorreporter.exe=d`, so Steam can't start the
  reporter.
- As a safety net, the prefix has `HKCU\Software\Wine\WineDbg\ShowCrashDialog=0` (the installer sets it).
- Verified: no `steamerrorreporter`, `winedbg` or "division by zero" lines in any later run.

**Side effect handled:** without the reporter, Steam's crash handler sometimes **hangs** instead of exiting, so
`steam -shutdown` never returns. `shutdown_all` (in `env.sh`) now works like this:

- It sends `-shutdown`.
- As soon as a new `crash_*.dmp` appears, it waits 2 s and ends the session with `wineserver -k`. Otherwise it
  waits up to 30 s, then `wineserver -k`.
- If anything is still alive after that, it pkills the sidecar, and `pkill -9` as a last resort.
- It deletes the empty dumps.

Typical time from game exit to "nothing left running": ~11 s (10 s of it is the deliberate wait for cloud saves).

The dbghelp part is already fixed upstream (`28526110`). Builds based on newer Wine won't crash the reporter,
but Steam's own exit crash and the reporter disable remain useful.

## 8. Steam main-loop stalls, direct launch vs Steam launch

Steam's console log sometimes shows `RtlpWaitForCriticalSection … timed out` followed by
`BMainLoop appears to have stalled`. Once that happens, Steam doesn't notice the game exiting and doesn't answer
`-shutdown`.

- **Direct launch** (`wine XComEW.exe -FROMLAUNCHER -LANGUAGE=INT` with `SteamAppId=SteamGameId=200510`, env only on
  the game, Steam running): the game passed CEG and reached the menu in ~13 s. But **Steam stalled in both direct
  runs** and never logged `Game process removed`. Kept as `play.sh --direct`, not recommended.
- **Steam launch** (`steam -applaunch 200510` plus automatic click in the XCOM launcher): no stall in tests 4 and
  5. Steam logs `Game process added` and `Game process removed` (e.g. 07:23:37 → 07:24:03 CEST in test 5).

The skip-the-launcher options Steam offers (launch options such as `-applaunch 200510 <args>`) still go through the
XCOM launcher, which is a separate .NET program Steam starts as the app's executable. So the only launcher-free
path is the direct one, and that is what triggers the stall. Clicking the launcher button automatically keeps
Steam as the parent.

## 9. Free-mode launcher design

- **Steam readiness:** Steam writes `HKCU\Software\Valve\Steam\ActiveProcess\ActiveUser` (non-zero) once an account
  is logged in, and resets it to 0 on exit. `play.sh` sets it to 0 before starting Steam, then polls it
  (`wine reg query`). No fixed sleep, and it works for first logins (waits up to 15 min in play.sh, 1 h in the installer).
- **Settings travel with Steam:** Steam passes its environment to the game, so the sidecar/FPS/d3d9/overlay/debug
  settings must be set when Steam starts. `start_steam` records them in `logs/.steam-settings` (and the Steam log
  path in `logs/.steam-log`, where the game's output ends up), and `play.sh` restarts a running Steam if they differ.
- **Process detection:** `ps` shows Windows command lines (`C:\…\Steam.exe`). CrossOver's processes would match the
  same names, so a process only counts if its executable image (`lsof -d txt`) lives in this setup's `wine/`.
  CrossOver's wineserver is detected by path, to enforce "one Steam at a time".
- **Launcher click:** `xclick.exe ew` (64-bit, CC0, source in `tools/xclick.c`) waits for the window titled
  `XCOM Launcher`, then presses its topmost visible child ≥100×60 (the Enemy Within button): mouse down/up plus
  `BM_CLICK`, after a 750 ms settle. In test 4 the click came 9 s after `-applaunch`.
- **Stop:** `stop.sh` first asks the game to close (`wine taskkill /im XComEW.exe`, i.e. WM_CLOSE; the engine logs a
  clean `Exit: Exiting.`). After 20 s it sends TERM, then KILL, then runs `shutdown_all`.
- **Steam overlay:** off by default via `WINEDLLOVERRIDES` (section 12); `--overlay` turns it on.
- **Leftovers:** after every shutdown, and before every start, `sweep_orphans` kills processes of this setup
  that outlived their wineserver (section 13).
- **FPS counter:** `bin/fpsbar` (section 14).

## 10. Test runs

All in free mode, Steam already logged in (the login was remembered).

| Run | Launch | Result |
|---|---|---|
| 1–2 | direct (`--direct`) | CEG OK, menu at ~13 s; **Steam stalled** both times; no `Game process removed` |
| 3 | Steam, manual launcher click | OK; on exit the reporter crash and "Program Error" dialog (before the fix) |
| 4 | Steam + auto-click, new filter | Click at +9 s, menu at 9.75 s, ~40 faults/s at the menu, 3 rwx regions, only XComEW had a sidecar, HUD library loaded; graceful stop → `Exit: Exiting.`; Steam crashed on `-shutdown` (expected), fallback cleaned up, nothing left; no reporter/winedbg |
| 4b | `--no-hud` | `libMTLHud.dylib` not loaded |
| 5 | Desktop launcher (end to end, fresh Steam start) | Steam logged in after 17 s, `-applaunch` → game running after 8 s (auto-click); **the game closed itself at 18 s** during the intro movie (`All Windows Closed`, clean `appRequestExit(0)`). The tester did not close it; see section 12. `play.sh` then closed Steam 11 s later, "nothing left running"; no reporter/winedbg, `Game process removed` logged |
| 6 | Desktop launcher, the tester playing | Game ran ~2.5 min and was quit from the menu. Steam then hung while quitting, and the fallback killed its wineserver. Three Wine processes lived on and wrote ~1.45 GB of errors to the Steam log (section 13) |
| 7–9 | Desktop launcher via Terminal, overlay off (new default), FPS counter on | Game up 2:12, 1:55 and 3:00+ at the main menu without input; **no `gameoverlayui64.exe`** started; `+fps` lines every ~1.5 s (22–52 fps at the menu, windowed 1280×832); `fpsbar` window on screen and in front of the game window; stopped with the Desktop stop launcher → clean `All Windows Closed`, **all processes gone within 10 s**, Steam log 23–27 KB |
| 10 | Free mode, Desktop launcher, FPS box + FPS log (v0.4.0) | Game up at +27 s; box on screen and in front of the game (`source=wglSwapBuffers`); stopped at 1:09 with the stop launcher → `All Windows Closed`, everything gone at +1:43; `fps-free-*.csv` (39 rows) and `-summary.txt` written |
| 11 | CrossOver mode (the tester's CrossOver launcher, real bottle), FPS box + FPS log | The first attempt stopped at the pre-flight check: "Another Wine is running" matched the *test harness's own shell*, whose command line contained the word `wineserver`. Fixed (servers are now matched by executable path, section 15). Second attempt: auto-click worked through CrossOver's wine, game up at +25 s, box on screen and in front of the game, stopped with `taskkill` at ~1:20 → game gone in 2 s, `fps-crossover-*.csv` (48 rows) and summary written; Steam then quit with `-shutdown`, nothing left |
| 12 | Free mode, `--renderer=mtld3d` with the **bundled mtld3d v0.7.0** (two attempts) | The game showed a message box and quit: "Your video card does not support alpha blending with floating point render targets (D3DFMT_A16B16G16R16F), which is required to run this game. Exiting..." (text read by enumerating the game's windows, section 16). `sample` showed every thread idle and the main thread in `wait_message`. Stopped with `stop.sh`, nothing left |
| 13 | Free mode, `--renderer=mtld3d`, **mtld3d v0.11.0** | Intro movies ~26–30 fps (Bink), **main menu 31–67 s: average 156, median 158, 132–169 fps**; at 67 s a new game with the tutorial (`Command1`) was started (see below), loading screen ~106–113 fps, tutorial 57–106 fps (median 71). CPU ~85%, 3 rwx regions, no freeze. mtld3d's log had four warnings. Three are harmless for this game (unsupported `CreateQuery` type 12, a 0×0 client area at device creation, the swap-effect note). The fourth, `stream stride 20 below the consumed declaration extent 28`, is the overlay-fan bug in section 16. Stopped at ~3:20 with `stop.sh` → `Exit: Exiting.`, nothing left; no save written. fps here was rebuilt from the macOS log, because the fps adapter was a test copy |
| 14 | Free mode, `play.sh --renderer=mtld3d` end to end (v0.5.0 scripts, Metal HUD overlay hidden) | Metal HUD log → `mtlhud-fps.sh` → fps box (`source=mtlhud`, on screen and in front of the game) → `fps-free-mtld3d-*.csv` (55 rows, ~1 s apart) → summary. Menu 135–153 fps for ~5 s, then the tutorial was started again; stopped at ~1:10 with `stop.sh`, `Exit: Exiting.`, nothing left; no save written |
| 15 | Free mode, default renderer (GL), v0.5.0 scripts and mtld3d v0.11.0 installed (regression check) | `source=wglSwapBuffers`, box in front of the game; menu 53–73 fps, no input at the Mac, no tutorial start; stopped at game time 79 s with `stop.sh`, `Exit: Exiting.`, nothing left |
| 16 | Free mode, `--renderer=mtld3d`, right after run 15, same conditions | Menu from ~30 s: 141–169 fps (`FPS 165` in the box); no tutorial start; stopped at 85 s, `Exit: Exiting.`, nothing left; no save written. Comparison with run 15 in section 16 |
| 17 | Free mode, `--mtld3d`, stock v0.11.0, no `mtld3d.conf` | Tactical mission. Fast. `Launch.log` reports `VendorID 0000106B`, `Apple M1 Max`, driver `mtld3d` (wined3d runs report `000010DE`, GeForce 8800 GTX). Dynamic lights looked wrong. mtld3d log `XComEW-77574.log`: HDR present on (RGBA16Float, extended-linear Display P3, 16× headroom) and the stride-widen warning |
| 18 | Free mode, `--mtld3d`, stock v0.11.0, `mtld3d.conf` as in section 16 | Same mission, 269 s, quit from the menu (`appRequestExit(0)`). `Launch.log`: `VendorID 000010DE`, GeForce 8800 GT, `GPU DeviceID found in ini`. mtld3d log `XComEW-2073.log`: spoof `0x10de/0x0611`, HDR disabled, present `BGRA8` / sRGB. Fps over 252 s, first 10 s skipped: average 73.9, median 72.3, 1% low 25.5. Fires, headlights and the street looked normal. Fog of war and the move highlight were huge triangle fans. Stride warning once, about two minutes in |

Installer: `install.sh --dry-run` in free mode (separate `--dir`), `--crossover --dry-run` and `--uninstall --dry-run` all
passed on the test Mac without creating anything (`dryrun-mac-output.txt`, re-run for v0.5.0). `--game-from download` correctly failed its
disk-space check (14 GB free, ~26 GB needed). The pinned x87sidecar v1.7.0 release binary prints `supported` with
`--probe` on this Mac. The live tests above used a local build of the same commit (4048fcf); the release binary
itself has not been run with the game yet. A full second install was not done (disk space, and it would need a
second Steam login).

In three earlier runs, the game loaded `Command1 … Difficulty=1 ControlledStartFromShell` about 41 s after start.
That is the first-start tutorial. We are not sure whether it started by itself or someone clicked. It happened again
in runs 13 and 14 (36 s and 5 s after the menu appeared). The tester was using the Mac at the time, and the game
window takes keyboard focus when it opens, so keystrokes meant for another app may have reached the menu. Runs 7–9
stayed at the menu for 2–3 minutes, and so did runs 15–16 (no input at the Mac in run 15; in run 16 only in its last ~25 s). Menu
measurements should be made with nobody typing.

## 11. CrossOver mode details

- The installer makes an APFS clone of `CrossOver.app/Contents/SharedSupport/CrossOver` into
  `~/Library/Application Support/xcom-x87-fix/cxroot`. `CrossOver.app` and the bottle's files are never modified.
- **NX:** pattern `F6 4x 5F 01 | 75 xx | C7 45 xx 02 00 00 00` with `ProcessExecuteFlags` (0x22) within 80 bytes.
  Exactly one match is required, `ntdll.dll.orig` is kept, and the hash is checked against known versions.
- **x87:** x87sidecar is built from source (commit `4048fcf`) with Xcode CLT and CMake. It is attached through a bash
  wrapper that replaces `lib/wine/x86_64-unix/wine` in the clone: the real loader is `wine.x87real`, re-signed ad
  hoc with `get-task-allow`. This uses the default `task_for_pid` attach mode, because stock CrossOver has no
  cooperative hook.
- **d3d9:** `--dll d3d9=b` for the session only; the bottle's own override isn't changed.
- It runs the real bottle (CEG, section 6).
- **Play launcher** (`xcom-play.sh`, v0.4.0): refuses to start next to another Wine Steam or a running game;
  restarts this copy's Steam if it runs (settings are inherited from Steam); starts Steam with `-applaunch 200510`;
  presses Enemy Within with `xclick.exe` run through the cloned CrossOver wine; waits for the game (a process whose
  `lsof -d txt` image is inside the clone); starts `fpsbar` on the game's log; waits for the game to exit and prints
  the FPS summary. Steam keeps running (quit it from its menu). The wrapper around the loader adds `+fps` for the
  game only when `X87_FPS=1` and records the game log path in `logs/.last-game-log`.

## 12. The game closing itself, and the Steam overlay

In test 5 the game closed itself 18 s after start, during the intro movie: `Launch.log` shows
`All Windows Closed` and a clean `appRequestExit(0)`, i.e. the engine got a normal window-close message and
quit, not a crash or a signal. The tester confirmed he didn't close it.

Ruled out, with evidence:
- **xclick:** one click, at the "XCOM Launcher" window, before the game existed. It targets only that window.
- **play.sh:** its watcher logged the exit 3 s later and started the Steam shutdown only 10 s after that; there
  was no `wineserver -k` before the exit. No timeouts.
- **Input:** macOS's unified log shows keyboard focus on another app at 07:23:58 and at the moment of the close.
- **macOS:** nothing arrived at the game from outside: no Apple Event, no quit from loginwindow or
  LaunchServices, no Automatic Termination (AppKit logs `_kLSApplicationWouldBeTerminatedByTALKey=1` for Wine
  processes, but no terminate followed). The game's process logged nothing between 07:24:00.0 and 07:24:01.0.

What does line up: Steam starts `gameoverlayui64.exe` **7 times** per game start, ~11 s after the game. The
first stays, and the other 6 exit after ~150 ms. That happened in every session. In test 5 the 7th instance lived
from 07:24:00.12 to 00.28, and the game closed ~0.15 s later. In the other sessions the game survived the same
pattern, so it is a race.

A plausible mechanism exists in this Wine: athei's build is based on CrossOver's Wine, whose Mac driver has a
CodeWeavers hack ("CW Hack 22310, 24199", `dlls/winemac.drv/cocoa_app.m`). When a Wine app whose
AppUserModelID is whitelisted (`Valve.Steam.Client`, …) quits through Cocoa, it posts a distributed
`WineExternalQuitRequestNotification`, and every Wine app in the same prefix with a matching AUMID or exe name
quits too. Each overlay process registers for that notification. We could not prove that path was taken:
distnoted doesn't log posts, and the game's own log shows only the close. The close could also be a Windows-side
message from the overlay code injected into the game (`gameoverlayrenderer.dll`).

Fix: the overlay is **disabled by default**. `steam_env` adds
`gameoverlayrenderer=d;gameoverlayrenderer64=d;gameoverlayui.exe=d;gameoverlayui64.exe=d` to `WINEDLLOVERRIDES`,
so Steam can neither inject the renderer into the game nor start the overlay UI. Verified in runs 7–9: no
`gameoverlayui` process and no `gameoverlayui` line in the Steam log, and the game stayed up. Steam didn't
complain. `--overlay` restores the old behaviour. Because the self-close happened once in about four
comparable runs, three good runs are evidence, not proof.

## 13. Leftover Wine processes after a killed wineserver

After run 6, Steam deadlocked while quitting (`RtlpWaitForCriticalSection … blocked by 00ec`), and
`shutdown_all` fell back to killing the wineserver. `Steam.exe`, `winedevice.exe` and `explorer.exe` survived
it, reparented to launchd. They spun at 100% CPU (`err:sync:server_register_wait Failed to send server register
wait: 0x10000003`, msync) and wrote ~4.5 MB/s into the Steam log (1.45 GB when found). They were killed by pid
after checking that their executable was in this setup's `wine/`.

Fix: `sweep_orphans` in `env.sh`. When no wineserver of this setup is running, it `kill -9`s every process
whose executable image (`lsof -d txt`) is in this setup's `wine/` (after a cheap `ps` pre-filter). It runs at the
end of `shutdown_all`, at every `play.sh` start, and in `stop.sh` when Steam is not running. CrossOver's
processes live elsewhere and are never matched.

## 14. FPS counter

- **Metal Performance HUD doesn't work on the GL path.** `MTL_HUD_ENABLED=1` loads `libMTLHud.dylib` into the game but draws
  nothing (the tester saw no HUD). The game renders with wined3d on OpenGL (Apple's GL-on-Metal). The game also
  creates a DXMT D3D11 device (feature level 11_0), but it never presents. The build has no Vulkan
  (`winevulkan`/MoltenVK), so wined3d's Vulkan renderer (where the Metal HUD would work through MoltenVK) is not
  possible either. (With `--renderer=mtld3d` the game presents through Metal, and the HUD works: section 16.)
- **What we use instead:** wined3d's own `fps` debug channel. With `+fps` for the game only (set in
  `x87filter`), wined3d prints `… @ approx 51.62fps` about every 1.5 s (both `wglSwapBuffers` and
  `wined3d_cs_exec_present` lines). The game's stderr goes to the Steam log. `bin/fpsbar` (MIT, source
  `tools/fpsbar.m`, ~200 lines of AppKit, arm64, ad-hoc signed, sha256-pinned) follows that log and draws a
  borderless, click-through, non-activating window at `NSScreenSaverWindowLevel` (shielding level if a display
  is captured), with `canJoinAllSpaces|fullScreenAuxiliary`. The window sits in the top-left corner of the game's
  largest window (found by the game's pid in `CGWindowListCopyWindowInfo`) and exits with the game.
- **Verification without screenshots** (no Screen Recording permission): every 2 s fpsbar writes
  `logs/fpsbar-status.txt` from the on-screen window list (front to back). In runs 7–9:
  `box onscreen=1 layer=1000 bounds=235,130 104x30`, `game … layer=0 bounds=227,122 1280x832`,
  `box_in_front_of_game=1`, `shown="FPS 30"`. The user then confirmed that the box is visible (windowed mode).
- Both `wglSwapBuffers` and `wined3d_cs_exec_present` print a line per interval. fpsbar locks onto the first
  source it sees, so each interval is counted once. It parses complete lines only (a partial last line is carried
  over to the next read).
- Cost: one trace line per 1.5 s in the game, and a 0.5 s timer in fpsbar.

## 15. FPS in CrossOver mode, FPS logging and comparison

**CrossOver 26.0 has the same channel.** Its i386 `wined3d.dll` contains the format string `%p @ approx %.2ffps` and
its `opengl32.dll` `@ approx %.2ffps, total %.2ffps`, the same as the free build. CrossOver 26.0 has no
`mtld3d`/DXMT d3d9, so built-in d3d9 there is wined3d on OpenGL too. Live check (run 11): `source=wglSwapBuffers`,
the box on screen and in front of the game, samples every 1.5 s.

**Logging.** fpsbar has `--csv FILE` (and `--hidden` to log without showing the box). Every sample is appended as
`time,elapsed_s,fps` (ISO local time, seconds since fpsbar started, fps) and flushed per line, so logging costs one
short write per 1.5 s. Both launchers write to `~/Library/Logs/xcom-mac-fix/fps-<mode>-<YYYYmmdd-HHMMSS>.csv`
(`mode` = `free`, `free-mtld3d` (section 16) or `crossover`) and keep the last 100 files per mode. When the game exits, `fps-summary.sh` prints
and saves `…-summary.txt`:

- skips the first 10 s (loading; `XCOM_FPS_SKIP` or the second argument changes it);
- ignores exact `0.00` values: wined3d's first report of every session is `approx 0.00fps`, because its interval
  timer starts at zero. A real stall still prints a small non-zero number once the next frame arrives;
- reports samples, measured seconds, average, median, "1% low" (the 1st percentile of the ~1.5 s averages; with
  fewer than 100 samples this is simply the minimum), min and max. These are interval averages, not frame times,
  so "1% low" is coarser than a frame-time 1% low.

`compare-fps.sh [A B] [--skip N]` prints both summaries side by side with the difference. A and B are files or mode
names (the newest log of that mode, e.g. `free-mtld3d`); without arguments it takes the newest `fps-free-*` and
`fps-crossover-*`. The summary reports the actual sample interval (~1.5 s for wined3d, ~1 s for the Metal HUD).

**Options.** `--no-hud`: box off, logging stays on (in free mode no Steam restart is needed). `--no-fps`: no trace,
no box, no CSV (changes the Steam settings, so a running Steam is restarted).

**Pre-flight fix found in run 11.** The CrossOver launcher looked for other Wine servers with `pgrep -fl
wineserver`, which matches *any* process whose arguments contain the word (a shell, an editor, a `tail`). It now
lists servers by executable path (`ps -axo comm=`, the full argv[0] on macOS) and ignores shells and text tools
when looking for a running `XComEW.exe`. Windows processes under Wine show their Windows path as `comm`
(`C:\…\XComEW.exe`).

**Menu-only numbers (runs 10 and 11, not a benchmark).** Same Mac, windowed ~1280×830, main menu without input,
~1 min each, first 10 s skipped:

| | free mode | CrossOver mode |
|---|---|---|
| samples / measured | 38 / 57 s | 47 / 71 s |
| average | 51.7 | 61.6 |
| median | 58.6 | 68.3 |
| min (= 1% low here) | 19.5 | 19.9 |
| max | 74.7 | 80.9 |
| steady menu, samples after 45 s | ~67 | ~77 |

Both sessions start with ~20 s of intro movie at ~30 fps and one dip (~20 fps) at the switch to the menu, and the
two runs stopped at different points, so the averages mostly reflect how much movie each contains. Run length,
Wine version (26.0 vs 26.3), sidecar attach mode, background load and the menu scene itself all differ. A fair
comparison needs the method in the README (same save, same spot, 2–3 minutes each, alternating, several rounds).

## 16. Other d3d9 paths: Vulkan/DXVK, D3DMetal, mtld3d

Question for v0.5.0: is a d3d9 path other than wined3d on OpenGL faster and still stable in free mode?

**Vulkan (DXVK d3d9, wined3d's Vulkan renderer): not possible in this build.** athei/wine-build `cx-26.3.0-6` is
configured `--without-vulkan`, and its bundle step deletes `vulkan-1` and `winevulkan`. Only the static import
stubs `libvulkan-1.a`/`libwinevulkan.a` remain, and there is no `libMoltenVK`. So a DXVK `d3d9.dll` has no Vulkan to
talk to, and `HKCU\Software\Wine\Direct3D\renderer=vulkan` has nothing to use. (Older wine-build releases, up to
`cx-26.3.0-1`, still bundled MoltenVK; not tested, since that would mean an older Wine with the same signal-handler
problem.) The upstream TEB-less signal fixes (`0f82d287`, `5fe9b20f`, see section 4) are also missing: athei's
`cx-26-patched` branch still has the old `amd64_thread_data()` in `dlls/ntdll/unix/signal_x86_64.c` and no
`!teb` checks. A DXVK-on-MoltenVK d3d9 would therefore probably freeze the way d9vk did in CrossOver.
`play.sh --renderer=dxvk|vulkan` prints this and exits.

**D3DMetal (Apple's GPTK) and DXMT: no d3d9.** The build ships `D3DMetal.framework`, but compatdb uses it only for
the dxgi family (d3d10/11/12, 64-bit). DXMT is d3d11 only. XCOM EW is a 32-bit d3d9 game.

**mtld3d: works from v0.11.0.** mtld3d (athei, zlib licence, github.com/athei/mtld3d) implements d3d9 on Metal
directly. The build bundles v0.7.0 as `lib/wine/d3d9/mtld3d` and uses it by default for other programs; compatdb
knows only the names `mtld3d` and `wined3d` for d3d9, so a second version can't sit next to it.

- v0.7.0 (run 12): XCOM checks `CheckDeviceFormat(D3DUSAGE_QUERY_POSTPIXELSHADER_BLENDING, D3DFMT_A16B16G16R16F)`
  and quits with a message box: "Your video card does not support alpha blending with floating point render
  targets (D3DFMT_A16B16G16R16F), which is required to run this game. Exiting...". The Launch.log was cut off, and
  there is no Screen Recording permission, so the text was read with a tiny read-only Windows tool (EnumWindows +
  GetWindowText, run in the same prefix).
- v0.11.0 (released 2026-09-25; its CI tests against `cx-26.3.0-5`) answers that query. Main menu, back-to-back
  runs 15 (GL) and 16 (mtld3d), same window, first 35 s (intro) skipped, `compare-fps.sh
  free free-mtld3d --skip 35`:

  | | wined3d/GL | mtld3d v0.11.0 | difference |
  |---|---|---|---|
  | samples / measured | 30 / 46 s | 65 / 49 s | |
  | average | 64.9 | 159.3 | +145% |
  | median | 65.3 | 159.7 | +145% |
  | min (= 1% low here) | 54.6 | 140.9 | +158% |
  | max | 73.3 | 168.9 | +130% |

  Only the steady part (skip 52 s): 69.3 vs 161.6. Run 13 gave the same picture (menu average 156). The menu is
  a light scene and these are single runs, so real play will differ. Tutorial map (run 13): median ~71 fps (no GL
  number for that scene). No freeze, clean exits. A tactical mission was checked on 26 Sep (runs 17–18). Two separate picture bugs, both still opt-in until the patched DLL is confirmed in game:

  1. **Adapter identity and HDR present.** Stock v0.11.0 reports the real Apple GPU (`VendorID 0000106B`). Unreal Engine 3 only copies scene depth when the adapter is NVIDIA or AMD (INTZ plus the RESZ draw). Without that copy, dynamic lights, light shafts, ambient occlusion and depth of field sample a buffer nothing writes. wined3d already reports a GeForce 8800 GTX, which is why the OpenGL renderer does not have this bug. mtld3d implements the NVIDIA path; `adapter.spoof = nvidia` turns it on (`Launch.log` then shows `000010DE` and `GPU DeviceID found in ini`). On top of that, the default HDR present inverse-tone-maps a frame XCOM already tonemapped for an SDR monitor (`color.hdr.enable = true`, RGBA16Float, extended-linear Display P3). `color.hdr.enable = false` and `color.space = accurate` force the SDR blit and tag the layer sRGB. With both set, fires, headlights and the street looked normal (run 18). The file is read once, at `Direct3DCreate9`, from the directory of `XComEW.exe`:

     `…/XEW/Binaries/Win32/mtld3d.conf`

     ```
     adapter.spoof = nvidia
     color.hdr.enable = false
     color.space = accurate
     ```

     `play.sh --mtld3d` writes this file next to `XComEW.exe` when it is missing, and leaves an existing file alone. `install.sh` does not. The same three keys are the `xcom-ew` profile in mtld3d pull request 872, which a released build would apply with no file; until that release, the file is what stock v0.11.0 reads.

  2. **Short vertex stride (the fans).** The fog-of-war tint and the red move highlight are a mesh packed at 20 bytes per vertex. The shader also consumes an attribute that ends at byte 28. Metal cannot describe an attribute past the stride, so v0.11.0 widens the step to 28 and then reads the original buffer at that step. Every vertex after the first comes from the wrong place, and those overlays stretch into fans across the map. World geometry uses a different layout and stays put. The log line is `stream stride 20 below the consumed declaration extent 28; layout widened to the extent`. It is not harmless. The fix copies each vertex out to the widened step, using the bytes D3D9 addresses at `base + index * stride` (the extra attribute overlaps the next vertex). Pull request: https://github.com/athei/mtld3d/pull/872. The patched i686 `d3d9.dll` from that branch is installed in this machine's `~/xcom-freewine/wine/lib/wine/d3d9/mtld3d/i386-windows/` (26 Sep 20:22). Its test `stride_below_a_consumed_attribute_still_places_the_triangle` passed under `make test-e2e-i686`. The patched DLL is **not** part of the installer. The installer downloads the pinned v0.11.0 tarball and skips that step when `wine/lib/wine/d3d9/mtld3d/.mtld3d-<sha>` already exists, so a later `./install.sh` on this machine leaves the patched `d3d9.dll` in place. Deleting that stamp, or bumping the pin, installs stock v0.11.0 again and the fans come back until 872 is in a release. The in-game picture with the patched DLL was confirmed (thin fog edge, tile-sized move highlight, lights normal). mtld3d is the default; `--renderer=gl` is the fallback.
- The installer downloads v0.11.0 (sha256 `c4535f3b…4304`), moves the bundled v0.7.0 tree to `dl/`, and installs
  v0.11.0's `i386-windows`, `x86_64-windows` and `x86_64-unix` folders in its place. Other programs in the
  prefix (Steam, the XCOM launcher) then get v0.11.0 as their default too. Steam worked normally in runs 13–14.
- mtld3d writes a small log (`<exe>-<pid>.log`, ~10 KB; it keeps the ten newest) to `mtld3d-logs/` next to
  `XComEW.exe`. A `log.dir` passed through `MTLD3D_CONFIG` showed up as empty in that log (cause not investigated),
  so we leave the default.

**FPS for mtld3d.** Wine's `+fps` channel is wined3d's, so it prints nothing with mtld3d. Instead, `x87filter` gives
the game `MTL_HUD_ENABLED=1 MTL_HUD_LOG_ENABLED=1 MTL_HUD_OPACITY=0` (logging on, overlay hidden, because the fps
box already shows fps; `XCOM_MTLHUD_OPACITY=1` shows Apple's HUD). The HUD then logs about once per second to the
macOS log (subsystem `com.apple.metal.hud`): `metal-HUD: <frame number>,<memory>,<memory><private>`. macOS redacts
the per-frame timings as `<private>`, so `mtlhud-fps.sh` computes fps as the frame-number difference divided by the
time difference of two lines (gaps under 0.5 s are skipped, and a counter restart resets it). It writes lines in
wined3d's `@ approx N.NNfps` format, so `fpsbar`, the CSV (`fps-free-mtld3d-<time>.csv`) and `fps-summary.sh`
work unchanged. `compare-fps.sh free free-mtld3d` compares the newest sessions of both.

## 17. Open questions

- Is the fpsbar box visible in fullscreen too? (Confirmed by the user in windowed mode.)
- Which mode is faster in real play? Only menu numbers exist (section 15).
- Was the test-5 self-close the Steam overlay (CW hack 22310 quit request or the injected renderer)? Does it
  recur with the overlay off?
- Does DXVK work with upstream's TEB-less signal handling (`0f82d287`/`5fe9b20f`) in a future build that also
  ships Vulkan/MoltenVK?
- A tactical mission on patched mtld3d (PR 872, plus the `mtld3d.conf` in section 16) looks right: thin fog edge, tile-sized move highlight, lights normal. It is the default. Menu fps is in section 16; one mission with the conf and stock DLL was median 72 fps, so the mission stays far below the menu. The remaining cost is the 32-bit game thread under Rosetta, not the choice of OpenGL versus Metal. The plan to try a native Apple Silicon Wine plus FEX, without touching this tree until it wins a comparison, is `plan-apple-silicon-wine.md`. Not started.
- Which of AO / DoF / light shafts / lens flares actually avoids the mission-start crash?
- Steam.exe's own exit crash (both Wines): root cause not investigated. It is harmless after the mitigations.

## 17. Release packaging audit (27 September 2026)

Version 0.5.1 closes the gap described in section 16: a clean rebuild of the tested i386 DLL source is
now bundled under `vendor/mtld3d/`, with zlib licence, source patch, commit link
and SHA-256. Installer runs always check the actual DLL and repair it when
needed, backing up the previous DLL by its checksum. This supersedes section
16's historical statement that the patched DLL is not included.

The launcher still uses mtld3d by default and writes the three explicit config
keys; OpenGL is the fallback. The original build did not include the later
automatic XCOM profile. The package does not claim a bit-reproducible build.

The pinned Wine executable reports `LC_BUILD_VERSION minos 15.0`; the old
macOS 14 installer floor was incorrect. This is a binary minimum, not a tested
compatibility claim: gameplay evidence remains M1 Max/macOS 27 only.

Runtime updates now refuse a running Wine session in the target installation.
Missing helper payloads fail preflight as well as wrong checksums.
