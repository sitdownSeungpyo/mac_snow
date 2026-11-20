// WinterDesk for Windows: entry point, overlay window, tray menu, hotkeys, frame pacing, live
// window tracking, light editing, persistence, safety (watchdog, sentinel, safe mode).
#include "winterdesk.h"
#include <windowsx.h>
#include <shellapi.h>
#include <wtsapi32.h>
#include <atomic>
#include <thread>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "wtsapi32.lib")

namespace {

enum : UINT {
    WM_TRAY = WM_APP + 1,
    ID_EFFECTS = 100, ID_EDITLIGHTS, ID_SNOW, ID_INT_LIGHT, ID_INT_NORMAL, ID_INT_HEAVY, ID_MODE_DESKTOP, ID_MODE_ONTOP,
    ID_SANTA, ID_PLOW, ID_WINSNOW, ID_LIGHTS, ID_LIVE, ID_DRAG_SLIDES, ID_DRAG_STAYS, ID_LINKS_AUTO, ID_LINKS_MANUAL,
    ID_GARLANDS, ID_STYLE_MULTI, ID_STYLE_WARM, ID_STYLE_CLASSIC, ID_STYLE_ICY, ID_STYLE_CANDY, ID_ADDGIFT, ID_CLEARBALLS, ID_CLEARALL, ID_RESET, ID_LOGIN, ID_GLITCH, ID_QUIT,
    ID_BALL_DELETE, ID_SETTINGS,
    HK_QUIT = 1, HK_EFFECTS, HK_SNOW, HK_SANTA, HK_PLOW, HK_LIGHTEDIT, HK_GLITCH, HK_SETTINGS,
    TIMER_HEARTBEAT = 1, TIMER_REBUILD, TIMER_MENU, TIMER_STARTHINT, TIMER_TRAYCLICK,
};

// ---------------------------------------------------------------------------------------------
// Watchdog: terminates when the UI thread stalls > 3 s (recording the reason so the next launch
// starts in safe mode), and enforces --test-seconds even when the UI thread is hung. Time is
// measured without suspend; a long gap in its own loop (system sleep) is not a stall.
// ---------------------------------------------------------------------------------------------
ULONGLONG AwakeMs()
{
    ULONGLONG t = 0;
    QueryUnbiasedInterruptTime(&t);
    return t / 10000;
}

class Watchdog {
public:
    void Start(double testSeconds)
    {
        Beat();
        deadline_ = testSeconds > 0 ? AwakeMs() + (ULONGLONG)(testSeconds * 1000) + 2500 : 0;
        thread_ = std::thread([this] { Loop(); });
    }
    void Stop()
    {
        stop_ = true;
        if (thread_.joinable()) thread_.join();
    }
    void Beat() { heartbeat_ = AwakeMs(); }
    std::atomic<HWND> overlay{nullptr};

private:
    void Loop()
    {
        ULONGLONG last = AwakeMs();
        while (!stop_) {
            Sleep(250);
            ULONGLONG now = AwakeMs();
            if (now - last > 2000) Beat();        // we were suspended (sleep / hibernate), not stalled
            last = now;
            if (deadline_ && now > deadline_) { Logf(L"watchdog: --test-seconds deadline passed, terminating"); Kill(2, nullptr); }
            ULONGLONG age = now - heartbeat_.load();
            if (age > 3000) {
                wchar_t why[96];
                swprintf_s(why, L"main thread stalled for %.1fs", age / 1000.0);
                Logf(L"watchdog: %s, terminating", why);
                Kill(3, why);
            }
        }
    }
    void Kill(UINT code, const wchar_t* reason)
    {
        if (reason) RecordSafetyStop(reason);
        HWND h = overlay.load();
        if (h) ShowWindowAsync(h, SW_HIDE);
        TerminateProcess(GetCurrentProcess(), code);
    }
    std::atomic<ULONGLONG> heartbeat_{0};
    ULONGLONG deadline_ = 0;
    std::atomic<bool> stop_{false};
    std::thread thread_;
};

/// Snowflake tray icon drawn in code (distance-field lines, straight alpha).
HICON MakeFlakeIcon(int size, bool dim)
{
    BITMAPV5HEADER bi{};
    bi.bV5Size = sizeof(bi);
    bi.bV5Width = size;
    bi.bV5Height = -size;
    bi.bV5Planes = 1;
    bi.bV5BitCount = 32;
    bi.bV5Compression = BI_BITFIELDS;
    bi.bV5RedMask = 0x00FF0000;
    bi.bV5GreenMask = 0x0000FF00;
    bi.bV5BlueMask = 0x000000FF;
    bi.bV5AlphaMask = 0xFF000000;
    void* bits = nullptr;
    HDC hdc = GetDC(nullptr);
    HBITMAP color = CreateDIBSection(hdc, reinterpret_cast<BITMAPINFO*>(&bi), DIB_RGB_COLORS, &bits, nullptr, 0);
    ReleaseDC(nullptr, hdc);
    if (!color) return nullptr;
    struct Seg { float ax, ay, bx, by; };
    std::vector<Seg> segs;
    float c = size / 2.f, r = size * 0.44f;
    for (int k = 0; k < 6; k++) {
        float a = k * kPi / 3 + kPi / 2;
        segs.push_back({c, c, c + std::cos(a) * r, c - std::sin(a) * r});
        float bx = c + std::cos(a) * r * 0.58f, by = c - std::sin(a) * r * 0.58f;
        for (int sgn = -1; sgn <= 1; sgn += 2) {
            float b = a + sgn * 0.75f;
            segs.push_back({bx, by, bx + std::cos(b) * r * 0.32f, by - std::sin(b) * r * 0.32f});
        }
    }
    float ink[3] = {0.55f, dim ? 0.6f : 0.82f, dim ? 0.68f : 1.f};
    float edge[3] = {dim ? 0.25f : 0.1f, dim ? 0.27f : 0.3f, dim ? 0.3f : 0.55f};
    float wEdge = size * 0.16f, wInk = size * 0.08f;
    uint32_t* px = static_cast<uint32_t*>(bits);
    for (int y = 0; y < size; y++)
        for (int x = 0; x < size; x++) {
            float p0 = x + 0.5f, p1 = y + 0.5f, dmin = 1e9f;
            for (const Seg& s : segs) {
                float vx = s.bx - s.ax, vy = s.by - s.ay;
                float t = Clampf(((p0 - s.ax) * vx + (p1 - s.ay) * vy) / (vx * vx + vy * vy), 0, 1);
                dmin = std::min(dmin, std::hypot(p0 - (s.ax + t * vx), p1 - (s.ay + t * vy)));
            }
            float ae = Clampf(wEdge / 2 + 0.5f - dmin, 0, 1), ai = Clampf(wInk / 2 + 0.5f - dmin, 0, 1);
            float a = ai + ae * (1 - ai);
            if (dim) a *= 0.55f;
            uint32_t out = 0;
            if (a > 0) {
                uint32_t ch[3];
                float al = ai + ae * (1 - ai);
                for (int i = 0; i < 3; i++) ch[i] = (uint32_t)std::lround((ink[i] * ai + edge[i] * ae * (1 - ai)) / al * 255);
                out = ((uint32_t)std::lround(a * 255) << 24) | (ch[0] << 16) | (ch[1] << 8) | ch[2];
            }
            px[y * size + x] = out;
        }
    std::vector<BYTE> zeros((size_t)((size + 15) / 16 * 2) * size, 0);
    HBITMAP mask = CreateBitmap(size, size, 1, 1, zeros.data());
    ICONINFO ii{TRUE, 0, 0, mask, color};
    HICON icon = CreateIconIndirect(&ii);
    DeleteObject(mask);
    DeleteObject(color);
    return icon;
}

std::wstring RectStr(const RECT& r)
{
    wchar_t b[96];
    swprintf_s(b, L"%ld,%ld %ldx%ld", r.left, r.top, r.right - r.left, r.bottom - r.top);
    return b;
}

class App;
App* g_app = nullptr;

class App {
public:
    int Run(HINSTANCE inst, bool safe, const std::wstring& safeWhy, double testSeconds, bool testMode);
    LRESULT CtlProc(HWND h, UINT m, WPARAM w, LPARAM l);
    LRESULT OverlayProc(HWND h, UINT m, WPARAM w, LPARAM l);
    void OnWinEvent(DWORD ev, HWND h, LONG obj, LONG child);

private:
    void Tick(bool vsync);
    void SlowTick(double now);
    void RenderFrame(double now, Activity act);
    void CursorPoll();
    bool SettingsOnTopAt(HWND sw, POINT pt) const;
    void SetClickThrough(bool through);
    bool BuildOverlay();
    bool CreateOverlayWindowAndRenderer();
    void DestroyOverlayWindow();
    void TearDown();
    void Rebuild(const wchar_t* why);
    void UpdateRunning();
    void SaveState();
    bool FullscreenOnDisplay();
    void ApplyMode();
    void KeepAboveDesktop(bool log);
    void ShowMenu(const POINT* at = nullptr);
    void CancelTrayClick() { if (ctl_) KillTimer(ctl_, TIMER_TRAYCLICK); }
    void Command(UINT id);
    void OpenSettings(int tab);
    void UiCommand(int sc);
    void Changed();
    void Toast(const std::wstring& t, bool force = false);
    void ToggleEffects();
    void ToggleLightEdit();
    bool EnterLightEdit();
    void ExitLightEdit(bool silent);
    void LinksChanged();
    void ReportGlitch();
    void UpdateLiveHooks();
    void AddTray();
    void UpdateTrayIcon();
    void Quit() { PostQuitMessage(0); }
    UINT RunPopupMenu(HMENU m, POINT pt, UINT flags);
    UINT SyncFor(Activity a) const;
    PanelHost Host() const { return {disp_.bounds, disp_.work, std::max(0.5f, disp_.scale)}; }
    std::wstring OffStateText() const;

    HINSTANCE inst_ = nullptr;
    Settings settings_;
    double testDeadline_ = 0, startTime_ = 0;
    bool sentinelCleared_ = false;
    Watchdog dog_;
    HWND ctl_ = nullptr, overlay_ = nullptr;
    DisplayInfo disp_;
    bool haveDisp_ = false;
    std::unique_ptr<Renderer> rend_;
    std::unique_ptr<Scene> scene_;
    bool visible_ = false, clickThrough_ = true;
    bool locked_ = false, suspended_ = false, fullscreen_ = false;
    bool inMenu_ = false, quitting_ = false;
    bool lightEdit_ = false;
    bool testMode_ = false, needShow_ = false, lastPrimaryDown_ = false;
    double primaryUpSince_ = -1, retryDelay_ = 5;
    UINT msgState_ = 0, msgSanta_ = 0, msgBall_ = 0, msgEdit_ = 0, msgCommand_ = 0, msgHit_ = 0, msgSnowman_ = 0, msgCustomize_ = 0, msgSettings_ = 0;
    std::vector<SavedGift> savedGifts_;
    bool haveSaved_ = false, defaultGiftRemovedThisSession_ = false;
    std::vector<SavedRider> pendingRiders_;
    std::vector<SavedLink> pendingLinks_;
    HICON iconOn_ = nullptr, iconOff_ = nullptr, iconBig_ = nullptr;
    bool traySkipSelect_ = false;      // the NIN_SELECT of a double-click's second release is ignored
    POINT trayPt_{};                   // icon anchor of the pending single click (menu goes there)
    HWND trayFg_ = nullptr;            // foreground at that click: a change cancels the pending menu
    UINT wmTaskbarCreated_ = 0;
    NOTIFYICONDATAW nid_{};
    HWINEVENTHOOK hooks_[5] = {};
    std::unordered_map<DWORD, HWINEVENTHOOK> liveHooks_;
    double lastFrame_ = 0, lastUpdate_ = 0, lastCursor_ = 0, lastPoll_ = 0, lastSlow_ = 0, lastTopmost_ = 0;
    double stateSaveTimer_ = 0, lastStats_ = 0, renderFailAt_ = -100;
    bool pollRequested_ = false, fsCheckRequested_ = false;
    bool powerSaving_ = false;
    std::wstring desktopLayout_;
    int statFrames_ = 0, statWakeups_ = 0, statEvents_ = 0, statPolls_ = 0;
    double statWork_ = 0, statUpdate_ = 0, statDraw_ = 0, statPoll_ = 0, statCursor_ = 0;
    ULONGLONG statCpu0_ = 0;
};

LRESULT CALLBACK CtlProcThunk(HWND h, UINT m, WPARAM w, LPARAM l) { return g_app ? g_app->CtlProc(h, m, w, l) : DefWindowProcW(h, m, w, l); }
LRESULT CALLBACK OverlayProcThunk(HWND h, UINT m, WPARAM w, LPARAM l) { return g_app ? g_app->OverlayProc(h, m, w, l) : DefWindowProcW(h, m, w, l); }
void CALLBACK WinEventThunk(HWINEVENTHOOK, DWORD ev, HWND h, LONG obj, LONG child, DWORD, DWORD)
{
    if (g_app) g_app->OnWinEvent(ev, h, obj, child);
}

ULONGLONG ProcessCpu100ns()
{
    FILETIME c, e, k, u;
    if (!GetProcessTimes(GetCurrentProcess(), &c, &e, &k, &u)) return 0;
    return (((ULONGLONG)k.dwHighDateTime << 32) | k.dwLowDateTime) + (((ULONGLONG)u.dwHighDateTime << 32) | u.dwLowDateTime);
}

// =============================================================================================
// Startup / main loop
// =============================================================================================

int App::Run(HINSTANCE inst, bool safe, const std::wstring& safeWhy, double testSeconds, bool testMode)
{
    inst_ = inst;
    testMode_ = testMode;
    settings_.Load();
    if (safe) {
        // runtime mask only: Desktop mode and no window snow / lights while it lasts; the saved
        // settings keep the user's own values
        settings_.safeMode = true;
        settings_.safeReason = safeWhy;
        Logf(L"%s: Desktop mode, window snow/lights off for this run (saved settings unchanged)", safeWhy.c_str());
    }
    RefreshLaunchAtLogin();
    // automation messages (registered names; handled only with --test / --test-seconds / --selftest)
    msgState_ = RegisterWindowMessageW(L"WinterDesk.Test.State");
    msgSanta_ = RegisterWindowMessageW(L"WinterDesk.Test.Santa");
    msgBall_ = RegisterWindowMessageW(L"WinterDesk.Test.Ball");
    msgEdit_ = RegisterWindowMessageW(L"WinterDesk.Test.LightEdit");
    msgCommand_ = RegisterWindowMessageW(L"WinterDesk.Test.Command");
    msgHit_ = RegisterWindowMessageW(L"WinterDesk.Test.HitTest");
    msgSnowman_ = RegisterWindowMessageW(L"WinterDesk.Test.Snowman");
    msgCustomize_ = RegisterWindowMessageW(L"WinterDesk.Test.Customize");
    msgSettings_ = RegisterWindowMessageW(L"WinterDesk.Test.Settings");
    haveSaved_ = LoadGifts(savedGifts_);
    pendingRiders_ = LoadRiders();
    pendingLinks_ = LoadLinks();
    Logf(L"restored state: %d gifts, %d window snowmen, %d light links pending", (int)savedGifts_.size(), (int)pendingRiders_.size(),
         (int)pendingLinks_.size());
    startTime_ = NowSec();
    if (testSeconds > 0) testDeadline_ = startTime_ + testSeconds;
    dog_.Start(testSeconds);
    PanelsInit(inst);

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = CtlProcThunk;
    wc.hInstance = inst;
    wc.lpszClassName = L"WinterDeskControl";
    RegisterClassExW(&wc);
    WNDCLASSEXW oc{};
    oc.cbSize = sizeof(oc);
    oc.style = CS_DBLCLKS;
    oc.lpfnWndProc = OverlayProcThunk;
    oc.hInstance = inst;
    oc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    oc.lpszClassName = L"WinterDeskOverlay";
    RegisterClassExW(&oc);

    // hidden top-level window: tray callbacks, hotkeys, display/power/session notifications
    ctl_ = CreateWindowExW(WS_EX_TOOLWINDOW, wc.lpszClassName, L"WinterDesk", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr, inst, nullptr);
    if (!ctl_) { Logf(L"control window creation failed (%lu)", GetLastError()); dog_.Stop(); return 1; }
    wmTaskbarCreated_ = RegisterWindowMessageW(L"TaskbarCreated");
    WTSRegisterSessionNotification(ctl_, NOTIFY_FOR_THIS_SESSION);
    SetTimer(ctl_, TIMER_HEARTBEAT, 1000, nullptr);

    const struct { int id; UINT vk; const wchar_t* name; } keys[] = {{HK_QUIT, 'Q', L"Q"}, {HK_EFFECTS, 'E', L"E"}, {HK_SNOW, 'S', L"S"},
        {HK_SANTA, 'D', L"D"}, {HK_PLOW, 'P', L"P"}, {HK_LIGHTEDIT, 'L', L"L"}, {HK_GLITCH, 'G', L"G"}, {HK_SETTINGS, 'O', L"O"}};
    std::wstring reg;
    for (const auto& k : keys) {
        if (RegisterHotKey(ctl_, k.id, MOD_CONTROL | MOD_ALT | MOD_SHIFT | MOD_NOREPEAT, k.vk)) reg += k.name;
        else Logf(L"hotkey Ctrl+Alt+Shift+%s unavailable (skipped)", k.name);
    }
    Logf(L"hotkeys registered (Ctrl+Alt+Shift+): %s", reg.c_str());

    int iconSize = GetSystemMetrics(SM_CXSMICON);
    iconOn_ = MakeFlakeIcon(iconSize, false);
    iconOff_ = MakeFlakeIcon(iconSize, true);
    iconBig_ = MakeFlakeIcon(GetSystemMetrics(SM_CXICON), false);
    AddTray();

    const DWORD flags = WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS;
    hooks_[0] = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr, WinEventThunk, 0, 0, flags);
    hooks_[1] = SetWinEventHook(EVENT_SYSTEM_MOVESIZESTART, EVENT_SYSTEM_MINIMIZEEND, nullptr, WinEventThunk, 0, 0, flags);
    hooks_[2] = SetWinEventHook(EVENT_OBJECT_DESTROY, EVENT_OBJECT_HIDE, nullptr, WinEventThunk, 0, 0, flags);
    hooks_[3] = SetWinEventHook(EVENT_OBJECT_CLOAKED, EVENT_OBJECT_UNCLOAKED, nullptr, WinEventThunk, 0, 0, flags);

    statCpu0_ = ProcessCpu100ns();
    lastStats_ = NowSec();
    Rebuild(L"startup");
    std::wstring off = OffStateText();
    if (!off.empty() || settings_.safeMode) SetTimer(ctl_, TIMER_STARTHINT, 1500, nullptr);

    MSG msg;
    while (!quitting_) {
        double now = NowSec();
        double next = lastSlow_ + 0.5;
        if (testDeadline_ > 0) next = std::min(next, testDeadline_);
        bool waitVsync = false;
        if (scene_ && visible_ && rend_) {
            Activity act = scene_->GetActivity();
            next = std::min(next, lastCursor_ + 0.016);
            next = std::min(next, lastPoll_ + (pollRequested_ ? 0.03 : (scene_->WindowsBusy() ? 0.1 : 0.25)));
            if (act >= ActNormal) {
                double due = lastFrame_ + (act == ActHigh ? 1 / 60.0 : 1 / 30.0) - 0.006;
                if (now >= due && rend_->waitable) waitVsync = true;
                else next = std::min(next, due);
            } else if (act == ActLow) {
                next = std::min(next, lastFrame_ + 0.2);
            } else {
                next = std::min(next, scene_->needsRedraw ? now : lastUpdate_ + 0.25);
            }
        }
        DWORD timeout = next <= now ? 0 : (DWORD)std::ceil((next - now) * 1000);
        if (waitVsync) timeout = std::min<DWORD>(timeout, 50);
        HANDLE hs[1] = {waitVsync ? rend_->waitable : nullptr};
        DWORD r = MsgWaitForMultipleObjectsEx(waitVsync ? 1 : 0, hs, timeout, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        bool vsync = waitVsync && r == WAIT_OBJECT_0;
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) { quitting_ = true; break; }
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if (quitting_) break;
        Tick(vsync);
    }

    Logf(L"shutting down");
    ExitLightEdit(true);
    CloseSettingsUi();
    TearDown();
    PanelsShutdown();
    for (HWINEVENTHOOK h : hooks_) if (h) UnhookWinEvent(h);
    for (auto& kv : liveHooks_) UnhookWinEvent(kv.second);
    for (int id = HK_QUIT; id <= HK_SETTINGS; id++) UnregisterHotKey(ctl_, id);
    Shell_NotifyIconW(NIM_DELETE, &nid_);
    WTSUnRegisterSessionNotification(ctl_);
    DestroyWindow(ctl_);
    if (iconOn_) DestroyIcon(iconOn_);
    if (iconOff_) DestroyIcon(iconOff_);
    if (iconBig_) DestroyIcon(iconBig_);
    DiagFlush();
    dog_.Stop();
    ClearSentinel();
    Logf(L"clean exit");
    return 0;
}

UINT App::SyncFor(Activity a) const
{
    int hz = std::max(30, disp_.refreshHz);
    int fps = a == ActHigh ? 60 : 30;
    if (a < ActNormal) return 1;
    // present every Nth vblank so the rate never exceeds the target (144 Hz -> 36 / 48 fps)
    return (UINT)std::max(1, std::min(4, (int)std::ceil((double)hz / fps - 0.05)));
}

void App::Tick(bool vsync)
{
    dog_.Beat();
    double now = NowSec();
    if (testDeadline_ > 0 && now >= testDeadline_) {
        Logf(L"--test-seconds elapsed; quitting");
        testDeadline_ = 0;
        Quit();
        return;
    }
    if (now - lastSlow_ >= 0.5 || fsCheckRequested_) SlowTick(now);
    if (needShow_) {                                      // renderer was recreated: show it (outside RenderFrame)
        needShow_ = false;
        UpdateRunning();
    }
    if (!scene_ || !visible_ || !rend_) return;

    statWakeups_++;
    if (now - lastCursor_ >= 0.014) {
        CursorPoll();
        lastCursor_ = now;
        statCursor_ += NowSec() - now;
    }
    double pollInt = scene_->WindowsBusy() ? 0.1 : 0.25;
    if ((pollRequested_ && now - lastPoll_ >= 0.03) || now - lastPoll_ >= pollInt) {
        double tp = NowSec();
        scene_->PollWindows(std::min(0.5, now - lastPoll_));
        if (!pendingRiders_.empty()) pendingRiders_ = scene_->RestoreRiders(pendingRiders_);
        if (!pendingLinks_.empty() && scene_->TrackedWindowCount() > 0) {
            size_t before = pendingLinks_.size();
            pendingLinks_ = scene_->RestoreLinks(pendingLinks_);
            if (pendingLinks_.size() != before) Logf(L"TEST restored %d light link(s)", (int)(before - pendingLinks_.size()));
        }
        UpdateLiveHooks();
        lastPoll_ = now;
        pollRequested_ = false;
        statPoll_ += NowSec() - tp;
        statPolls_++;
    }

    Activity act = scene_->GetActivity();
    bool render = false;
    if (act >= ActNormal) {
        double interval = act == ActHigh ? 1 / 60.0 : 1 / 30.0;
        render = vsync || (!rend_->waitable && now - lastFrame_ >= interval - 0.004) || now - lastFrame_ >= 0.25;
    } else if (act == ActLow) {
        render = now - lastFrame_ >= 0.2;
    } else if (scene_->needsRedraw || scene_->RedrawDue()) {
        render = true;
    } else if (now - lastUpdate_ >= 0.25) {
        // idle: keep timers (Santa schedule, accumulation, rest timers) running without drawing
        scene_->Update(std::min(0.5, now - lastUpdate_));
        lastUpdate_ = now;
        if (scene_->needsRedraw || scene_->RedrawDue()) render = true;
    }
    if (render) RenderFrame(now, act);
}

void App::RenderFrame(double now, Activity act)
{
    double t0 = NowSec();
    double dt = std::min(0.1, std::max(0.0, now - lastUpdate_));
    if (dt > 0) scene_->Update(dt);
    lastUpdate_ = now;
    double t1 = NowSec();
    statUpdate_ += t1 - t0;
    if (rend_->waitable && act < ActNormal) WaitForSingleObject(rend_->waitable, 20);
    double t2 = NowSec();
    scene_->PrepareCaches(*rend_);
    rend_->BeginFrame();
    scene_->Render(*rend_);
    statDraw_ += NowSec() - t2;
    bool ok = rend_->EndFrame(SyncFor(scene_->GetActivity()));
    lastFrame_ = now;
    statFrames_++;
    statWork_ += NowSec() - t0;
    if (!ok) {
        Logf(L"device lost: recreating the renderer");
        scene_->ReleaseDevice();
        DestroyOverlayWindow();
        if (!CreateOverlayWindowAndRenderer()) {
            Logf(L"renderer recreation failed; retrying with backoff");
            renderFailAt_ = now;
            DestroyOverlayWindow();
            visible_ = false;
        } else {
            needShow_ = true;                                 // shown from the next Tick
        }
    }
}

void App::SlowTick(double now)
{
    double dt = now - lastSlow_;
    lastSlow_ = now;
    fsCheckRequested_ = false;
    dog_.Beat();
    if (!sentinelCleared_ && now - startTime_ >= 10) { sentinelCleared_ = true; ClearSentinel(); Logf(L"sentinel cleared (10 s healthy)"); }

    bool fs = settings_.effectsOn && haveDisp_ && !locked_ && FullscreenOnDisplay();
    if (fs != fullscreen_) {
        fullscreen_ = fs;
        Logf(L"fullscreen app on the internal display: %d", fs ? 1 : 0);
        UpdateRunning();
    }
    SYSTEM_POWER_STATUS ps{};
    bool saving = GetSystemPowerStatus(&ps) && (ps.ACLineStatus == 0 || ps.SystemStatusFlag == 1);
    if (saving != powerSaving_) { powerSaving_ = saving; Logf(L"power saving: %d", saving ? 1 : 0); Diag("power", nullptr, nullptr, saving ? L"saving=1" : L"saving=0"); }
    if (scene_) scene_->powerSaving = powerSaving_ ? 1 : 0;
    if (!rend_ && scene_ && !fullscreen_ && !locked_ && !suspended_ && now - renderFailAt_ > retryDelay_) {
        dog_.Beat();
        if (CreateOverlayWindowAndRenderer()) { retryDelay_ = 5; needShow_ = true; }
        else {
            renderFailAt_ = now;
            retryDelay_ = std::min(300.0, retryDelay_ * 2);  // 5, 10, 20 ... 300 s
            Logf(L"renderer creation failed again; next try in %.0f s", retryDelay_);
        }
        dog_.Beat();
    }
    if (scene_ && visible_) {
        std::wstring how;
        int groundY = GroundLine(disp_, how);
        scene_->SetGroundLine(groundY - disp_.bounds.top);
        if (settings_.EffMode() == ModeDesktop) KeepAboveDesktop(false);
        else if (now - lastTopmost_ >= 2) {
            lastTopmost_ = now;
            SetWindowPos(overlay_, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
        }
    }
    if (lightEdit_) {
        bool allowed = settings_.effectsOn && settings_.WindowFeatures() && settings_.windowLights && scene_ && visible_;
        if (!allowed) ExitLightEdit(true);
        else if (scene_->EditIdleSeconds() > 30) { Logf(L"TEST light edit idle timeout"); ExitLightEdit(false); }
    }
    ValidateCustomize();
    stateSaveTimer_ += dt;
    if (stateSaveTimer_ >= 5) { stateSaveTimer_ = 0; SaveState(); }
    DiagFlush();
    if (now - lastStats_ >= 10) {
        ULONGLONG cpu = ProcessCpu100ns();
        double span = now - lastStats_;
        double f = statFrames_ ? 1000.0 / statFrames_ : 0.0;
        Logf(L"stats: %d frames in %.1fs (%.1f fps), per frame: update %.3f ms, draw calls %.3f ms, EndDraw %.3f ms, Present %.3f ms;"
             L" %d wakeups, %d window polls (%.3f ms each), cursor poll %.3f ms total, %d win events; process CPU %.2f%% of one core",
             statFrames_, span, statFrames_ / span, statUpdate_ * f, statDraw_ * f, rend_ ? rend_->endDrawSec * f : 0.0,
             rend_ ? rend_->presentSec * f : 0.0, statWakeups_, statPolls_, statPolls_ ? statPoll_ / statPolls_ * 1000 : 0.0,
             statCursor_ * 1000, statEvents_, (cpu - statCpu0_) / 1e7 / span * 100);
        statFrames_ = statWakeups_ = statEvents_ = statPolls_ = 0;
        statWork_ = statUpdate_ = statDraw_ = statPoll_ = statCursor_ = 0;
        if (rend_) rend_->endDrawSec = rend_->presentSec = 0;
        statCpu0_ = cpu;
        lastStats_ = now;
    }
}

// =============================================================================================
// Overlay lifecycle
// =============================================================================================

bool App::CreateOverlayWindowAndRenderer()
{
    const RECT& b = disp_.bounds;
    int w = b.right - b.left, h = b.bottom - b.top;
    DWORD ex = WS_EX_NOREDIRECTIONBITMAP | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT | WS_EX_LAYERED;
    if (settings_.EffMode() == ModeOnTop) ex |= WS_EX_TOPMOST;
    overlay_ = CreateWindowExW(ex, L"WinterDeskOverlay", L"WinterDesk", WS_POPUP, b.left, b.top, w, h, nullptr, nullptr, inst_, nullptr);
    if (!overlay_) { Logf(L"overlay window creation failed (%lu)", GetLastError()); return false; }
    // layered + transparent = click-through; alpha 255 keeps the composition content as drawn
    SetLayeredWindowAttributes(overlay_, 0, 255, LWA_ALPHA);
    clickThrough_ = true;
    rend_.reset(new Renderer());
    rend_->flakePct = settings_.flakeSize;   // the atlas is built once, at the user's flake size
    dog_.Beat();
    bool inited = rend_->Init(overlay_, w, h, std::max(0.5f, disp_.scale));   // includes the art rendering
    dog_.Beat();
    if (!inited) {
        rend_.reset();
        return false;
    }
    Logf(L"renderer: %s D3D11 device, adapter \"%s\", swap chain %dx%d premultiplied flip-sequential, frame-latency waitable %s",
         rend_->warp ? L"WARP (software)" : L"hardware", rend_->adapter.c_str(), w, h, rend_->waitable ? L"yes" : L"no");
    dog_.overlay = overlay_;
    return true;
}

void App::DestroyOverlayWindow()
{
    rend_.reset();
    if (overlay_) {
        dog_.overlay = nullptr;
        DestroyWindow(overlay_);
        overlay_ = nullptr;
    }
    visible_ = false;
}

bool App::BuildOverlay()
{
    std::wstring how;
    int groundY = GroundLine(disp_, how);
    Logf(L"ground line y=%d (%s)", groundY, how.c_str());
    scene_.reset(new Scene(disp_, groundY - disp_.bounds.top, settings_, haveSaved_ ? &savedGifts_ : nullptr,
                           !defaultGiftRemovedThisSession_, pendingRiders_.empty()));
    Scene* sc = scene_.get();
    sc->onToast = [this](const std::wstring& t) { Toast(t); };
    sc->onDefaultGiftGone = [this] { defaultGiftRemovedThisSession_ = true; };
    sc->onRiderParked = [this](const SavedRider& r) { pendingRiders_.push_back(r); };
    sc->onLinksChanged = [this] { LinksChanged(); };
    sc->onOpenCustomizer = [this, sc](Ball* root, RECT local) {
        RECT anchor = {local.left + disp_.bounds.left, local.top + disp_.bounds.top, local.right + disp_.bounds.left, local.bottom + disp_.bounds.top};
        CustomizeTarget t;
        t.valid = [this, sc, root] { return scene_.get() == sc && sc->IsSnowmanRoot(root); };
        t.get = [this, sc, root] { return scene_.get() == sc && sc->IsSnowmanRoot(root) ? root->outfit : Outfit(); };
        t.set = [this, sc, root](const Outfit& o) {
            if (scene_.get() == sc && sc->IsSnowmanRoot(root)) { sc->SetOutfit(root, o); SaveState(); }
        };
        ShowCustomize(Host(), anchor, t);
    };
    if (!CreateOverlayWindowAndRenderer()) {
        renderFailAt_ = NowSec();
        DestroyOverlayWindow();
        return false;
    }
    return true;
}

/// Persists gifts, window snowmen (with their outfits) and light links.
void App::SaveState()
{
    if (!scene_) return;
    savedGifts_ = scene_->SnapshotGifts();
    haveSaved_ = true;
    if (scene_->defaultGiftRemoved) defaultGiftRemovedThisSession_ = true;
    scene_->giftsDirty = false;
    SaveGifts(savedGifts_);
    std::vector<SavedRider> riders = scene_->SnapshotRiders();
    riders.insert(riders.end(), pendingRiders_.begin(), pendingRiders_.end());
    SaveRiders(riders);
    std::vector<SavedLink> links = scene_->SnapshotLinks();
    for (const SavedLink& p : pendingLinks_) if (std::find(links.begin(), links.end(), p) == links.end()) links.push_back(p);
    if ((int)links.size() > Scene::kMaxLinks) links.resize(Scene::kMaxLinks);
    SaveLinks(links);
}

/// Saves state and releases the overlay, renderer and scene.
void App::TearDown()
{
    HideCustomize();
    if (scene_) {
        SaveState();
        // window snowmen of this scene go back to the pending list (restored on the next build)
        std::vector<SavedRider> r = scene_->SnapshotRiders();
        pendingRiders_.insert(pendingRiders_.end(), r.begin(), r.end());
        std::vector<SavedLink> l = scene_->SnapshotLinks();
        for (const SavedLink& p : l) if (std::find(pendingLinks_.begin(), pendingLinks_.end(), p) == pendingLinks_.end()) pendingLinks_.push_back(p);
        scene_.reset();
    }
    DestroyOverlayWindow();
    for (auto& kv : liveHooks_) UnhookWinEvent(kv.second);
    liveHooks_.clear();
}

void App::Rebuild(const wchar_t* why)
{
    ExitLightEdit(true);
    TearDown();
    dog_.Beat();
    disp_ = FindInternalDisplay();
    haveDisp_ = disp_.isInternal;
    if (!haveDisp_) Logf(L"no internal display (%s): paused until it comes back", disp_.how.c_str());
    Logf(L"target display (%s): %s \"%s\" bounds=%s work=%s scale=%.2f refresh=%dHz internal=%d via %s", why, disp_.name.c_str(),
         disp_.friendly.c_str(), RectStr(disp_.bounds).c_str(), RectStr(disp_.work).c_str(), disp_.scale, disp_.refreshHz,
         disp_.isInternal ? 1 : 0, disp_.how.c_str());
    fullscreen_ = settings_.effectsOn && haveDisp_ && !locked_ && FullscreenOnDisplay();
    UpdateRunning();
    dog_.Beat();
}

void App::UpdateRunning()
{
    bool want = settings_.effectsOn && haveDisp_ && !locked_ && !suspended_ && !fullscreen_;
    if (!settings_.effectsOn && scene_) { ExitLightEdit(true); TearDown(); }
    if (want && !scene_ && haveDisp_) BuildOverlay();
    if (want && scene_ && rend_ && !visible_) {
        double now = NowSec();
        scene_->PollWindows(0.0);
        lastPoll_ = lastCursor_ = now;
        lastUpdate_ = now;
        RenderFrame(now, ActNormal);
        if (rend_) {
            ShowWindow(overlay_, SW_SHOWNOACTIVATE);
            if (settings_.EffMode() == ModeOnTop)
                SetWindowPos(overlay_, HWND_TOPMOST, disp_.bounds.left, disp_.bounds.top, disp_.bounds.right - disp_.bounds.left,
                             disp_.bounds.bottom - disp_.bounds.top, SWP_NOACTIVATE | SWP_NOOWNERZORDER);
            else
                KeepAboveDesktop(true);
            visible_ = true;
            Logf(L"overlay shown (mode %s)", settings_.EffMode() == ModeOnTop ? L"On Top" : L"Desktop");
        }
    } else if (!want && visible_ && overlay_) {
        if (scene_) scene_->CancelCapture();               // a press in progress must never outlive the overlay
        if (GetCapture() == overlay_) ReleaseCapture();
        SetClickThrough(true);
        ShowWindow(overlay_, SW_HIDE);
        visible_ = false;
        HideCustomize();
        ExitLightEdit(true);
        if (scene_) SaveState();
        Logf(L"overlay hidden (effects=%d locked=%d suspended=%d fullscreen=%d)", settings_.effectsOn ? 1 : 0, locked_ ? 1 : 0,
             suspended_ ? 1 : 0, fullscreen_ ? 1 : 0);
    }
    UpdateTrayIcon();
}

/// Desktop mode: the overlay is an ordinary (non-topmost) top-level window kept directly above the
/// window that hosts the desktop icons (Progman on Windows 11 24H2, or the icon WorkerW), so it is
/// drawn over the icons and wallpaper but under every app window.
void App::KeepAboveDesktop(bool log)
{
    if (!overlay_) return;
    std::wstring layout;
    HWND host = DesktopIconHost(&layout);
    if (layout != desktopLayout_) { desktopLayout_ = layout; Logf(L"desktop host: %s", layout.c_str()); }
    if (!host) return;
    HWND prev = GetWindow(host, GW_HWNDPREV);
    while (prev && !IsWindowVisible(prev) && prev != overlay_) prev = GetWindow(prev, GW_HWNDPREV);
    if (prev != overlay_) {
        // insert right above the host: below the first visible window above it
        HWND above = GetWindow(host, GW_HWNDPREV);
        const UINT f = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_ASYNCWINDOWPOS;   // never wait on Explorer
        SetWindowPos(overlay_, HWND_NOTOPMOST, 0, 0, 0, 0, f);
        SetWindowPos(overlay_, above ? above : HWND_BOTTOM, 0, 0, 0, 0, f);
        if (!above) SetWindowPos(host, overlay_, 0, 0, 0, 0, f);
    }
    if (log) {
        int zOverlay = -1, zHost = -1, visibleBetween = 0, i = 0;
        for (HWND w = GetTopWindow(nullptr); w; w = GetWindow(w, GW_HWNDNEXT), i++) {
            if (w == overlay_) zOverlay = i;
            else if (w == host) { zHost = i; break; }
            else if (zOverlay >= 0 && IsWindowVisible(w)) visibleBetween++;
        }
        Logf(L"desktop mode z-order: overlay at %d, desktop host at %d, visible windows between: %d", zOverlay, zHost, visibleBetween);
    }
}

void App::ApplyMode()
{
    HideCustomize();
    ExitLightEdit(true);
    // the overlay's topmost style is fixed at creation: rebuild it in the new mode
    TearDown();
    UpdateRunning();
}

/// Fullscreen app / game / presentation covering the internal display.
bool App::FullscreenOnDisplay()
{
    HWND fg = GetForegroundWindow();
    QUERY_USER_NOTIFICATION_STATE state = QUNS_ACCEPTS_NOTIFICATIONS;
    SHQueryUserNotificationState(&state);
    bool fgOnTarget = fg && disp_.hmon && MonitorFromWindow(fg, MONITOR_DEFAULTTONULL) == disp_.hmon;
    if (state == QUNS_PRESENTATION_MODE) return true;
    if (state == QUNS_RUNNING_D3D_FULL_SCREEN && (!fg || fgOnTarget)) return true;
    // the front-most real window on the internal display (foreground or not) decides
    const RECT& m = disp_.bounds;
    DWORD own = GetCurrentProcessId();
    for (HWND w = GetTopWindow(nullptr); w; w = GetWindow(w, GW_HWNDNEXT)) {
        if (!IsWindowVisible(w) || IsIconic(w) || IsCloaked(w)) continue;
        DWORD pid = 0;
        GetWindowThreadProcessId(w, &pid);
        if (pid == own) continue;
        LONG ex = GetWindowLongW(w, GWL_EXSTYLE);
        if ((ex & WS_EX_TOOLWINDOW) && !(ex & WS_EX_APPWINDOW)) continue;
        if ((ex & WS_EX_TRANSPARENT) && (ex & WS_EX_LAYERED)) continue;
        wchar_t cls[64];
        ClassOf(w, cls, 64);
        if (!wcscmp(cls, L"Progman") || !wcscmp(cls, L"WorkerW") || !wcscmp(cls, L"Shell_TrayWnd") || !wcscmp(cls, L"Shell_SecondaryTrayWnd"))
            continue;
        RECT r, in;
        if (!GetWindowRect(w, &r) || !IntersectRect(&in, &r, &m)) continue;
        LONG style = GetWindowLongW(w, GWL_STYLE);
        if ((style & WS_CAPTION) == WS_CAPTION && IsZoomed(w)) return false;   // maximized, not fullscreen
        return r.left <= m.left && r.top <= m.top && r.right >= m.right && r.bottom >= m.bottom;
    }
    return false;
}

/// Live window tracking (the SkyLight equivalent): EVENT_OBJECT_LOCATIONCHANGE, hooked only for the
/// processes that own a tracked window so cursor / caret traffic of other processes never wakes us.
void App::UpdateLiveHooks()
{
    std::vector<DWORD> want;
    if (scene_ && settings_.liveTracking && settings_.WindowFeatures() && (settings_.windowSnow || settings_.windowLights))
        want = scene_->Windows().Pids();
    for (auto it = liveHooks_.begin(); it != liveHooks_.end();) {
        if (std::find(want.begin(), want.end(), it->first) == want.end()) { UnhookWinEvent(it->second); it = liveHooks_.erase(it); }
        else ++it;
    }
    for (DWORD pid : want) {
        if (liveHooks_.count(pid)) continue;
        HWINEVENTHOOK h = SetWinEventHook(EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE, nullptr, WinEventThunk, pid, 0,
                                          WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
        if (h) liveHooks_[pid] = h;
    }
}

// =============================================================================================
// Input
// =============================================================================================

void App::CursorPoll()
{
    POINT pt;
    if (!GetCursorPos(&pt)) return;
    CoachCursor(pt);
    const RECT& b = disp_.bounds;
    bool inside = PtInRect(&b, pt) != FALSE;
    // the primary button as the user has it (swapped buttons respected), read without consuming it
    bool primaryDown = (GetAsyncKeyState(GetSystemMetrics(SM_SWAPBUTTON) ? VK_RBUTTON : VK_LBUTTON) & 0x8000) != 0;
    double now = NowSec();
    if (primaryDown) primaryUpSince_ = -1;
    else if (primaryUpSince_ < 0) primaryUpSince_ = now;
    // a hold / pending press only counts while the button is physically down; if the release never
    // reached us (capture lost: UAC, Alt+Tab, overlay hidden) cancel it after 150 ms and go click-through
    if (scene_->IsHolding() && !primaryDown && primaryUpSince_ >= 0 && now - primaryUpSince_ > 0.15) {
        scene_->CancelCapture();
        if (GetCapture() == overlay_) ReleaseCapture();
        Logf(L"TEST stale press cancelled (button is up)");
    }
    // the customize panel (when the cursor is over it) owns the mouse; a press elsewhere closes it
    HWND cust = CustomizeHwnd();
    RECT cr;
    bool overPanel = cust && GetWindowRect(cust, &cr) && PtInRect(&cr, pt);
    if (overPanel) inside = false;
    // the settings window is never covered by an overlay capture (On Top mode draws above it), but
    // only where it really is the top visible window under the cursor
    HWND sw = SettingsUiHwnd();
    RECT sr;
    if (inside && sw && IsWindowVisible(sw) && !IsIconic(sw) && GetWindowRect(sw, &sr) && PtInRect(&sr, pt) && SettingsOnTopAt(sw, pt))
        inside = false;
    if (primaryDown && !lastPrimaryDown_ && cust && !overPanel) { Logf(L"TEST customize panel closed by a click outside"); HideCustomize(); }
    lastPrimaryDown_ = primaryDown;
    // Light Edit: Esc is read, not grabbed (other apps still receive it)
    if (lightEdit_ && (GetAsyncKeyState(VK_ESCAPE) & 0x8000)) { ExitLightEdit(false); return; }
    bool interactive = scene_->UpdateCursor((float)(pt.x - b.left), (float)(pt.y - b.top), inside, settings_.EffMode() == ModeDesktop);
    SetClickThrough(!interactive);
}

/// True when `sw` (cursor already inside its rect) is not cloaked and no other visible, uncloaked,
/// click-receiving top-level window of another process lies above it at `pt`. Walks only the
/// windows above it in z-order, and runs only while the cursor is over the settings window.
bool App::SettingsOnTopAt(HWND sw, POINT pt) const
{
    if (IsCloaked(sw)) return false;                         // on another virtual desktop
    DWORD self = GetCurrentProcessId();
    int guard = 0;
    for (HWND w = GetWindow(sw, GW_HWNDPREV); w && guard < 512; w = GetWindow(w, GW_HWNDPREV), guard++) {
        if (!IsWindowVisible(w) || IsIconic(w)) continue;
        DWORD pid = 0;
        GetWindowThreadProcessId(w, &pid);
        if (pid == self) continue;                           // overlay, toast, hint, coach, customize
        LONG_PTR ex = GetWindowLongPtrW(w, GWL_EXSTYLE);
        if ((ex & WS_EX_TRANSPARENT) && (ex & WS_EX_LAYERED)) continue;   // click-through overlays of other apps
        RECT r;
        if (!GetWindowRect(w, &r) || !PtInRect(&r, pt)) continue;
        if (IsCloaked(w)) continue;
        return false;
    }
    return true;
}

void App::SetClickThrough(bool through)
{
    if (through == clickThrough_ || !overlay_) return;
    clickThrough_ = through;
    LONG_PTR ex = GetWindowLongPtrW(overlay_, GWL_EXSTYLE);
    ex = through ? (ex | WS_EX_TRANSPARENT) : (ex & ~(LONG_PTR)WS_EX_TRANSPARENT);
    SetWindowLongPtrW(overlay_, GWL_EXSTYLE, ex);
    Diag(through ? "clickThrough" : "capture", nullptr, nullptr, L"");
}

LRESULT App::OverlayProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    switch (m) {
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
    case WM_DPICHANGED:
        SetTimer(ctl_, TIMER_REBUILD, 800, nullptr);   // keep our exact bounds; rebuild for the new scale
        return 0;
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT:
        ValidateRect(h, nullptr);
        return 0;
    case WM_SETCURSOR:
        if (LOWORD(l) == HTCLIENT && scene_) {
            SetCursor(LoadCursorW(nullptr, scene_->HoveringObject() || scene_->IsHolding() ? IDC_HAND : IDC_ARROW));
            return TRUE;
        }
        break;
    case WM_LBUTTONDOWN:
    case WM_LBUTTONDBLCLK:
        if (scene_) {
            SetCapture(h);
            Diag("overlayMouseDown", nullptr, nullptr, scene_->MouseTargetName((float)GET_X_LPARAM(l), (float)GET_Y_LPARAM(l)));
            scene_->MouseDown((float)GET_X_LPARAM(l), (float)GET_Y_LPARAM(l), false, m == WM_LBUTTONDBLCLK ? 2 : 1);
        }
        return 0;
    case WM_RBUTTONDOWN:
        if (scene_) {
            scene_->MouseDown((float)GET_X_LPARAM(l), (float)GET_Y_LPARAM(l), true, 1);
            if (scene_->ContextBall()) {
                // right-click on a snowball / snowman: a small "삭제" menu
                HMENU menu = CreatePopupMenu();
                AppendMenuW(menu, MF_STRING, ID_BALL_DELETE, L"삭제");
                POINT pt;
                GetCursorPos(&pt);
                UINT cmd = RunPopupMenu(menu, pt, TPM_RIGHTBUTTON);
                DestroyMenu(menu);
                if (cmd == ID_BALL_DELETE && scene_) scene_->DeleteBallFromMenu();
            }
        }
        return 0;
    case WM_MOUSEMOVE:
        if (scene_) scene_->MouseMove((float)GET_X_LPARAM(l), (float)GET_Y_LPARAM(l));
        return 0;
    case WM_LBUTTONUP:
        if (scene_) scene_->MouseUp((float)GET_X_LPARAM(l), (float)GET_Y_LPARAM(l));
        if (GetCapture() == h) ReleaseCapture();
        return 0;
    case WM_CAPTURECHANGED:
        // capture taken away (not our own release): drop whatever was held, never treat it as a click
        if (scene_ && scene_->IsHolding()) { scene_->CancelCapture(); Logf(L"TEST capture lost: press cancelled"); }
        SetClickThrough(true);
        return 0;
    default:
        break;
    }
    return DefWindowProcW(h, m, w, l);
}

void App::OnWinEvent(DWORD ev, HWND h, LONG obj, LONG child)
{
    statEvents_++;
    if (ev == EVENT_SYSTEM_FOREGROUND) { fsCheckRequested_ = true; pollRequested_ = true; return; }
    if (obj != OBJID_WINDOW || child != CHILDID_SELF || !h || !scene_) return;
    switch (ev) {
    case EVENT_OBJECT_LOCATIONCHANGE: {
        if (!scene_->Windows().Find(h)) return;
        RECT r;
        if (FrameBounds(h, &r)) scene_->OnWindowLive(h, r);
        return;
    }
    case EVENT_SYSTEM_MOVESIZESTART: scene_->OnMoveSizeStart(h); pollRequested_ = true; return;
    case EVENT_SYSTEM_MOVESIZEEND: scene_->OnMoveSizeEnd(h); pollRequested_ = true; return;
    case EVENT_SYSTEM_MINIMIZESTART: scene_->OnWindowVanished(h, L"minimize"); pollRequested_ = true; return;
    case EVENT_OBJECT_HIDE: scene_->OnWindowVanished(h, L"hide"); pollRequested_ = true; return;
    case EVENT_OBJECT_DESTROY: scene_->OnWindowVanished(h, L"close"); pollRequested_ = true; return;
    case EVENT_OBJECT_CLOAKED: scene_->OnWindowVanished(h, L"cloaked"); pollRequested_ = true; return;
    default:
        if (GetAncestor(h, GA_ROOT) == h) pollRequested_ = true;
        return;
    }
}

// =============================================================================================
// Control window: tray, menu, hotkeys, system notifications
// =============================================================================================

void App::AddTray()
{
    nid_ = NOTIFYICONDATAW{};
    nid_.cbSize = sizeof(nid_);
    nid_.hWnd = ctl_;
    nid_.uID = 1;
    nid_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    nid_.uCallbackMessage = WM_TRAY;
    nid_.hIcon = settings_.effectsOn ? iconOn_ : iconOff_;
    wcscpy_s(nid_.szTip, settings_.effectsOn ? L"WinterDesk" : L"WinterDesk (effects off - Ctrl+Alt+Shift+E)");
    if (!Shell_NotifyIconW(NIM_ADD, &nid_)) Logf(L"tray icon add failed");
    nid_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &nid_);
}

void App::UpdateTrayIcon()
{
    HICON want = settings_.effectsOn ? iconOn_ : iconOff_;
    if (nid_.hIcon == want) return;
    nid_.hIcon = want;
    nid_.uFlags = NIF_ICON | NIF_TIP;
    wcscpy_s(nid_.szTip, settings_.effectsOn ? L"WinterDesk" : L"WinterDesk (effects off - Ctrl+Alt+Shift+E)");
    Shell_NotifyIconW(NIM_MODIFY, &nid_);
}

std::wstring App::OffStateText() const
{
    std::wstring parts;
    auto add = [&](const wchar_t* p) { if (!parts.empty()) parts += L" · "; parts += p; };
    if (!settings_.effectsOn) add(L"효과 Ctrl+Alt+Shift+E");
    if (!settings_.snowFalling) add(L"눈 내리기 Ctrl+Alt+Shift+S");
    if (!settings_.santa) add(L"산타 Ctrl+Alt+Shift+D");
    return parts.empty() ? parts : L"꺼져 있음: " + parts;
}

void App::ShowMenu(const POINT* at)
{
    CancelTrayClick();
    HMENU m = CreatePopupMenu(), inten = CreatePopupMenu(), mode = CreatePopupMenu(), drag = CreatePopupMenu(), links = CreatePopupMenu(),
          style = CreatePopupMenu();
    auto chk = [](bool b) { return (UINT)(MF_STRING | (b ? MF_CHECKED : MF_UNCHECKED)); };
    std::wstring off = OffStateText();
    if (!haveDisp_) AppendMenuW(m, MF_STRING | MF_GRAYED, 0, L"\uB0B4\uC7A5 \uB514\uC2A4\uD50C\uB808\uC774 \uC5C6\uC74C \u2013 \uC77C\uC2DC \uC815\uC9C0");
    AppendMenuW(m, MF_STRING, ID_SETTINGS, L"⚙ 설정…");
    SetMenuDefaultItem(m, ID_SETTINGS, FALSE);
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    if (!off.empty()) AppendMenuW(m, MF_STRING | MF_GRAYED, 0, (L"⚠️ " + off).c_str());
    AppendMenuW(m, chk(settings_.effectsOn), ID_EFFECTS, L"Effects On\tCtrl+Alt+Shift+E");
    AppendMenuW(m, chk(lightEdit_) | (settings_.effectsOn ? 0 : MF_GRAYED), ID_EDITLIGHTS, L"전구 연결하기…\tCtrl+Alt+Shift+L");
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    if (settings_.safeMode) {
        AppendMenuW(m, MF_STRING | MF_GRAYED, 0, (L"⚠️ " + settings_.safeReason).c_str());
        AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    }
    AppendMenuW(m, chk(settings_.snowFalling), ID_SNOW, L"Snow Falling\tCtrl+Alt+Shift+S");
    AppendMenuW(inten, MF_STRING | (settings_.intensity == 0 ? MF_CHECKED : 0), ID_INT_LIGHT, L"Light");
    AppendMenuW(inten, MF_STRING | (settings_.intensity == 1 ? MF_CHECKED : 0), ID_INT_NORMAL, L"Normal");
    AppendMenuW(inten, MF_STRING | (settings_.intensity == 2 ? MF_CHECKED : 0), ID_INT_HEAVY, L"Heavy");
    AppendMenuW(m, MF_POPUP, (UINT_PTR)inten, L"Snow Intensity");
    AppendMenuW(mode, chk(settings_.EffMode() == ModeDesktop), ID_MODE_DESKTOP, L"Desktop (behind windows)");
    AppendMenuW(mode, chk(settings_.EffMode() == ModeOnTop), ID_MODE_ONTOP, L"On Top (over everything)");
    AppendMenuW(m, MF_POPUP, (UINT_PTR)mode, L"Mode");
    AppendMenuW(m, chk(settings_.santa), ID_SANTA, L"Santa\tCtrl+Alt+Shift+D");
    AppendMenuW(m, chk(settings_.snowplow), ID_PLOW, L"제설차 (Snowplow)\tCtrl+Alt+Shift+P");
    AppendMenuW(m, chk(settings_.windowSnow), ID_WINSNOW, settings_.WindowFeatures() ? L"Snow on Windows" : L"Snow on Windows (On Top mode only)");
    AppendMenuW(m, chk(settings_.windowLights), ID_LIGHTS, settings_.WindowFeatures() ? L"Window Lights" : L"Window Lights (On Top mode only)");
    AppendMenuW(m, chk(settings_.liveTracking), ID_LIVE, L"실시간 창 추적 (실험적)");
    AppendMenuW(m, MF_STRING | MF_GRAYED, 0, settings_.liveTracking ? L"창 추적: 실시간" : L"창 추적: 기본");
    AppendMenuW(drag, chk(settings_.dragSnowSlides), ID_DRAG_SLIDES, L"미끄러져 떨어짐");
    AppendMenuW(drag, chk(!settings_.dragSnowSlides), ID_DRAG_STAYS, L"붙어 있음");
    AppendMenuW(m, MF_POPUP, (UINT_PTR)drag, L"창 끌 때 눈");
    if (powerSaving_) AppendMenuW(m, MF_STRING | MF_GRAYED, 0, L"절전: 켜짐");
    AppendMenuW(links, chk(settings_.lightLinksAuto), ID_LINKS_AUTO, L"Automatic");
    AppendMenuW(links, chk(!settings_.lightLinksAuto), ID_LINKS_MANUAL, L"Manual only");
    AppendMenuW(m, MF_POPUP, (UINT_PTR)links, L"Light Links");
    AppendMenuW(m, chk(settings_.windowGarlands), ID_GARLANDS, L"Window Garlands");
    AppendMenuW(style, chk(settings_.lightStyle == 0), ID_STYLE_MULTI, L"Multicolor");
    AppendMenuW(style, chk(settings_.lightStyle == 1), ID_STYLE_WARM, L"Warm White");
    AppendMenuW(style, chk(settings_.lightStyle == 2), ID_STYLE_CLASSIC, L"Classic");
    AppendMenuW(style, chk(settings_.lightStyle == 3), ID_STYLE_ICY, L"Icy");
    AppendMenuW(style, chk(settings_.lightStyle == 4), ID_STYLE_CANDY, L"Candy");
    AppendMenuW(m, MF_POPUP, (UINT_PTR)style, L"Light Style");
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, MF_STRING | (scene_ && scene_->CanAddGift() ? 0 : MF_GRAYED), ID_ADDGIFT, L"Add Gift");
    AppendMenuW(m, MF_STRING, ID_CLEARBALLS, L"Clear Snowballs && Snowmen");
    AppendMenuW(m, MF_STRING, ID_CLEARALL, L"Clear Snowmen, Snowballs && Gifts");
    AppendMenuW(m, MF_STRING | (scene_ ? 0 : MF_GRAYED), ID_RESET, L"Reset Snow");
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, chk(GetLaunchAtLogin()), ID_LOGIN, L"Launch at Login");
    AppendMenuW(m, MF_STRING, ID_GLITCH, L"Report a Glitch\tCtrl+Alt+Shift+G");
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, MF_STRING, ID_QUIT, L"Quit WinterDesk");
    AppendMenuW(m, MF_STRING | MF_GRAYED, 0, L"Emergency quit from anywhere: Ctrl+Alt+Shift+Q");

    POINT pt;
    if (at) pt = *at;
    else GetCursorPos(&pt);
    UINT cmd = RunPopupMenu(m, pt, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN);
    DestroyMenu(m);
    if (cmd) Command(cmd);
}

/// Shows a popup menu (our window must be foreground for it to close properly) and gives the
/// foreground back to the window that had it.
UINT App::RunPopupMenu(HMENU m, POINT pt, UINT flags)
{
    HWND prev = GetForegroundWindow();
    // a tray click gives us the right to take the foreground (the shell allows it for the icon's
    // owner); without it the menu still shows but may not close on an outside click - logged
    if (!SetForegroundWindow(ctl_)) Logf(L"popup menu: SetForegroundWindow refused (menu may not close on an outside click)");
    inMenu_ = true;
    SetTimer(ctl_, TIMER_MENU, 33, nullptr);   // keep animating / beating while the menu loop runs
    UINT cmd = (UINT)TrackPopupMenuEx(m, TPM_RETURNCMD | TPM_NONOTIFY | flags, pt.x, pt.y, ctl_, nullptr);
    KillTimer(ctl_, TIMER_MENU);
    inMenu_ = false;
    PostMessageW(ctl_, WM_NULL, 0, 0);
    if (GetForegroundWindow() == ctl_ && prev && prev != ctl_ && IsWindow(prev)) SetForegroundWindow(prev);
    return cmd;
}

void App::Toast(const std::wstring& t, bool force)
{
    if (!haveDisp_ || locked_ || suspended_) return;
    if (!force && !visible_) return;
    ShowToast(Host(), t);
}

void App::Changed()
{
    settings_.Save();
    if (scene_) scene_->SettingsChanged();
    pollRequested_ = true;
    SettingsUiRefresh();
}

void App::ToggleEffects()
{
    settings_.effectsOn = !settings_.effectsOn;
    settings_.Save();
    Logf(L"effects %s", settings_.effectsOn ? L"on" : L"off");
    UpdateRunning();
    Toast(settings_.effectsOn ? L"✨ 효과 켜짐" : L"✨ 효과 꺼짐", true);
    SettingsUiRefresh();
}

void App::ToggleLightEdit()
{
    if (lightEdit_) { ExitLightEdit(false); return; }
    EnterLightEdit();
}

/// Starts Light Edit (turning on what it needs); true when it is on afterwards.
bool App::EnterLightEdit()
{
    if (lightEdit_) return true;
    if (locked_ || suspended_) return false;
    if (!settings_.effectsOn) { Toast(L"효과가 꺼져 있어요 (Ctrl+Alt+Shift+E)", true); return false; }
    if (settings_.safeMode) { Toast(L"안전 모드에서는 전구 연결을 할 수 없어요"); return false; }
    if (!settings_.WindowFeatures() || !settings_.windowLights) {
        // turn on what linking needs instead of silently doing nothing
        bool rebuild = settings_.EffMode() != ModeOnTop;
        settings_.mode = ModeOnTop;
        settings_.windowLights = true;
        settings_.Save();
        if (rebuild) ApplyMode(); else Changed();
        Toast(L"전구 연결을 위해 On Top 모드와 Window Lights를 켰어요");
    }
    if (!scene_ || !visible_) return false;
    lightEdit_ = true;
    scene_->SetLightEdit(true);
    Logf(L"TEST light edit on (Esc is polled, not grabbed)");
    if (scene_->EligibleAnchorWindows() < 2) Toast(L"연결하려면 창이 2개 이상 보여야 해요");
    ShowCoach(Host(), [this] {
        if (lightEdit_)
            ShowHint(Host(), L"금색 점 → 다른 창의 금색 점으로 드래그 · 전구 클릭 = 삭제 · Esc = 끝내기");
    });
    return true;
}

void App::ExitLightEdit(bool silent)
{
    if (!lightEdit_) return;
    lightEdit_ = false;
    if (scene_) { scene_->SetLightEdit(false); scene_->CancelCapture(); }
    SetClickThrough(true);
    HideCoach();
    HideHint();
    Logf(L"TEST light edit off");
    if (!silent) Toast(L"\U0001F4A1 전구 연결 끝");
}

void App::LinksChanged()
{
    // one-time: the first user link switches the automatic window-pair strands off
    if (scene_ && scene_->UserLinkCount() > 0 && !settings_.manualAfterFirstLinkDone) {
        settings_.manualAfterFirstLinkDone = true;
        settings_.lightLinksAuto = false;
        Changed();
    }
    SaveState();
}

void App::ReportGlitch()
{
    wchar_t state[256];
    swprintf_s(state, L"windows=%d mode=%s live=%d visible=%d power=%d", scene_ ? scene_->TrackedWindowCount() : 0,
               settings_.EffMode() == ModeOnTop ? L"onTop" : L"desktop", settings_.liveTracking ? 1 : 0, visible_ ? 1 : 0, powerSaving_ ? 1 : 0);
    std::wstring path = DumpGlitchRing(state);
    Logf(L"glitch report: %s", path.c_str());
    if (path.empty()) { Toast(L"기록을 저장하지 못했어요", true); return; }
    size_t slash = path.find_last_of(L'\\');
    Toast(L"\U0001F9FE 기록 저장: " + path.substr(slash + 1), true);
}

void App::Command(UINT id)
{
    CancelTrayClick();                       // a pending single-click menu is stale once anything ran
    switch (id) {
    case ID_EFFECTS: ToggleEffects(); break;
    case ID_EDITLIGHTS: ToggleLightEdit(); break;
    case ID_SNOW:
        settings_.snowFalling = !settings_.snowFalling;
        Changed();
        Toast(settings_.snowFalling ? L"❄️ 눈 내리기 켜짐" : L"눈 내리기 꺼짐");
        break;
    case ID_INT_LIGHT: case ID_INT_NORMAL: case ID_INT_HEAVY: settings_.intensity = (int)(id - ID_INT_LIGHT); Changed(); break;
    case ID_MODE_DESKTOP: case ID_MODE_ONTOP:
        settings_.mode = id == ID_MODE_ONTOP ? ModeOnTop : ModeDesktop;
        if (settings_.safeMode) { settings_.safeMode = false; settings_.safeReason.clear(); Logf(L"safe mode ended (mode chosen)"); }
        settings_.Save();
        Logf(L"TEST mode -> %s", settings_.mode == ModeOnTop ? L"On Top" : L"Desktop");
        ApplyMode();
        break;
    case ID_SANTA:
        settings_.santa = !settings_.santa;
        Changed();
        Toast(settings_.santa ? L"\U0001F385 산타 켜짐" : L"\U0001F385 산타 꺼짐");
        break;
    case ID_PLOW:
        settings_.snowplow = !settings_.snowplow;
        Changed();
        Toast(settings_.snowplow ? L"\U0001F69C 제설차 켜짐" : L"\U0001F69C 제설차 꺼짐");
        break;
    case ID_WINSNOW: settings_.windowSnow = !settings_.windowSnow; Changed(); break;
    case ID_LIGHTS: settings_.windowLights = !settings_.windowLights; if (!settings_.windowLights) ExitLightEdit(true); Changed(); break;
    case ID_LIVE: settings_.liveTracking = !settings_.liveTracking; Changed(); UpdateLiveHooks(); break;
    case ID_DRAG_SLIDES: case ID_DRAG_STAYS: settings_.dragSnowSlides = id == ID_DRAG_SLIDES; Changed(); break;
    case ID_LINKS_AUTO: case ID_LINKS_MANUAL:
        settings_.lightLinksAuto = id == ID_LINKS_AUTO;
        settings_.manualAfterFirstLinkDone = true;           // an explicit choice wins
        Changed();
        break;
    case ID_GARLANDS: settings_.windowGarlands = !settings_.windowGarlands; Changed(); break;
    case ID_STYLE_MULTI: case ID_STYLE_WARM: case ID_STYLE_CLASSIC: case ID_STYLE_ICY: case ID_STYLE_CANDY:
        settings_.lightStyle = (int)(id - ID_STYLE_MULTI);
        Changed();
        break;
    case ID_ADDGIFT: if (scene_) scene_->AddGift(); break;
    case ID_CLEARBALLS:
        if (scene_) scene_->ClearBalls();
        pendingRiders_.clear();
        HideCustomize();
        SaveState();
        Logf(L"TEST cleared snowballs and snowmen");
        break;
    case ID_CLEARALL:
        if (scene_) scene_->ClearSnowmenAndGifts();
        else { savedGifts_.clear(); haveSaved_ = true; defaultGiftRemovedThisSession_ = true; SaveGifts(savedGifts_); }
        pendingRiders_.clear();
        HideCustomize();
        SaveState();
        Logf(L"TEST cleared snowmen, snowballs and gifts");
        break;
    case ID_RESET: if (scene_) scene_->ResetSnow(); break;
    case ID_LOGIN: SetLaunchAtLogin(!GetLaunchAtLogin()); break;
    case ID_GLITCH: ReportGlitch(); break;
    case ID_QUIT: Logf(L"quit from menu"); Quit(); break;
    case ID_SETTINGS: OpenSettings(-1); break;
    default: break;
    }
    SettingsUiRefresh();
}

void App::OpenSettings(int tab)
{
    CancelTrayClick();
    SettingsUiHost h;
    h.settings = &settings_;
    h.work = disp_.work;
    if (!haveDisp_ || IsRectEmpty(&h.work)) SystemParametersInfoW(SPI_GETWORKAREA, 0, &h.work, 0);
    h.iconBig = iconBig_;
    h.iconSmall = iconOn_;
    h.test = testMode_;
    h.command = [this](int sc) { UiCommand(sc); };
    h.apply = [this](bool save) {
        if (save) settings_.Save();
        if (scene_) scene_->SettingsChanged();
        pollRequested_ = true;
    };
    h.canAddGift = [this] { return scene_ && scene_->CanAddGift(); };
    h.canEditLights = [this] { return scene_ && visible_ && !locked_ && !suspended_ && settings_.effectsOn && !settings_.safeMode; };
    h.enterLightEdit = [this] { CancelTrayClick(); bool on = EnterLightEdit(); SettingsUiRefresh(); return on; };
    h.paused = [this] { return locked_ || suspended_; };
    h.pump = [this] { if (!inMenu_) Tick(false); };
    ShowSettingsUi(h, tab);
}

/// Settings window actions: the same paths as the tray menu (toasts, mode rebuilds, safe mode).
void App::UiCommand(int sc)
{
    static const UINT map[] = {ID_EFFECTS, ID_SNOW, ID_SANTA, ID_PLOW, ID_WINSNOW, ID_LIGHTS, ID_LIVE, ID_GARLANDS, ID_LOGIN, ID_EDITLIGHTS,
                               ID_ADDGIFT, ID_CLEARBALLS, ID_CLEARALL, ID_RESET, ID_MODE_DESKTOP, ID_MODE_ONTOP, ID_LINKS_AUTO, ID_LINKS_MANUAL,
                               ID_DRAG_SLIDES, ID_DRAG_STAYS};
    if (sc == SC_ResetEffects) {
        settings_.ResetEffects();
        Changed();
        Toast(L"↺ 효과 설정을 기본값으로 되돌렸어요");
        return;
    }
    if (sc >= 0 && sc < (int)_countof(map)) Command(map[sc]);
}

LRESULT App::CtlProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (m == wmTaskbarCreated_ && m != 0) { AddTray(); return 0; }
    if (m != 0 && (m == msgState_ || m == msgSanta_ || m == msgBall_ || m == msgEdit_ || m == msgCommand_ || m == msgHit_ || m == msgSnowman_ || m == msgCustomize_ || m == msgSettings_)) {
        if (!testMode_) { Logf(L"automation message ignored (start with --test to enable)"); return 0; }
        if (m == msgState_) { if (scene_) Logf(L"STATE %s", scene_->StateLine().c_str()); }
        else if (m == msgSanta_ && scene_) {
            // w: 0 random, 1 fly over, 2 land; l & 3: 1 right, 2 left; l >> 2: cruise height (screen y, 0 = random)
            int dir = (l & 3) == 1 ? 1 : ((l & 3) == 2 ? -1 : 0), cy = (int)(l >> 2);
            scene_->ForceSantaPass((int)w - 1, dir, cy ? (float)(cy - disp_.bounds.top) : 0.f);
        }
        else if (m == msgSnowman_) { if (scene_) scene_->TestSnowman((float)((int)w - disp_.bounds.left), (int)l); }
        else if (m == msgCustomize_) { if (scene_) Logf(L"TEST customize open %d", scene_->TestOpenCustomizer((float)((int)w - disp_.bounds.left)) ? 1 : 0); }
        else if (m == msgBall_) { if (scene_) { Ball* b = scene_->SpawnTestBall((float)w, (float)l); Logf(L"TEST spawned ball %d", b ? 1 : 0); } }
        else if (m == msgEdit_) ToggleLightEdit();
        else if (m == msgSettings_) { if (l == 1) CloseSettingsUi(); else OpenSettings((int)w); }
        else if (m == msgCommand_) Command((UINT)w);
        else if (m == msgHit_ && scene_) {
            float x = (float)((int)w - disp_.bounds.left), y = (float)((int)l - disp_.bounds.top);
            Logf(L"TEST target at %d,%d = '%s' clickThrough=%d", (int)w, (int)l, scene_->MouseTargetName(x, y).c_str(), clickThrough_ ? 1 : 0);
            Logf(L"TEST %s", scene_->SupportInfo(x, y).c_str());
        }
        return 0;
    }
    switch (m) {
    case WM_TRAY:
        // NOTIFYICON_VERSION_4: LOWORD(l) = event, wParam = icon anchor (screen x, y). A double-click
        // arrives as LBUTTONDOWN, NIN_SELECT, LBUTTONDBLCLK, NIN_SELECT (the second release).
        switch (LOWORD(l)) {
        case WM_LBUTTONDOWN:
            traySkipSelect_ = false;            // a fresh first press: nothing left to skip
            break;
        case NIN_SELECT:
            if (traySkipSelect_) { traySkipSelect_ = false; break; }   // the double-click's second release
            // a single click opens the menu (at the icon) once the double-click time passed without a second click
            if (!inMenu_) {
                trayPt_ = {GET_X_LPARAM(w), GET_Y_LPARAM(w)};
                trayFg_ = GetForegroundWindow();
                SetTimer(h, TIMER_TRAYCLICK, GetDoubleClickTime(), nullptr);
            }
            break;
        case WM_LBUTTONDBLCLK:
            CancelTrayClick();
            traySkipSelect_ = true;
            if (!inMenu_) OpenSettings(-1);
            break;
        case WM_CONTEXTMENU:
        case NIN_KEYSELECT: {
            CancelTrayClick();
            POINT at = {GET_X_LPARAM(w), GET_Y_LPARAM(w)};
            if (!inMenu_) ShowMenu(&at);
            break;
        }
        default:
            break;
        }
        return 0;
    case WM_HOTKEY:
        Logf(L"TEST hotkey %d", (int)w);
        CancelTrayClick();
        switch ((int)w) {
        case HK_QUIT: Logf(L"emergency quit hotkey"); Quit(); break;
        case HK_EFFECTS: ToggleEffects(); break;
        case HK_SNOW: Command(ID_SNOW); break;
        case HK_SANTA: Command(ID_SANTA); break;
        case HK_PLOW: Command(ID_PLOW); break;
        case HK_LIGHTEDIT: ToggleLightEdit(); break;
        case HK_GLITCH: ReportGlitch(); break;
        case HK_SETTINGS: OpenSettings(-1); break;
        default: break;
        }
        return 0;
    case WM_TIMER:
        dog_.Beat();
        if (w == TIMER_REBUILD) { KillTimer(h, TIMER_REBUILD); Rebuild(L"display settings changed"); }
        else if (w == TIMER_MENU && inMenu_) Tick(false);
        else if (w == TIMER_TRAYCLICK) {
            KillTimer(h, TIMER_TRAYCLICK);
            // something else took the foreground since the click (user moved on): no stray menu
            if (GetForegroundWindow() != trayFg_) Logf(L"TEST tray click menu cancelled (foreground changed)");
            else if (!inMenu_) ShowMenu(&trayPt_);
        }
        else if (w == TIMER_STARTHINT) {
            KillTimer(h, TIMER_STARTHINT);
            // one hint at start-up if something was left switched off by an earlier hotkey
            if (!settings_.effectsOn) Toast(L"✨ 효과가 꺼져 있어요 · Ctrl+Alt+Shift+E로 켜기", true);
            else if (!settings_.snowFalling) Toast(L"❄️ 눈 내리기가 꺼져 있어요 · Ctrl+Alt+Shift+S로 켜기");
            else if (!settings_.santa) Toast(L"\U0001F385 산타가 꺼져 있어요 · Ctrl+Alt+Shift+D로 켜기");
            else if (settings_.safeMode) Toast(L"⚠️ " + settings_.safeReason);
        }
        return 0;
    case WM_DISPLAYCHANGE:
        Logf(L"WM_DISPLAYCHANGE");
        SetTimer(h, TIMER_REBUILD, 800, nullptr);
        return 0;
    case WM_SETTINGCHANGE:
        if (w == SPI_SETWORKAREA) pollRequested_ = true;
        return 0;
    case WM_WTSSESSION_CHANGE:
        if (w == WTS_SESSION_LOCK || w == WTS_CONSOLE_DISCONNECT || w == WTS_REMOTE_DISCONNECT) locked_ = true;
        else if (w == WTS_SESSION_UNLOCK || w == WTS_CONSOLE_CONNECT || w == WTS_REMOTE_CONNECT) locked_ = false;
        else return 0;
        Logf(L"session change %u -> locked=%d", (unsigned)w, locked_ ? 1 : 0);
        if (locked_) ExitLightEdit(true);
        UpdateRunning();
        SettingsUiRefresh();                    // its animation timer follows the lock state
        return 0;
    case WM_POWERBROADCAST:
        if (w == PBT_APMSUSPEND) { suspended_ = true; Logf(L"power: suspend"); UpdateRunning(); }
        else if (w == PBT_APMRESUMEAUTOMATIC || w == PBT_APMRESUMESUSPEND) {
            if (suspended_) {
                suspended_ = false;
                Logf(L"power: resume");
                dog_.Beat();
                SetTimer(h, TIMER_REBUILD, 800, nullptr);   // the GPU device may be gone after sleep
            }
        }
        return TRUE;
    default:
        break;
    }
    return DefWindowProcW(h, m, w, l);
}

/// --selftest: writes NaN / garbage gifts, riders and links into the WINTERDESK_DATA_DIR override
/// (refuses to run without it, so real files are never touched), checks the loaders and the
/// NaN-safe helpers, then the normal app starts on those files (they must not crash it).
int RunSelfTest()
{
    wchar_t over[MAX_PATH];
    if (GetEnvironmentVariableW(L"WINTERDESK_DATA_DIR", over, MAX_PATH) == 0) {
        Logf(L"SELFTEST refused: set WINTERDESK_DATA_DIR to a scratch folder");
        return -1;
    }
    std::wstring dir = AppDataDir();
    auto put = [&](const wchar_t* name, const char* text) {
        HANDLE f = CreateFileW((dir + L"\\" + name).c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
        DWORD n = 0;
        if (f != INVALID_HANDLE_VALUE) { WriteFile(f, text, (DWORD)strlen(text), &n, nullptr); CloseHandle(f); }
    };
    put(L"gifts.txt", "nan nan 1 0\n-nan 5 2 1\ninf 3 1 0\n1e39 2 3 0\n12.5 nan 0 1\nnan 2 1\ngarbage\n\t\n300 900 7 1\n");
    put(L"riders.txt", "notepad.exe\t0\tnan\t1.0.0.1\t11,8,6\nnotepad.exe\t1\t0.5\t9.9.9.9\tnan,inf,-3\n\t\t\t\t\nx\t0\t0.4\t1.2.3.4\t12,nan,7\n");
    put(L"links.txt", "a.exe\tnan\t9\tb.exe\t-1\t-5\n\t\t\t\t\t\ngarbage\n");
    int bad = 0;
    auto check = [&](bool ok, const wchar_t* what) { Logf(L"SELFTEST %s: %s", ok ? L"ok  " : L"FAIL", what); if (!ok) bad++; };
    check(Clampf(NAN, 0, 1) == 0 && Clampf(INFINITY, 0, 1) == 1 && Clampf(-INFINITY, 0, 1) == 0, L"Clampf maps NaN / inf into range");
    std::vector<SavedGift> g;
    LoadGifts(g);
    bool finite = true;
    for (const SavedGift& s : g) finite = finite && std::isfinite(s.x) && std::isfinite(s.y);
    check(finite && g.size() == 1, L"gifts loader keeps only finite entries (1 of 9 lines valid)");
    std::vector<SavedRider> r = LoadRiders();
    finite = true;
    for (const SavedRider& s : r) { finite = finite && std::isfinite(s.fx); for (float v : s.radiiPt) finite = finite && std::isfinite(v); }
    check(finite && r.size() == 1 && r[0].radiiPt.size() == 2, L"riders loader drops NaN fx and NaN / inf radii (1 of 4 lines valid, radii 12,nan,7 -> 12,7)");
    std::vector<SavedLink> l = LoadLinks();
    bool kinds = true;
    for (const SavedLink& s : l) kinds = kinds && s.aKind >= 0 && s.aKind <= 2 && s.bKind >= 0 && s.bKind <= 2;
    check(kinds && l.size() == 1, L"links loader clamps anchor kinds and drops lines without owners (1 of 3 lines usable)");
    GroundSnow gs(1920, 1000, 1);
    check(std::isfinite(gs.HeightAt(NAN)) && std::isfinite(gs.SurfaceY(INFINITY)), L"GroundSnow::HeightAt is finite for NaN / inf x");
    WinCap c;
    c.rect = {100, 300, 700, 600};
    c.Init(1, 0, 0);
    check(std::isfinite(c.HeightAt(NAN)) && std::isnan(c.SurfaceAt(NAN)), L"WinCap::HeightAt finite / SurfaceAt NaN for NaN x");
    return bad;
}

}  // namespace

// =============================================================================================
// Entry point
// =============================================================================================

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int)
{
    // physical pixels everywhere: must happen before any window exists
    bool pmv2 = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) != FALSE;
    if (!pmv2) SetProcessDPIAware();

    bool safeFlag = false, log = false, diag = false, test = false, selftest = false;
    double testSeconds = 0;
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    for (int i = 1; argv && i < argc; i++) {
        if (!wcscmp(argv[i], L"--safe")) safeFlag = true;
        else if (!wcscmp(argv[i], L"--log")) log = true;
        else if (!wcscmp(argv[i], L"--diag")) diag = true;
        else if (!wcscmp(argv[i], L"--test")) test = true;
        else if (!wcscmp(argv[i], L"--selftest")) selftest = true;
        else if (!wcscmp(argv[i], L"--test-seconds") && i + 1 < argc) testSeconds = _wtof(argv[++i]);
    }
    if (argv) LocalFree(argv);
    bool shift = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
    if (log || selftest) LogOpen();
    if (diag) DiagOpen();
    if (selftest) {
        int bad = RunSelfTest();
        if (bad < 0) return 4;                       // refused: no WINTERDESK_DATA_DIR override
        if (bad > 0) Logf(L"SELFTEST: %d check(s) FAILED", bad);
        test = true;
    }

    HANDLE mutex = CreateMutexW(nullptr, TRUE, L"Local\\WinterDesk.SingleInstance");
    if (mutex && GetLastError() == ERROR_ALREADY_EXISTS) {
        Logf(L"another instance is running; exiting");
        CloseHandle(mutex);
        return 0;
    }
    std::wstring lastStop;
    bool previousUnhealthy = ArmSentinel(lastStop);
    bool safe = true;
    std::wstring why;
    if (shift) why = L"Safe mode (Shift held at launch)";
    else if (safeFlag) why = L"Safe mode (--safe)";
    else if (previousUnhealthy) why = L"Safe mode — last run did not finish starting cleanly" + (lastStop.empty() ? L"" : L": " + lastStop);
    else safe = false;
    Logf(L"WinterDesk (Windows, C++/Direct2D) start, pid=%lu, dpiAwareness=%s, safe=%d (%s), testSeconds=%.1f, diag=%d", GetCurrentProcessId(),
         pmv2 ? L"PerMonitorV2" : L"system", safe ? 1 : 0, why.c_str(), testSeconds, diag ? 1 : 0);
    App app;
    g_app = &app;
    int code = app.Run(inst, safe, why, testSeconds, test || testSeconds > 0);
    g_app = nullptr;
    if (mutex) {
        ReleaseMutex(mutex);
        CloseHandle(mutex);
    }
    return code;
}
