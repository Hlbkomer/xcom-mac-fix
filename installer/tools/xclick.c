/* xclick: automate the XCOM Launcher under Wine (part of the XCOM Mac fix; public domain / CC0).
   usage: xclick.exe                -> list children of the "XCOM Launcher" window:
                                       hwnd class "text" at=x,y size=w,h vis (client coords of the launcher)
          xclick.exe click HWND     -> press that child (mouse down/up at its centre + BM_CLICK for buttons)
          xclick.exe ew [SECONDS]   -> wait up to SECONDS (default 120) for the launcher, then press the
                                       upper large button (Enemy Within). Exit 0 = clicked, 2 = no launcher.
   build: x86_64-w64-mingw32-gcc -municode -O2 -s -o xclick.exe xclick.c */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
static HWND top, best;
static LONG besty;
static BOOL CALLBACK en(HWND h, LPARAM lp) {
    wchar_t cls[128] = L"", txt[256] = L""; RECT r; POINT p;
    GetClassNameW(h, cls, 128); GetWindowTextW(h, txt, 256); GetWindowRect(h, &r);
    p.x = r.left; p.y = r.top; ScreenToClient(top, &p);
    if (lp) {   /* pick the topmost visible large child (the two game buttons are ~260x128; close is 32x32) */
        if (IsWindowVisible(h) && r.right - r.left >= 100 && r.bottom - r.top >= 60 && (!best || p.y < besty)) {
            best = h; besty = p.y;
        }
        return TRUE;
    }
    wprintf(L"%p %ls \"%ls\" at=%ld,%ld size=%ld,%ld vis=%d\n", (void *)h, cls, txt, p.x, p.y,
            r.right - r.left, r.bottom - r.top, IsWindowVisible(h));
    return TRUE;
}
static void press(HWND h) {
    RECT r; wchar_t cls[128] = L""; LPARAM lp;
    GetClientRect(h, &r); lp = MAKELPARAM(r.right / 2, r.bottom / 2); GetClassNameW(h, cls, 128);
    SetForegroundWindow(top);
    PostMessageW(h, WM_LBUTTONDOWN, MK_LBUTTON, lp); Sleep(80);
    PostMessageW(h, WM_LBUTTONUP, 0, lp);
    if (wcsstr(cls, L"BUTTON") || wcsstr(cls, L"Button")) PostMessageW(h, BM_CLICK, 0, 0);
    wprintf(L"clicked %p at %d,%d\n", (void *)h, r.right / 2, r.bottom / 2);
}
int wmain(int argc, wchar_t **argv) {
    if (argc >= 2 && !wcscmp(argv[1], L"ew")) {
        int secs = argc >= 3 ? _wtoi(argv[2]) : 120, i;
        for (i = 0; i < secs * 4; i++) {
            top = FindWindowW(NULL, L"XCOM Launcher");
            if (top && IsWindowVisible(top)) {
                best = NULL; EnumChildWindows(top, en, 1);
                if (best) { Sleep(750); press(best); return 0; }   /* short settle so the form is ready */
            }
            Sleep(250);
        }
        wprintf(L"no XCOM Launcher window\n"); return 2;
    }
    top = FindWindowW(NULL, L"XCOM Launcher");
    if (!top) { wprintf(L"no XCOM Launcher window\n"); return 2; }
    RECT tr; GetClientRect(top, &tr);
    wprintf(L"top=%p size=%ldx%ld\n", (void *)top, tr.right, tr.bottom);
    if (argc >= 3 && !wcscmp(argv[1], L"click")) {
        HWND h = (HWND)(ULONG_PTR)_wcstoui64(argv[2], NULL, 16);
        if (!IsWindow(h)) { wprintf(L"bad hwnd\n"); return 3; }
        press(h); return 0;
    }
    EnumChildWindows(top, en, 0);
    return 0;
}
