// Finds the laptop's built-in panel and the taskbar edge on it; small window helpers.
#include "winterdesk.h"
#include <shellscalingapi.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <cwctype>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "shcore.lib")
#pragma comment(lib, "dwmapi.lib")

namespace {

struct Mon {
    HMONITOR h;
    std::wstring name;
    RECT bounds, work;
    bool primary;
};

BOOL CALLBACK MonProc(HMONITOR h, HDC, LPRECT, LPARAM data)
{
    MONITORINFOEXW mi{};
    mi.cbSize = sizeof(mi);
    if (GetMonitorInfoW(h, &mi)) {
        Mon m{h, mi.szDevice, mi.rcMonitor, mi.rcWork, (mi.dwFlags & MONITORINFOF_PRIMARY) != 0};
        reinterpret_cast<std::vector<Mon>*>(data)->push_back(m);
    }
    return TRUE;
}

bool IsInternalTech(DISPLAYCONFIG_VIDEO_OUTPUT_TECHNOLOGY t)
{
    return t == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INTERNAL || t == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_DISPLAYPORT_EMBEDDED ||
           t == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_UDI_EMBEDDED || t == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_LVDS;
}

/// GDI name (\\.\DISPLAYn) of the active path whose target is the built-in panel; prefers
/// OUTPUT_TECHNOLOGY_INTERNAL over embedded DP / UDI / LVDS.
std::wstring QueryInternalGdiName(std::wstring& tech, std::wstring& friendly)
{
    std::vector<DISPLAYCONFIG_PATH_INFO> paths;
    std::vector<DISPLAYCONFIG_MODE_INFO> modes;
    LONG err = ERROR_INSUFFICIENT_BUFFER;
    UINT32 np = 0, nm = 0;
    for (int attempt = 0; attempt < 4 && err == ERROR_INSUFFICIENT_BUFFER; attempt++) {
        err = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &np, &nm);
        if (err != ERROR_SUCCESS) { Logf(L"GetDisplayConfigBufferSizes error %ld", err); return L""; }
        paths.resize(np);
        modes.resize(nm);
        err = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &np, paths.data(), &nm, modes.data(), nullptr);
    }
    if (err != ERROR_SUCCESS) { Logf(L"QueryDisplayConfig error %ld", err); return L""; }

    std::wstring best;
    int bestRank = 0;
    for (UINT32 i = 0; i < np; i++) {
        const DISPLAYCONFIG_PATH_INFO& p = paths[i];
        DISPLAYCONFIG_SOURCE_DEVICE_NAME src{};
        src.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
        src.header.size = sizeof(src);
        src.header.adapterId = p.sourceInfo.adapterId;
        src.header.id = p.sourceInfo.id;
        LONG r = DisplayConfigGetDeviceInfo(&src.header);
        DISPLAYCONFIG_TARGET_DEVICE_NAME tgt{};
        tgt.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
        tgt.header.size = sizeof(tgt);
        tgt.header.adapterId = p.targetInfo.adapterId;
        tgt.header.id = p.targetInfo.id;
        LONG rt = DisplayConfigGetDeviceInfo(&tgt.header);
        DISPLAYCONFIG_VIDEO_OUTPUT_TECHNOLOGY t = p.targetInfo.outputTechnology;
        Logf(L"display path %u: source=%s target=\"%s\" outputTechnology=0x%08X", i,
             r == ERROR_SUCCESS ? src.viewGdiDeviceName : L"<err>",
             rt == ERROR_SUCCESS ? tgt.monitorFriendlyDeviceName : L"", (unsigned)t);
        if (r != ERROR_SUCCESS || !IsInternalTech(t)) continue;
        int rank = t == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INTERNAL ? 2 : 1;
        if (rank > bestRank) {
            bestRank = rank;
            best = src.viewGdiDeviceName;
            wchar_t b[64];
            swprintf_s(b, L"outputTechnology=0x%08X", (unsigned)t);
            tech = b;
            friendly = rt == ERROR_SUCCESS ? tgt.monitorFriendlyDeviceName : L"";
        }
    }
    return best;
}

}  // namespace

DisplayInfo FindInternalDisplay()
{
    std::vector<Mon> mons;
    EnumDisplayMonitors(nullptr, nullptr, MonProc, reinterpret_cast<LPARAM>(&mons));
    std::wstring tech, friendly;
    std::wstring name = QueryInternalGdiName(tech, friendly);

    DisplayInfo d;
    const Mon* chosen = nullptr;
    if (!name.empty())
        for (const Mon& m : mons)
            if (_wcsicmp(m.name.c_str(), name.c_str()) == 0) chosen = &m;
    if (chosen) {
        d.isInternal = true;
        d.how = L"QueryDisplayConfig " + tech;
        d.friendly = friendly;
    } else {
        // No active built-in panel (lid closed / docked / second screen only / desktop PC, or the
        // panel's GDI name has no monitor): never draw on another monitor. The caller pauses.
        d.name = L"(none)";
        d.how = name.empty() ? L"no active internal panel" : L"internal panel " + name + L" has no matching monitor";
        return d;
    }
    d.name = chosen->name;
    d.bounds = chosen->bounds;
    d.work = chosen->work;
    d.hmon = chosen->h;
    UINT dx = 96, dy = 96;
    if (SUCCEEDED(GetDpiForMonitor(chosen->h, MDT_EFFECTIVE_DPI, &dx, &dy)) && dx >= 48) d.scale = dx / 96.f;
    DEVMODEW dm{};
    dm.dmSize = sizeof(dm);
    if (EnumDisplaySettingsW(chosen->name.c_str(), ENUM_CURRENT_SETTINGS, &dm) && dm.dmDisplayFrequency > 1)
        d.refreshHz = (int)dm.dmDisplayFrequency;
    return d;
}

namespace {
struct BarSearch { std::vector<HWND> bars; };
BOOL CALLBACK BarProc(HWND h, LPARAM data)
{
    if (ClassIs(h, L"Shell_TrayWnd") || ClassIs(h, L"Shell_SecondaryTrayWnd"))
        reinterpret_cast<BarSearch*>(data)->bars.push_back(h);
    return TRUE;
}
}  // namespace

int GroundLine(const DisplayInfo& d, std::wstring& how)
{
    const RECT& mon = d.bounds;
    APPBARDATA abd{};
    abd.cbSize = sizeof(abd);
    if ((SHAppBarMessage(ABM_GETSTATE, &abd) & ABS_AUTOHIDE) != 0) { how = L"taskbar auto-hide"; return mon.bottom; }

    BarSearch s;
    EnumWindows(BarProc, reinterpret_cast<LPARAM>(&s));
    int monW = mon.right - mon.left, monH = mon.bottom - mon.top;
    for (HWND h : s.bars) {
        if (!IsWindowVisible(h)) continue;
        RECT tb;
        if (!GetWindowRect(h, &tb)) continue;
        RECT inter;
        if (!IntersectRect(&inter, &tb, &mon) || inter.right - inter.left < monW / 2) continue;
        bool atBottom = tb.bottom >= mon.bottom - 2 && tb.top > mon.top + monH / 2;
        if (!atBottom) continue;
        if (mon.bottom - tb.top < 8) { how = L"taskbar hidden"; return mon.bottom; }
        how = ClassIs(h, L"Shell_TrayWnd") ? L"taskbar Shell_TrayWnd" : L"taskbar Shell_SecondaryTrayWnd";
        return tb.top;
    }
    how = L"no bottom taskbar on this monitor";
    return mon.bottom;
}

bool FrameBounds(HWND h, RECT* r)
{
    if (SUCCEEDED(DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, r, sizeof(RECT)))) return true;
    return GetWindowRect(h, r) != FALSE;
}

bool IsCloaked(HWND h)
{
    DWORD cloaked = 0;
    if (FAILED(DwmGetWindowAttribute(h, DWMWA_CLOAKED, &cloaked, sizeof(cloaked)))) return false;
    return cloaked != 0;
}

void ClassOf(HWND h, wchar_t* buf, int n)
{
    if (GetClassNameW(h, buf, n) == 0) buf[0] = 0;
}

bool ClassIs(HWND h, const wchar_t* cls)
{
    wchar_t buf[64];
    ClassOf(h, buf, 64);
    return wcscmp(buf, cls) == 0;
}

std::wstring ExeNameOf(HWND h)
{
    static std::unordered_map<DWORD, std::wstring> cache;
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    auto it = cache.find(pid);
    if (it != cache.end()) return it->second;
    std::wstring name;
    HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (p) {
        wchar_t buf[MAX_PATH];
        DWORD n = MAX_PATH;
        if (QueryFullProcessImageNameW(p, 0, buf, &n)) {
            name = buf;
            size_t slash = name.find_last_of(L'\\');
            if (slash != std::wstring::npos) name = name.substr(slash + 1);
            for (wchar_t& c : name) c = (wchar_t)towlower(c);
        }
        CloseHandle(p);
    }
    if (cache.size() > 512) cache.clear();
    cache[pid] = name;
    return name;
}

namespace {
struct HostSearch { HWND worker = nullptr; };
BOOL CALLBACK HostProc(HWND h, LPARAM data)
{
    if (ClassIs(h, L"WorkerW") && IsWindowVisible(h) && FindWindowExW(h, nullptr, L"SHELLDLL_DefView", nullptr)) {
        reinterpret_cast<HostSearch*>(data)->worker = h;
        return FALSE;
    }
    return TRUE;
}
}  // namespace

HWND DesktopIconHost(std::wstring* layout)
{
    HWND progman = FindWindowW(L"Progman", nullptr);
    if (progman && FindWindowExW(progman, nullptr, L"SHELLDLL_DefView", nullptr)) {
        if (layout) {
            bool wallWorker = FindWindowExW(progman, nullptr, L"WorkerW", nullptr) != nullptr;
            *layout = wallWorker ? L"Progman hosts SHELLDLL_DefView + wallpaper WorkerW child (Windows 11 24H2 layout)"
                                 : L"Progman hosts SHELLDLL_DefView (no wallpaper WorkerW child)";
        }
        return progman;
    }
    HostSearch s;
    EnumWindows(HostProc, reinterpret_cast<LPARAM>(&s));
    if (s.worker) {
        if (layout) *layout = L"a top-level WorkerW hosts SHELLDLL_DefView (classic layout after 0x052C)";
        return s.worker;
    }
    if (layout) *layout = progman ? L"Progman without icon view" : L"no desktop host found";
    return progman;
}
