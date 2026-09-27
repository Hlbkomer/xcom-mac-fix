// fpsbar: a small always-on-top FPS readout for the free-Wine XCOM setup (xcom-mac-fix).
// Copyright (c) 2026 Hlbkomer. MIT License (see LICENSE).
//
// Usage: fpsbar [--csv FILE] [--status FILE] [--hidden] LOGFILE WATCH_PID [STATUSFILE]
//   Follows LOGFILE (from its current end) for the Wine "+fps" trace that wined3d prints about every
//   1.5 s ("... @ approx 59.94fps") and shows "FPS 60" in a small click-through box above all windows,
//   in the top-left corner of the game's window (or of the screen while no game window is found;
//   XCOM_FPS_POS=tl|tr|bl|br picks another corner). Shows "FPS -" when no number arrived for 5 s.
//   Exits when WATCH_PID (the game process) is gone. Needs no macOS permissions.
//   --csv FILE     one line per sample: "time,elapsed_s,fps" (local time with ms, seconds since fpsbar
//                  started, the fps value Wine printed). Used for the session summary and comparisons.
//   --status FILE  (or the 3rd argument) a short report every 2 s: whether the box is on screen and in
//                  front of the game's window (from CGWindowListCopyWindowInfo; no Screen Recording needed).
//   --hidden       no box, only the CSV/status logging.
//   Wine prints the same number from two places (opengl32's wglSwapBuffers and wined3d's present); only the
//   first source seen is used, so each sample is counted once.
//
// Build (macOS 11+):
//   clang -O2 -fobjc-arc -Wno-deprecated-declarations -mmacosx-version-min=11.0 -arch arm64 \
//         -framework AppKit -framework CoreGraphics -o fpsbar fpsbar.m
#import <AppKit/AppKit.h>
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>

static const char *gLogPath;
static pid_t gPid;
static NSString *gStatusPath;
static NSWindow *gWin;
static NSTextField *gLabel;
static FILE *gFP;
static off_t gOff = -1;
static char gBuf[65536];
static size_t gCarry;
static double gFps = -1;
static CFAbsoluteTime gFpsTime;
static unsigned long gSamples, gTicks;
static FILE *gCSV;
static char gSrc[64];
static BOOL gHidden;
static CFAbsoluteTime gStart;

static void record(double v) {
  gFps = v; gFpsTime = CFAbsoluteTimeGetCurrent(); gSamples++;
  if (!gCSV) return;
  struct timeval tv; gettimeofday(&tv, NULL);
  struct tm tm; localtime_r(&tv.tv_sec, &tm);
  char ts[32]; strftime(ts, sizeof ts, "%Y-%m-%dT%H:%M:%S", &tm);
  fprintf(gCSV, "%s.%03d,%.1f,%.2f\n", ts, (int)(tv.tv_usec / 1000), gFpsTime - gStart, v);
  fflush(gCSV);
}

// one complete log line; "....:trace:fps:<source> [ptr] @ approx 59.94fps[, total ...]"
static void handleLine(const char *s, size_t n) {
  const char *a = memmem(s, n, "@ approx ", 9);
  if (!a) return;
  char *e = NULL;
  double v = strtod(a + 9, &e);
  if (!e || e == a + 9 || e + 3 > s + n || strncmp(e, "fps", 3) != 0 || v < 0 || v >= 100000) return;
  char src[64] = "";
  const char *t = memmem(s, (size_t)(a - s), ":fps:", 5);
  if (t) {
    t += 5; size_t k = 0;
    while (t + k < a && t[k] != ' ' && k < sizeof src - 1) k++;
    memcpy(src, t, k); src[k] = 0;
  }
  if (!gSrc[0]) strlcpy(gSrc, src[0] ? src : "?", sizeof gSrc);
  else if (strcmp(gSrc, src[0] ? src : "?") != 0) return;
  record(v);
}

static void readLog(void) {
  if (!gFP) {
    gFP = fopen(gLogPath, "rb");
    if (!gFP) return;
    if (gOff < 0) { fseeko(gFP, 0, SEEK_END); gOff = ftello(gFP); }
  }
  struct stat st;
  if (fstat(fileno(gFP), &st) == 0 && st.st_size < gOff) { gOff = 0; gCarry = 0; }  // truncated
  fseeko(gFP, gOff, SEEK_SET);
  for (;;) {
    size_t n = fread(gBuf + gCarry, 1, sizeof(gBuf) - 1 - gCarry, gFP);
    if (n == 0) break;
    gOff += (off_t)n;
    size_t len = gCarry + n;
    gBuf[len] = 0;
    char *p = gBuf, *end = gBuf + len, *nl;
    while (p < end && (nl = memchr(p, '\n', (size_t)(end - p)))) { handleLine(p, (size_t)(nl - p)); p = nl + 1; }
    size_t rest = (size_t)(end - p);               // incomplete last line: keep it for the next read
    if (rest > sizeof(gBuf) / 2) rest = 0;         // absurdly long line: drop it
    memmove(gBuf, p, rest);
    gCarry = rest;
  }
  clearerr(gFP);
}

static CGRect gGameRect;                            // game window, CG coordinates (top-left origin); empty = none

static void findGame(void) {                        // largest on-screen window of the game process
  NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
  double best = 0; gGameRect = CGRectZero;
  for (NSDictionary *d in list) {
    if ([d[(__bridge id)kCGWindowOwnerPID] intValue] != gPid) continue;
    CGRect r = CGRectZero;
    CFDictionaryRef b = (__bridge CFDictionaryRef)d[(__bridge id)kCGWindowBounds];
    if (b) CGRectMakeWithDictionaryRepresentation(b, &r);
    if (r.size.width >= 320 && r.size.height >= 200 && r.size.width * r.size.height > best) {
      best = r.size.width * r.size.height; gGameRect = r;
    }
  }
}

static void place(void) {
  NSArray<NSScreen *> *screens = [NSScreen screens];
  if (!screens.count) return;
  CGFloat H = NSMaxY(screens[0].frame);             // CG y runs down from the top of the menu-bar screen
  NSRect f;
  CGFloat top;                                      // gap to the top edge (clears the menu bar on the screen)
  if (!CGRectIsEmpty(gGameRect)) {
    f = NSMakeRect(gGameRect.origin.x, H - CGRectGetMaxY(gGameRect), gGameRect.size.width, gGameRect.size.height);
    top = 8;
    if (NSMaxY(f) > H - 34) top = 8 + (NSMaxY(f) - (H - 34));   // game touches the menu bar/notch area
  } else { f = screens[0].frame; top = 40; }
  NSSize z = gWin.frame.size;
  const char *pos = getenv("XCOM_FPS_POS");
  NSString *p = pos ? [NSString stringWithUTF8String:pos] : @"tl";
  CGFloat x = NSMinX(f) + 8, y = NSMaxY(f) - z.height - top;
  if ([p hasSuffix:@"r"]) x = NSMaxX(f) - z.width - 8;
  if ([p hasPrefix:@"b"]) y = NSMinY(f) + 8;
  if (!NSEqualPoints(gWin.frame.origin, NSMakePoint(x, y))) [gWin setFrameOrigin:NSMakePoint(x, y)];
}

static NSString *boundsStr(NSDictionary *d) {
  CGRect r = CGRectZero;
  CFDictionaryRef b = (__bridge CFDictionaryRef)d[(__bridge id)kCGWindowBounds];
  if (b) CGRectMakeWithDictionaryRepresentation(b, &r);
  return [NSString stringWithFormat:@"%.0f,%.0f %.0fx%.0f", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

static void writeStatus(void) {
  if (!gStatusPath) return;
  NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));  // front to back
  CGWindowID mine = gWin ? (CGWindowID)gWin.windowNumber : 0;
  long selfIdx = -1, gameIdx = -1, gameWins = 0; NSDictionary *selfD = nil, *gameD = nil; double best = 0;
  for (NSUInteger i = 0; i < list.count; i++) {
    NSDictionary *d = list[i];
    if ([d[(__bridge id)kCGWindowNumber] unsignedIntValue] == mine) { selfIdx = (long)i; selfD = d; continue; }
    if ([d[(__bridge id)kCGWindowOwnerPID] intValue] != gPid) continue;
    gameWins++;
    CGRect r = CGRectZero;
    CFDictionaryRef b = (__bridge CFDictionaryRef)d[(__bridge id)kCGWindowBounds];
    if (b) CGRectMakeWithDictionaryRepresentation(b, &r);
    if (r.size.width * r.size.height > best) { best = r.size.width * r.size.height; gameIdx = (long)i; gameD = d; }
  }
  NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"HH:mm:ss";
  double age = gFps >= 0 ? CFAbsoluteTimeGetCurrent() - gFpsTime : -1;
  NSMutableString *s = [NSMutableString string];
  [s appendFormat:@"time=%@ shown=\"%@\" fps=%.1f age_s=%.1f samples=%lu source=%s hidden=%d\n",
                  [df stringFromDate:[NSDate date]], gLabel ? gLabel.stringValue : @"-", gFps, age, gSamples,
                  gSrc[0] ? gSrc : "-", gHidden];
  [s appendFormat:@"box onscreen=%d index=%ld layer=%@ bounds=%@\n", selfD != nil, selfIdx,
                  selfD[(__bridge id)kCGWindowLayer] ?: @"-", selfD ? boundsStr(selfD) : @"-"];
  [s appendFormat:@"game windows_onscreen=%ld index=%ld layer=%@ bounds=%@\n", gameWins, gameIdx,
                  gameD[(__bridge id)kCGWindowLayer] ?: @"-", gameD ? boundsStr(gameD) : @"-"];
  [s appendFormat:@"box_in_front_of_game=%d display_captured=%d\n",
                  selfD && gameD && selfIdx < gameIdx, CGDisplayIsCaptured(CGMainDisplayID()) ? 1 : 0];
  [s writeToFile:gStatusPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static void tick(void) {
  if (kill(gPid, 0) != 0 && errno == ESRCH) exit(0);
  readLog();
  ++gTicks;
  if (gWin) {
    BOOL fresh = gFps >= 0 && CFAbsoluteTimeGetCurrent() - gFpsTime < 5;
    gLabel.stringValue = fresh ? [NSString stringWithFormat:@"FPS %.0f", gFps] : @"FPS -";
    NSInteger want = CGDisplayIsCaptured(CGMainDisplayID()) ? CGShieldingWindowLevel() + 1 : NSScreenSaverWindowLevel;
    if (gWin.level != want) gWin.level = want;
    if (gTicks % 2 == 0) { findGame(); place(); }
    if (gTicks % 4 == 0) [gWin orderFrontRegardless];
  }
  if (gTicks % 4 == 0) writeStatus();
}

int main(int argc, char **argv) {
  @autoreleasepool {
    const char *csv = NULL; int i = 1;
    for (; i < argc && strncmp(argv[i], "--", 2) == 0; i++) {
      if (!strcmp(argv[i], "--csv") && i + 1 < argc) csv = argv[++i];
      else if (!strcmp(argv[i], "--status") && i + 1 < argc) gStatusPath = [NSString stringWithUTF8String:argv[++i]];
      else if (!strcmp(argv[i], "--hidden")) gHidden = YES;
      else { fprintf(stderr, "fpsbar: unknown option %s\n", argv[i]); return 2; }
    }
    if (argc - i < 2) { fprintf(stderr, "usage: fpsbar [--csv FILE] [--status FILE] [--hidden] LOGFILE WATCH_PID [STATUSFILE]\n"); return 2; }
    gLogPath = argv[i];
    gPid = (pid_t)atoi(argv[i + 1]);
    if (gPid <= 0) { fprintf(stderr, "fpsbar: bad pid\n"); return 2; }
    if (argc - i > 2) gStatusPath = [NSString stringWithUTF8String:argv[i + 2]];
    gStart = CFAbsoluteTimeGetCurrent();
    if (csv) {
      gCSV = fopen(csv, "w");
      if (!gCSV) { perror(csv); return 1; }
      fprintf(gCSV, "time,elapsed_s,fps\n"); fflush(gCSV);
    }
    signal(SIGHUP, SIG_IGN);
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    if (!gHidden) {
      gWin = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 104, 30) styleMask:NSWindowStyleMaskBorderless
                                           backing:NSBackingStoreBuffered defer:NO];
      gWin.opaque = NO;
      gWin.backgroundColor = NSColor.clearColor;
      gWin.hasShadow = NO;
      gWin.ignoresMouseEvents = YES;
      gWin.releasedWhenClosed = NO;
      gWin.level = NSScreenSaverWindowLevel;
      gWin.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                                NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
      NSView *bg = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 104, 30)];
      bg.wantsLayer = YES;
      bg.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.7].CGColor;
      bg.layer.cornerRadius = 7;
      gLabel = [NSTextField labelWithString:@"FPS -"];
      gLabel.frame = NSMakeRect(4, 4, 96, 22);
      gLabel.alignment = NSTextAlignmentCenter;
      gLabel.font = [NSFont monospacedDigitSystemFontOfSize:16 weight:NSFontWeightBold];
      gLabel.textColor = [NSColor colorWithRed:0.45 green:1.0 blue:0.35 alpha:1];
      [bg addSubview:gLabel];
      gWin.contentView = bg;
      findGame();
      place();
      [gWin orderFrontRegardless];
    }
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { (void)t; tick(); }];
    tick();
    [NSApp run];
  }
  return 0;
}
