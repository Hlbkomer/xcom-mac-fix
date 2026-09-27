# xcom-mac-fix: XCOM: Enemy Within on Apple Silicon Macs

Makes **XCOM: Enemy Within** (Steam app 200510, the Windows version) playable on Apple Silicon
Macs. The **default "free" mode needs no CrossOver**: it uses a free, open-source Wine build that already
contains the key fix, and adds a small x87 accelerator for Rosetta 2. An optional **CrossOver mode**
(`--crossover`) applies the same fixes to a private copy of your own licensed CrossOver instead.

> **Status: experimental.** Tested on one machine: MacBook Pro M1 Max, macOS 27.0, Steam version of XCOM with
> Enemy Within. Free mode: athei/wine-build `cx-26.3.0-6`. CrossOver mode: CrossOver 26.0.0.39794. Tester's
> verdict on free mode: "worked pretty well, comparable to CrossOver". Both modes show an FPS box and log
> every session's fps, so you can compare them yourself ([Comparing the two modes](#comparing-free-mode-and-crossover-mode)).

- [Why XCOM is broken on Apple Silicon](#why-xcom-is-broken-on-apple-silicon)
- [How the fix works](#how-the-fix-works)
- [Requirements](#requirements) · [Install](#install) · [Play](#play) · [Options](#options)
- [Troubleshooting](#troubleshooting) · [Uninstall](#uninstall) · [Known issues](#known-issues)
- [Comparing free mode and CrossOver mode](#comparing-free-mode-and-crossover-mode) · [Renderers (free mode)](#renderers-free-mode)
- [CrossOver mode](#crossover-mode) · [What was done, in order](#what-was-done-in-order) · [Credits and licences](#credits-and-licences)

Details and evidence for everything below: [TECHNICAL.md](TECHNICAL.md). The general method (for fixing the next
game): [../METHODOLOGY.md](../METHODOLOGY.md).

## Why XCOM is broken on Apple Silicon

XCOM (2012/2013) is a **32-bit** Unreal Engine 3 game. Under Wine on an Apple Silicon Mac it runs as x86 code
through **Rosetta 2**. We found three separate problems, plus one game setting that matters:

| # | Problem | Symptom | Fix used here |
|---|---|---|---|
| 1 | **NX (no-exec) fault storm.** Wine turns data-execution prevention off for the *whole process* as soon as any DLL without the `NX_COMPAT` flag is loaded. XCOM loads two (`cudart32_30_9.dll`, `PhysXExtensions.dll`), although `XComEW.exe` itself is NX-compatible. With NX off, Wine maps every readable page executable. Under Rosetta, the first write to a page that is both writable and executable costs a Mach exception round trip. | ~5 fps, one core pinned, **~76,000 page faults/s**, **931 writable+executable regions (495 MB)** | athei's Wine build has the source fix ([athei/wine@539aa62](https://github.com/athei/wine/commit/539aa62220ad23a390ce9f2a1c99ee5d3831907b)): only the main executable decides, and under Rosetta no-exec stays on. Result: **3 rwx regions**, ~40 page faults/s at the main menu. This is **upstream Wine behaviour too**, not only CrossOver's (see TECHNICAL.md). |
| 2 | **x87 floating point under Rosetta.** UE3 uses the x87 FPU heavily, and Rosetta translates x87 slowly. | Low fps even after fix 1 | [athei/x87sidecar](https://github.com/athei/x87sidecar) patches Rosetta's x87 translation in the game process. It is attached to `XComEW.exe` only. On a synthetic x87 loop: **10,993 ms → 159 ms (~68×)**; that is not an fps number. |
| 3 | **Freeze with DXVK/"d9vk" d3d9 on MoltenVK.** With DXVK's d3d9 the game froze at the main menu (`Timed out while waiting for GPU to catch up`): Wine's signal handler faulted on a macOS-owned Metal thread. | Freeze at or shortly after the main menu | Not DXVK. Free mode's default is athei's **mtld3d** (d3d9 on Metal); `--renderer=gl` is Wine's wined3d on OpenGL. CrossOver mode uses built-in d3d9 (`--dll d3d9=b`). See [Renderers](#renderers-free-mode). |
| + | **Ambient Occlusion must stay ON.** With built-in d3d9, AO off (we had also turned off DoF, light shafts and lens flares) crashed at mission start (NULL read in the renderer's resolve-target copy used by the AO/fog-of-war passes). | Crash entering the first mission | Keep AO on. The installer offers to set `AmbientOcclusion=True` (with a backup); `play.sh` warns if it is off. |

Also important: **Steam's copy protection (CEG).** XCOM's `.exe` files are tied to the Steam install they came
from. A game folder copied or cloned from another install quits ~2 s after start until Steam has
**verified the files once** (`steam://validate/200510`), which re-fetches the protected executables. The
installer does that automatically after cloning; `validate.sh` does it by hand.

## How the fix works

**Free mode (default)** installs a self-contained folder (default `~/Library/Application Support/xcom-mac-fix`):

```
wine/        athei/wine-build cx-26.3.0-6 (CrossOver 26.3 open-source Wine + NX fix + x87 hook), + Wine Mono 10.4.1
prefix/      its own Wine prefix (Windows "C:" drive) with Steam and the game
bin/         x87sidecar (v1.7.0), x87filter (decides which process gets the sidecar), xclick.exe (launcher helper),
             fpsbar (the FPS box and FPS logger)
wine/lib/wine/d3d9/mtld3d/   mtld3d v0.11.0 (replaces the build's bundled v0.7.0; used by default, plus the bundled XCOM short-stride DLL)
env.sh       shared settings        play.sh   play           stop.sh   stop everything
steam.sh     Steam on its own       validate.sh  one-time CEG fix   kill-xcom.sh  stop the game only
fps-summary.sh  summary of one FPS log    compare-fps.sh  two FPS logs side by side
mtlhud-fps.sh   fps for --renderer=mtld3d (from Apple's Metal HUD log)
logs/        launch logs (last 10)  install.manifest
~/Library/Logs/xcom-mac-fix/   FPS logs of every session (fps-free-*.csv, fps-free-mtld3d-*.csv, fps-crossover-*.csv, *-summary.txt)
~/Desktop/XCOM Enemy Within (free Wine).command   double-click to play
~/Desktop/XCOM (free Wine) - stop.command         stop the game and Steam if anything hangs
```

What `play.sh` does, step by step:

1. Refuses to run next to another Wine Steam (CrossOver's or CrossOver mode's): **only one Steam at a time**.
2. Starts Steam with the fix settings and waits until you are logged in. It watches Steam's own
   `ActiveProcess\ActiveUser` registry value, so it doesn't need a fixed delay.
3. Asks Steam to launch XCOM (`-applaunch 200510`). Starting through Steam keeps CEG happy. Steam's in-game
   overlay is **off** by default (`--overlay` turns it on; see Known issues).
4. `xclick.exe` presses **Enemy Within** in the XCOM launcher for you (`--launcher` turns that off).
5. Steam hands its environment to every child process, so a small filter (`bin/x87filter`, registered via the
   build's `ROSETTA_X87_PATH` hook) applies the **sidecar, the FPS trace and debug channels to `XComEW.exe`
   only**. Steam, its browser processes and the XCOM launcher run untouched.
6. Once the game runs, `bin/fpsbar` shows the **FPS box** and writes the session's **FPS log** (see Play).
7. When the game exits, it prints the **FPS summary**, waits 10 s (cloud saves) and then **closes Steam and the whole Wine session**. It tries
   a clean `steam -shutdown` first and falls back to `wineserver -k`. Then it removes any Wine process of this
   setup that outlived its wineserver. Nothing is left running.

## Requirements

- Apple Silicon Mac, **macOS 15 or newer** (Wine minimum; tested on 27.0 only), **Rosetta 2** (`softwareupdate --install-rosetta`)
- A **Steam account that owns XCOM: Enemy Unknown** with **Enemy Within** (the Complete Pack or the EW expansion)
- About **4 GB** free if the game can be cloned from a CrossOver bottle on the same APFS volume, otherwise about
  **26 GB** (Steam downloads the game)
- Internet access during install (GitHub for Wine/Mono/x87sidecar/mtld3d, Valve for Steam)
- **No CrossOver, Xcode, Homebrew or admin password needed** in free mode. Nothing is installed system-wide.

## Install

```bash
unzip xcom-mac-fix-0.5.1.zip
cd xcom-mac-fix-0.5.1/installer
./install.sh --dry-run        # checks everything and prints every action; changes nothing
./install.sh                  # install (free mode)
```

The installer is **resumable**: if it stops (network, you closed Steam), run it again and finished steps are
skipped. Its steps:

1. **System checks**: macOS version, Apple Silicon, Rosetta, tools, free space.
2. **Game source**: with `--game-from auto` (default) it looks for XCOM in your CrossOver bottles (read only). If
   found on the same volume, it makes an **APFS copy-on-write clone** (almost no extra space, the original is
   never changed); on another volume, a full copy (asks first). Otherwise **Steam downloads it**.
3. **Wine** download, **sha256-pinned** (`11cb278a…ce37`), unpacked into the install folder.
4. **Wine Mono** 10.4.1 (pinned), for the XCOM launcher (a .NET program).
5. **x87sidecar** v1.7.0 release binary (pinned), checked with `x87sidecar --probe` against your Rosetta;
   **mtld3d** v0.11.0 (pinned, `c4535f3b…4304`) in place of the build's bundled v0.7.0 (kept in `dl/`), then applies the included, checksum-verified XCOM short-stride DLL; plus
   the launch scripts.
6. **Wine prefix** (Windows 10, 64-bit), the Wine crash dialog turned off, and a **silent Steam install**. The
   licence note appears here: installing Steam means accepting Valve's Steam Subscriber Agreement. XCOM's own
   licence agreement is shown by Steam at the first game start.
7. **Steam login (you)**: a Steam window opens. Log in yourself (Steam Guard if asked, tick *Remember me*). The
   installer never sees or asks for your password. It continues on its own once you are logged in (waits up to 1 h).
8. **Game**: clone plus a one-time **Verify integrity of game files** (automated `steam://validate/200510`,
   ~1–3 min; Steam may report files that "failed to validate": expected, those are the protected .exe files),
   or a full Steam download (click *Install* in the dialog that appears).
9. **Launchers** on the Desktop, and the optional **Ambient Occlusion** setting (backup first).

## Play

Double-click **XCOM Enemy Within (free Wine).command** on the Desktop. A Terminal window shows progress; Steam
starts, XCOM starts, and Enemy Within is selected automatically. **Keep the Terminal window open**: it closes Steam
when you quit the game. (Closing it doesn't stop the game; it just skips the automatic Steam shutdown.)

- **First launch:** Steam may show XCOM's licence agreement (accept it) and install DirectX/VC++ once.
- **Quit** from the game menu (Exit Game). Steam is closed about 10 s later.
- **If anything hangs:** double-click **XCOM (free Wine) - stop.command**. It asks the game to close, then forces
  it, then shuts down Steam (falling back to `wineserver -k`).
- **FPS counter (on by default):** a small dark box with green text, **"FPS 60"**, in the **top-left corner of
  the game window**. It shows "FPS -" for the first seconds, until the first number arrives. It is a separate
  little Mac program (`bin/fpsbar`) that floats above the game. Mouse clicks go through it. It reads the frame
  rate that Wine's d3d9 (wined3d) reports about every 1.5 s, and it closes with the game. `--no-hud` turns it off;
  `HUD_DEFAULT=0` in `env.sh` makes it opt-in (`--hud`). `XCOM_FPS_POS=tr` (or `bl`, `br`) moves it to another
  corner.
- **FPS log (on by default, also with `--no-hud`):** every session writes
  `~/Library/Logs/xcom-mac-fix/fps-free-<date-time>.csv` (one line per ~1.5 s: time, seconds since start, fps).
  When the game exits, the Terminal window shows a summary (duration, average, median, 1% low, min, max, samples;
  the first 10 s of loading are skipped), also saved as `…-summary.txt`. `--no-fps` turns off the trace, the box
  and the log.
- Saves and settings live in `~/Documents/My Games/XCOM - Enemy Within`, shared with CrossOver if you use both.
- Don't open CrossOver's Steam while this one runs (and vice versa).

## Options

From Terminal: `"<install dir>/play.sh" [options]`, e.g.
`"$HOME/Library/Application Support/xcom-mac-fix/play.sh" --no-hud`. The Desktop launcher passes options on too.

| Option | Effect |
|---|---|
| `--no-hud` | no FPS counter (it is on by default) |
| `--hud` | show the FPS counter (only needed if you set `HUD_DEFAULT=0`) |
| `--no-fps` | no fps trace at all: no box, no FPS log, no summary |
| `--overlay` | enable Steam's in-game overlay (off by default; see Known issues) |
| `--no-x87` | run without x87sidecar (slow; for comparison, or if a macOS update breaks the sidecar) |
| `--renderer=mtld3d` | d3d9 through athei's mtld3d on Metal (**default**). `--mtld3d` is the same |
| `--renderer=gl` | d3d9 through Wine's wined3d on OpenGL (fallback) |
| `--renderer=dxvk` / `vulkan` / `d3dmetal` | not available in this Wine build (it has no Vulkan; D3DMetal has no d3d9); prints why and exits |
| `--launcher` | don't press Enemy Within automatically (choose Enemy Unknown or Enemy Within yourself) |
| `--direct` | start `XComEW.exe` directly instead of via Steam. CEG accepts it, but Steam's main loop stalls afterwards. **Not recommended.** |
| `--keep-steam` | leave Steam running after the game exits |
| `--validate` | run "Verify integrity of game files" first |
| `--debug=CH` | Wine debug channels for the game process only, e.g. `--debug=+seh` |

Other scripts: `stop.sh` (stop the game and Steam; `--game-only` keeps Steam), `steam.sh` (Steam alone, e.g. to
change settings or download), `validate.sh` (one-time CEG fix), `kill-xcom.sh` (stop only the game), `fps-summary.sh FILE.csv [SKIP]` (summary of one
FPS log), `compare-fps.sh [A B]` (two logs side by side: files, or mode names such as `free`, `free-mtld3d`,
`crossover` for the newest log of that mode; default: the newest free and CrossOver logs).
Settings Steam runs with are inherited by the game, so `play.sh` restarts a Steam that was started with other settings.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| **Game quits ~2 s after start**, `Launch.log` empty | Steam CEG rejects copied executables. Run `validate.sh` (or `play.sh --validate`) once. `play.sh` prints this hint when it sees it. |
| **"Program Error: steamerrorreporter64.exe has encountered a serious problem"** after Steam > Exit | Steam.exe crashes at the very end of its own shutdown under Wine (CrossOver too; harmless). Steam then starts its error reporter, which itself crashes in Wine's `dbghelp` (division by zero in the DWARF expression evaluator), and Wine shows a crash dialog. **Fixed**: the reporter is disabled (`WINEDLLOVERRIDES=steamerrorreporter64.exe=d;…`) and the prefix's crash dialog is off (`HKCU\Software\Wine\WineDbg\ShowCrashDialog=0`). |
| Steam doesn't exit / hangs after the game | Steam's crash handler can hang after that exit crash. `play.sh`/`stop.sh` detect the new crash dump and end the session with `wineserver -k`. Use the Desktop stop launcher if you quit Steam by hand. |
| **Game closes by itself** a few seconds after start (no crash, `Launch.log` ends with `All Windows Closed`) | Seen once with Steam's in-game overlay on: the game closed 0.15 s after one of Steam's overlay processes exited. The overlay is now **off by default**. If it still happens, send `Launch.log` and `logs/steam-*.log` (redacted). |
| **Mac fans spin up / a huge `logs/steam-*.log`** after quitting | Seen once: Steam hung while quitting, its wineserver had to be killed, and three Wine processes lived on without it, spinning and writing errors (~4.5 MB/s). **Fixed**: `play.sh`/`stop.sh` now kill any leftover process of this setup after the shutdown and before each start. Running the stop launcher once also cleans up. |
| FPS summary shows a very low min / 1% low | The ~1.5 s averages include loading hitches, the intro movies (capped at ~30 fps) and menu transitions. Compare runs of the same scene only (see Comparing). |
| No FPS box | Check that you didn't pass `--no-hud`. Look at the game window's top-left corner. `logs/fpsbar-status.txt` shows what the counter sees (`box onscreen=1`, `box_in_front_of_game=1`). `logs/steam-*.log` should contain `@ approx NN.NNfps` lines. |
| "Another Wine Steam … is running" | Quit CrossOver's Steam (Steam menu > Exit) or run the other setup's stop launcher. One Steam at a time. |
| Freeze at the main menu | Make sure no DXVK `d3d9.dll` was copied into the game folder. If it happens on the Metal default, try `--renderer=gl` and report it. |
| "Your video card does not support alpha blending with floating point render targets…" and the game quits | `--renderer=mtld3d` with the build's old bundled mtld3d v0.7.0. The installer replaces it with v0.11.0; re-run `./install.sh`, or use `--renderer=gl`. |
| Graphics glitches with `--renderer=mtld3d` | Version 0.5.1 includes the tested short-stride DLL for fog of war and move highlights. Re-run the installer to verify/repair it. The launcher creates `mtld3d.conf` with NVIDIA spoofing and SDR settings if missing; existing custom config is preserved. If glitches remain, try `--renderer=gl` and report the scene and settings. |
| Crash when a mission starts | Turn **Ambient Occlusion** on in the game's graphics options (or `install.sh --game-config`). |
| Low fps | Check that `logs/steam-*.log` shows the sidecar attaching to `XComEW.exe` (`attaching rosettax87 … XComEW.exe`); set a lower resolution in the game. |
| Steam asks to log in every time | Tick *Remember me* at login. |
| `x87sidecar --probe` says unsupported | Your Rosetta version is newer than the sidecar knows. Use `--no-x87` and check for a new x87sidecar release. |
| "Loading user settings" hangs on the main menu | Cause not isolated. Keep Ambient Occlusion enabled; wait briefly or restart. |

**Test scope:** Enemy Within was tested; the base Enemy Unknown executable is not covered by the automatic launcher or x87 filter. A clean install on another account/Mac remains untested.

Logs: `<install dir>/logs/` (`steam-*.log`, `game-*.log`) and the game's own
`~/Documents/My Games/XCOM - Enemy Within/XComGame/Logs/Launch.log`. They contain local paths and account
names: **redact before sharing**.

## Uninstall

```bash
./uninstall.sh                # = ./install.sh --uninstall   (add --dir DIR if you used one; --dry-run works too)
```

Stops the setup if it runs, asks for confirmation, removes the install folder (Wine, prefix, Steam login, the game
copy) and the two Desktop launchers (only if unchanged). **Not touched:** your saves/settings in `~/Documents/My
Games`, CrossOver and its bottles, and `XComEngine.ini` (the backup path is printed).

## Known issues

- **Tested on one Mac only.** Please report results (with redacted logs).
- **FPS counter:** Metal sessions use Apple's Metal HUD log as the data source, with our small FPS box showing it. OpenGL sessions use Wine's frame trace. Windowed mode was checked; fullscreen placement still needs testing.
- **Steam overlay off by default:** under this Wine, Steam starts `gameoverlayui64.exe` 7 times per game start
  and 6 of them exit at once. In one test run the game closed itself, cleanly, 0.15 s after the 7th exited (at
  the intro movie, with no input and no outside trigger). With the overlay disabled (Wine DLL overrides for
  `gameoverlayrenderer`/`gameoverlayui`), none of it runs, and three runs stayed up at the main menu. The
  overlay (Shift+Tab, Steam chat) is only available with `--overlay`. Because the self-close was rare, the link
  is likely but not proven (see TECHNICAL.md).
- **`--direct` stalls Steam:** launching `XComEW.exe` without Steam as parent works (CEG passes), but Steam's main
  loop then stalls (`BMainLoop appears to have stalled`) and never registers the game's exit. The default
  Steam-parented launch doesn't do that.
- **Steam.exe crashes on exit under Wine** (also in CrossOver). It is harmless, and the dialog and the hang are
  handled (see Troubleshooting).
- **The tutorial may start from the main menu** after ~5–40 s in some test sessions (`Command1 … ControlledStartFromShell`).
  It is unclear whether the game does it by itself or keystrokes reached the game window (it takes the keyboard
  focus when it opens). It may create tutorial autosaves.
- **Rosetta 2's future:** Apple has said full Rosetta remains through macOS 27 and will be limited afterwards.
  x87sidecar depends on Rosetta internals and may need updates after macOS updates (`--no-x87` as a fallback).
- Wine prints `attaching rosettax87` lines for every 32-bit process. That's the build's hook asking; the filter
  attaches the sidecar only to `XComEW.exe`.
- **No real fps benchmark yet.** The tester reported playable fps with all fixes (about 5 fps before any fix). Main
  menu only, ~1 min each, not a fair benchmark: free mode average 51.7 / median 58.6, CrossOver mode 61.6 / 68.3
  (steady menu ~67 vs ~77). See TECHNICAL.md section 15 and the method below.

## Renderers (free mode)

XCOM is a 32-bit Direct3D 9 game, so something has to translate d3d9 for the Mac. What was tried (v0.5.0,
details in TECHNICAL.md section 16):

| Renderer | Status | Main menu (same Mac, windowed 1280×832, back-to-back runs, intro skipped) |
|---|---|---|
| **mtld3d** (`--renderer=mtld3d`, **default**) | tactical visuals confirmed with `mtld3d.conf` and the original short-stride build; the bundled rebuild passes the graphics regression, with a fresh game check pending ([mtld3d#872](https://github.com/athei/mtld3d/pull/872)). Faster than OpenGL | **~160 fps** at the menu (median; 141–169), +145% vs OpenGL; a mission with the conf and stock DLL was median 72 |
| **wined3d on OpenGL** (`--renderer=gl`) | works, tested in battle. Fallback | ~65 fps at the menu (median; 55–73) |
| mtld3d v0.7.0 (bundled with the Wine build) | the game refuses to start ("…does not support alpha blending with floating point render targets…") | – |
| DXVK d3d9 / wined3d's Vulkan renderer | impossible in this build: no Vulkan/MoltenVK, and the Metal-thread signal fix that stopped DXVK freezing is not in it | – |
| D3DMetal (GPTK), DXMT | no d3d9 (they cover d3d10/11/12 only) | – |

On the Metal default, the FPS box and log work the same way; the numbers come from Apple's Metal HUD log (its
overlay stays hidden; `XCOM_MTLHUD_OPACITY=1` shows it), and the log is named `fps-free-mtld3d-<time>.csv`.
Compare with `compare-fps.sh free free-mtld3d` after one session of each on the same save. **Keep Ambient
Occlusion on** in both. If you see glitches (fog of war, shadows, effects) or a freeze, use `--renderer=gl`.

## Comparing free mode and CrossOver mode

Both launchers log every session to `~/Library/Logs/xcom-mac-fix/` (`fps-free-*.csv`, `fps-crossover-*.csv`).
The numbers are only comparable if the scene is the same, so:

1. Pick one save (ideally a quiet spot: the Ant Farm, or a tactical map with the camera at rest) and one set of
   graphics options and resolution. Don't change them between runs.
2. Quit everything else that uses the GPU or CPU heavily. Keep the Mac on power.
3. Run mode A: start with its Desktop launcher, load the save, leave the camera still (or do the same short camera
   pan each time) for **2–3 minutes**, then quit to the desktop from the game menu. Wait for the summary.
4. Make sure that mode's Steam has quit (only one Steam at a time): free mode closes its Steam by itself; in
   CrossOver mode quit Steam from its menu (Steam > Exit). Then run mode B the same way.
5. Repeat A and B once or twice more, **alternating** (A B A B), so warm caches and heat affect both.
6. Compare: `compare-fps.sh` (newest of each mode), or pick files: `compare-fps.sh A.csv B.csv`. For loading-free
   numbers of a run that loaded a save, skip more: `compare-fps.sh A.csv B.csv --skip 60`. Use the median and the
   spread across rounds rather than one run's average; differences under ~5% are within noise.

`compare-fps.sh` is in the free-mode folder (`<install dir>/compare-fps.sh`), in CrossOver mode's
`~/Library/Application Support/xcom-x87-fix/bin/`, and in `installer/freewine/` of this package.

## CrossOver mode

For people who own **CrossOver 26.0** and want to keep using their existing bottle:

```bash
./install.sh --crossover --dry-run --bottle Steam
./install.sh --crossover --bottle Steam        # uninstall: ./install.sh --crossover --uninstall
```

It makes an APFS clone of CrossOver's Wine tree in `~/Library/Application Support/xcom-x87-fix` and changes nothing
inside `CrossOver.app` or your bottle's files. Then:

- **NX:** a 1-byte patch in the clone's 32-bit `ntdll.dll` (the `jne` after `test byte [reg+0x5f],1`, located by
  pattern and refused unless exactly one match).
- **x87:** x87sidecar is **built from source** at a pinned commit (needs Xcode Command Line Tools and CMake 3.27+)
  and attached to `XComEW.exe` through a wrapper around the cloned loader, in the default `task_for_pid` attach
  mode. macOS may ask for an admin password once per login for the "developer tools" right.
- **d3d9:** built-in d3d9 for the session (`--dll d3d9=b`).
- **FPS box and FPS log**, the same as free mode (CrossOver 26.0's built-in d3d9 is wined3d too, with the same fps
  trace): `--no-hud`, `--no-fps` work the same, and logs are named `fps-crossover-*.csv`.
- **Enemy Within is pressed automatically** in the XCOM launcher (`--launcher` to choose yourself). The Terminal
  window stays open until the game exits and prints the FPS summary. Steam keeps running in CrossOver mode (quit
  it from its menu).
- Other options: `--no-x87`, `--debug=CHANNELS` (for the game process only).

It runs your **real** bottle (a cloned bottle fails CEG until validated). Desktop launchers: "XCOM Enemy Within
(CrossOver fix).command" and "XCOM (CrossOver fix) - stop.command". After a CrossOver update, re-install.
Only CrossOver 26.0.0.39794 is verified; others need `--force`.

Both modes can be installed side by side; just run one Steam at a time.

## What was done, in order

1. **Black screen** in CrossOver with the stock d3d9: a DXVK d3d9 ("d9vk") in the bottle was the earlier
   workaround (cause not investigated).
2. **~5 fps**: measured ~76,000 page faults/s and 931 writable+executable regions.
3. **NX fault storm** found and fixed (1-byte `ntdll.dll` patch in a CrossOver clone; athei's source fix in free mode).
4. **x87 sidecar** attached to the game only.
5. **d9vk freeze** at the main menu → built-in d3d9 for the game.
6. **Ambient Occlusion crash** at mission start → keep AO on.
7. **CEG and cloned bottles**: clones quit after 2–4 s until Steam re-validates; CrossOver mode runs the real bottle.
8. **Free-Wine path**: athei's open-source build, own prefix, installer and launchers, no CrossOver needed.
9. **Crash-reporter dialog** after Steam > Exit → reporter disabled, Wine crash dialog off.
10. **Game closing itself** → Steam overlay off by default.
11. **Orphan cleanup**: leftover Wine processes after a killed wineserver are removed.
12. **FPS box** (`fpsbar`).
13. **FPS in CrossOver mode and comparison logging** (CSV + summary per session, `compare-fps.sh`).
14. **Other renderers**: no Vulkan in the build (no DXVK); D3DMetal has no d3d9. mtld3d is the **default**
    (`--renderer=gl` falls back to OpenGL), ~2× the menu fps, and the tactical picture was confirmed with
    `mtld3d.conf` plus the short-stride fix in [mtld3d#872](https://github.com/athei/mtld3d/pull/872).
    TECHNICAL.md section 16.

Evidence for each step: TECHNICAL.md (section 0 has the table with links).

## Credits and licences

- **athei**: [wine-build](https://github.com/athei/wine-build) (the free Wine build used here) and
  [athei/wine](https://github.com/athei/wine) (NX fix 539aa62, x87 hook); [x87sidecar](https://github.com/athei/x87sidecar) (**MIT**);
  [mtld3d](https://github.com/athei/mtld3d) (d3d9 on Metal, **zlib**).
- The Wine build is compiled from **CodeWeavers' open-source CrossOver 26.3 Wine sources**. Wine is
  **LGPL-2.1-or-later**. Its source is available from CodeWeavers and athei's repositories; this installer only downloads
  the published release (it doesn't redistribute it).
- **Wine Mono** (MIT and other licences, see its release). **Lifeisawful**: [rosettax87_jit](https://github.com/Lifeisawful/rosettax87_jit),
  which x87sidecar began as a fork of. **The Wine project**, **CodeWeavers**, **DXVK**/MoltenVK authors.
- `xclick.exe` (launcher helper, source in `tools/xclick.c`): public domain / CC0.
- `fpsbar` (the FPS counter, source in `tools/fpsbar.m`): part of this project, MIT.
- Firaxis / 2K for XCOM. Valve for Steam.
- **This installer:** MIT License, Copyright (c) 2026 Hlbkomer; see [LICENSE](LICENSE). Third-party licences:
  [LICENSE-NOTE.md](LICENSE-NOTE.md).

## Disclaimer

Unofficial; not affiliated with or endorsed by CodeWeavers, Valve, 2K/Firaxis, Apple, the Wine project or athei.
Provided "as is" without warranty. The modified mtld3d DLL and its zlib licence are included (see `vendor/mtld3d/README.md`). No game, Steam, CrossOver or Wine runtime is bundled: free mode downloads the
published Wine build, Wine Mono, x87sidecar, mtld3d and Steam from their official sources, verifying the pinned sha256s
(Steam's installer is checked for being a Windows program only, because Valve updates it). You need your own Steam
copy of the game. **Back up your saves** (`~/Documents/My Games/XCOM - Enemy Within`) before trying it.
