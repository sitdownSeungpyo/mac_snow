// Log, random numbers, settings / gift / rider / link persistence, launch-at-login,
// crash sentinel, --diag CSV and the "Report a Glitch" ring.
#include "winterdesk.h"
#include <shlobj.h>
#include <cstdio>
#include <cstdarg>
#include <random>
#include <mutex>
#include <deque>

#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "ole32.lib")

// ---------------------------------------------------------------------------------------------
// Log (only with --log): %TEMP%\WinterDesk.log, UTF-8, truncated each start.
// ---------------------------------------------------------------------------------------------
static FILE* g_log = nullptr;
static std::mutex g_logLock;

void LogOpen()
{
    wchar_t dir[MAX_PATH];
    DWORD n = GetTempPathW(MAX_PATH, dir);
    if (n == 0 || n >= MAX_PATH) return;
    std::wstring path = std::wstring(dir) + L"WinterDesk.log";
    g_log = _wfsopen(path.c_str(), L"w, ccs=UTF-8", _SH_DENYWR);   // readable while running
}

void Logf(const wchar_t* fmt, ...)
{
    if (!g_log) return;
    wchar_t buf[2048];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf_s(buf, _countof(buf), _TRUNCATE, fmt, ap);
    va_end(ap);
    SYSTEMTIME st;
    GetLocalTime(&st);
    std::lock_guard<std::mutex> lock(g_logLock);
    fwprintf(g_log, L"%02u:%02u:%02u.%03u %s\n", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, buf);
    fflush(g_log);
}

double NowSec()
{
    static LARGE_INTEGER freq = [] { LARGE_INTEGER f; QueryPerformanceFrequency(&f); return f; }();
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return (double)t.QuadPart / (double)freq.QuadPart;
}

static std::mt19937& Rng()
{
    static std::mt19937 rng((unsigned)GetTickCount64() ^ (unsigned)GetCurrentProcessId());
    return rng;
}

double Rand01() { return std::uniform_real_distribution<double>(0.0, 1.0)(Rng()); }
float Rand(float lo, float hi) { return lo + (float)Rand01() * (hi - lo); }
int RandInt(int n) { return n <= 1 ? 0 : std::uniform_int_distribution<int>(0, n - 1)(Rng()); }

std::string Utf8(const std::wstring& w)
{
    if (w.empty()) return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s((size_t)n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], n, nullptr, nullptr);
    return s;
}

std::wstring Wide(const std::string& s)
{
    if (s.empty()) return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring w((size_t)n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
    return w;
}

// ---------------------------------------------------------------------------------------------
// Files in %APPDATA%\WinterDesk
// ---------------------------------------------------------------------------------------------
std::wstring AppDataDir()
{
    // WINTERDESK_DATA_DIR overrides the data folder (used by --selftest so it never touches real files)
    wchar_t over[MAX_PATH];
    DWORD on = GetEnvironmentVariableW(L"WINTERDESK_DATA_DIR", over, MAX_PATH);
    if (on > 0 && on < MAX_PATH) {
        CreateDirectoryW(over, nullptr);
        return over;
    }
    PWSTR p = nullptr;
    std::wstring dir;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &p))) dir = p;
    CoTaskMemFree(p);
    if (dir.empty()) return dir;
    dir += L"\\WinterDesk";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir;
}

static std::wstring LogsDir()
{
    PWSTR p = nullptr;
    std::wstring dir;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &p))) dir = p;
    CoTaskMemFree(p);
    if (dir.empty()) return dir;
    dir += L"\\WinterDesk";
    CreateDirectoryW(dir.c_str(), nullptr);
    dir += L"\\Logs";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir;
}

static bool ReadText(const std::wstring& path, std::string& out)
{
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size;
    bool ok = GetFileSizeEx(f, &size) && size.QuadPart < (1 << 20);
    if (ok) {
        out.resize((size_t)size.QuadPart);
        DWORD got = 0;
        ok = size.QuadPart == 0 || (ReadFile(f, &out[0], (DWORD)size.QuadPart, &got, nullptr) && got == (DWORD)size.QuadPart);
    }
    CloseHandle(f);
    return ok;
}

/// Writes to a temp file and swaps it in, so a crash never leaves a half-written file.
static bool WriteText(const std::wstring& path, const std::string& text)
{
    std::wstring tmp = path + L".tmp";
    HANDLE f = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return false;
    DWORD put = 0;
    bool ok = WriteFile(f, text.data(), (DWORD)text.size(), &put, nullptr) && put == text.size();
    ok = ok && FlushFileBuffers(f);                       // on disk before the rename swaps it in
    CloseHandle(f);
    if (!ok || !MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        DeleteFileW(tmp.c_str());
        return false;
    }
    return true;
}

/// Writes only when the text differs from what the file already holds (no needless disk writes).
static bool WriteIfChanged(const std::wstring& path, const std::string& text)
{
    static std::map<std::wstring, std::string> last;
    auto it = last.find(path);
    if (it != last.end() && it->second == text) return true;
    std::string cur;
    if (it == last.end() && ReadText(path, cur) && cur == text) { last[path] = text; return true; }
    if (!WriteText(path, text)) return false;
    last[path] = text;
    return true;
}

static std::vector<std::string> Lines(const std::string& text)
{
    std::vector<std::string> out;
    size_t pos = 0;
    while (pos < text.size()) {
        size_t end = text.find('\n', pos);
        if (end == std::string::npos) end = text.size();
        std::string line = text.substr(pos, end - pos);
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (!line.empty() && line[0] != '#') out.push_back(line);
        pos = end + 1;
    }
    return out;
}

static std::vector<std::string> SplitTabs(const std::string& line)
{
    std::vector<std::string> f;
    size_t pos = 0;
    for (;;) {
        size_t t = line.find('\t', pos);
        f.push_back(line.substr(pos, t == std::string::npos ? std::string::npos : t - pos));
        if (t == std::string::npos) break;
        pos = t + 1;
    }
    return f;
}

void Settings::Load()
{
    std::wstring dir = AppDataDir();
    std::string text;
    if (dir.empty() || !ReadText(dir + L"\\settings.ini", text)) return;
    for (const std::string& line : Lines(text)) {
        size_t eq = line.find('=');
        if (eq == std::string::npos) continue;
        std::string k = line.substr(0, eq);
        int v = atoi(line.c_str() + eq + 1);
        bool b = v != 0;
        if (k == "EffectsOn") effectsOn = b;
        else if (k == "SnowFalling") snowFalling = b;
        else if (k == "Intensity") intensity = std::max(0, std::min(2, v));
        else if (k == "Mode") mode = v == ModeDesktop ? ModeDesktop : ModeOnTop;
        else if (k == "Santa") santa = b;
        else if (k == "Snowplow") snowplow = b;
        else if (k == "WindowSnow") windowSnow = b;
        else if (k == "WindowLights") windowLights = b;
        else if (k == "LightLinksAuto") lightLinksAuto = b;
        else if (k == "WindowGarlands") windowGarlands = b;
        else if (k == "LightStyle") lightStyle = v == 1 ? 1 : 0;
        else if (k == "DragSnowSlides") dragSnowSlides = b;
        else if (k == "LiveTracking") liveTracking = b;
        else if (k == "ManualAfterFirstLinkDone") manualAfterFirstLinkDone = b;
    }
}

void Settings::Save() const
{
    std::wstring dir = AppDataDir();
    if (dir.empty()) return;
    char buf[512];
    sprintf_s(buf,
              "EffectsOn=%d\nSnowFalling=%d\nIntensity=%d\nMode=%d\nSanta=%d\nSnowplow=%d\nWindowSnow=%d\nWindowLights=%d\n"
              "LightLinksAuto=%d\nWindowGarlands=%d\nLightStyle=%d\nDragSnowSlides=%d\nLiveTracking=%d\nManualAfterFirstLinkDone=%d\n",
              effectsOn ? 1 : 0, snowFalling ? 1 : 0, intensity, mode, santa ? 1 : 0, snowplow ? 1 : 0, windowSnow ? 1 : 0,
              windowLights ? 1 : 0, lightLinksAuto ? 1 : 0, windowGarlands ? 1 : 0, lightStyle, dragSnowSlides ? 1 : 0,
              liveTracking ? 1 : 0, manualAfterFirstLinkDone ? 1 : 0);
    if (!WriteIfChanged(dir + L"\\settings.ini", buf)) Logf(L"settings save failed");
}

// gifts.txt: one gift per line "x y variant default" (monitor-local px). Old 3-field lines
// ("xFraction variant default") load as x = -fraction (the scene resolves it).
bool LoadGifts(std::vector<SavedGift>& out)
{
    out.clear();
    std::wstring dir = AppDataDir();
    std::string text;
    if (dir.empty() || !ReadText(dir + L"\\gifts.txt", text)) return false;
    for (const std::string& line : Lines(text)) {
        if ((int)out.size() >= Scene::kMaxGifts) break;
        float x = 0, y = 0;
        int v = 0, d = 0;
        SavedGift g{};
        if (sscanf_s(line.c_str(), "%f %f %d %d", &x, &y, &v, &d) == 4) {
            if (!std::isfinite(x) || !std::isfinite(y) || std::fabs(x) > 100000 || std::fabs(y) > 100000) continue;
            g.x = x;
            g.y = y;
        } else if (sscanf_s(line.c_str(), "%f %d %d", &x, &v, &d) == 3) {
            if (!std::isfinite(x)) continue;
            g.x = -Clampf(x, 0, 1) - 0.0001f;
            g.y = -1;
        } else {
            continue;
        }
        g.variant = ((v % 4) + 4) % 4;
        g.isDefault = d != 0;
        out.push_back(g);
    }
    return true;
}

void SaveGifts(const std::vector<SavedGift>& gifts)
{
    std::wstring dir = AppDataDir();
    if (dir.empty()) return;
    std::string text = "# WinterDesk gifts: x y (monitor px) variant(0..3) default(0/1)\n";
    char buf[96];
    for (const SavedGift& g : gifts) {
        sprintf_s(buf, "%.1f %.1f %d %d\n", g.x, g.y, g.variant, g.isDefault ? 1 : 0);
        text += buf;
    }
    if (!WriteIfChanged(dir + L"\\gifts.txt", text)) Logf(L"gift save failed");
}

// riders.txt: owner \t index \t fx \t hat.face.body.clothes \t r1,r2,... (pt)
std::vector<SavedRider> LoadRiders()
{
    std::vector<SavedRider> out;
    std::wstring dir = AppDataDir();
    std::string text;
    if (dir.empty() || !ReadText(dir + L"\\riders.txt", text)) return out;
    for (const std::string& line : Lines(text)) {
        std::vector<std::string> f = SplitTabs(line);
        if (f.size() < 5 || out.size() >= 24) continue;
        SavedRider r;
        r.owner = Wide(f[0]);
        r.index = atoi(f[1].c_str());
        float fx = (float)atof(f[2].c_str());
        if (!std::isfinite(fx)) continue;
        r.fx = Clampf(fx, 0, 1);
        sscanf_s(f[3].c_str(), "%d.%d.%d.%d", &r.outfit.hat, &r.outfit.face, &r.outfit.body, &r.outfit.clothes);
        r.outfit.hat = std::max(0, std::min(7, r.outfit.hat));
        r.outfit.face = std::max(0, std::min(7, r.outfit.face));
        r.outfit.body = std::max(0, std::min(7, r.outfit.body));
        r.outfit.clothes = std::max(0, std::min(7, r.outfit.clothes));
        size_t pos = 0;
        while (pos < f[4].size() && r.radiiPt.size() < 3) {
            size_t c = f[4].find(',', pos);
            float v = (float)atof(f[4].substr(pos, c == std::string::npos ? std::string::npos : c - pos).c_str());
            if (std::isfinite(v) && v > 0) r.radiiPt.push_back(Clampf(v, 4, 80));
            if (c == std::string::npos) break;
            pos = c + 1;
        }
        if (!r.owner.empty() && !r.radiiPt.empty()) out.push_back(r);
    }
    return out;
}

void SaveRiders(const std::vector<SavedRider>& riders)
{
    std::wstring dir = AppDataDir();
    if (dir.empty()) return;
    std::string text = "# WinterDesk window snowmen: owner index fx outfit radii\n";
    char buf[256];
    size_t n = 0;
    for (const SavedRider& r : riders) {
        if (++n > 24) break;
        std::string radii;
        for (float v : r.radiiPt) { char b[16]; sprintf_s(b, radii.empty() ? "%.1f" : ",%.1f", v); radii += b; }
        sprintf_s(buf, "\t%d\t%.4f\t%s\t", r.index, r.fx, r.outfit.Key().c_str());
        text += Utf8(r.owner) + buf + radii + "\n";
    }
    WriteIfChanged(dir + L"\\riders.txt", text);
}

// links.txt: aOwner \t aIndex \t aKind \t bOwner \t bIndex \t bKind
std::vector<SavedLink> LoadLinks()
{
    std::vector<SavedLink> out;
    std::wstring dir = AppDataDir();
    std::string text;
    if (dir.empty() || !ReadText(dir + L"\\links.txt", text)) return out;
    for (const std::string& line : Lines(text)) {
        std::vector<std::string> f = SplitTabs(line);
        if (f.size() < 6 || (int)out.size() >= Scene::kMaxLinks) continue;
        SavedLink l;
        l.aOwner = Wide(f[0]);
        l.aIndex = atoi(f[1].c_str());
        l.aKind = std::max(0, std::min(2, atoi(f[2].c_str())));
        l.bOwner = Wide(f[3]);
        l.bIndex = atoi(f[4].c_str());
        l.bKind = std::max(0, std::min(2, atoi(f[5].c_str())));
        if (l.aOwner.empty() || l.bOwner.empty()) continue;   // unusable line
        out.push_back(l);
    }
    return out;
}

void SaveLinks(const std::vector<SavedLink>& links)
{
    std::wstring dir = AppDataDir();
    if (dir.empty()) return;
    std::string text = "# WinterDesk light links: aOwner aIndex aKind bOwner bIndex bKind (kind 0 left, 1 center, 2 right)\n";
    for (const SavedLink& l : links) {
        char b[64];
        text += Utf8(l.aOwner);
        sprintf_s(b, "\t%d\t%d\t", l.aIndex, l.aKind);
        text += b + Utf8(l.bOwner);
        sprintf_s(b, "\t%d\t%d\n", l.bIndex, l.bKind);
        text += b;
    }
    WriteIfChanged(dir + L"\\links.txt", text);
}

// ---------------------------------------------------------------------------------------------
// Launch at login: HKCU\Software\Microsoft\Windows\CurrentVersion\Run\WinterDesk
// ---------------------------------------------------------------------------------------------
static const wchar_t* kRunKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";

bool GetLaunchAtLogin()
{
    DWORD type = 0, size = 0;
    return RegGetValueW(HKEY_CURRENT_USER, kRunKey, L"WinterDesk", RRF_RT_REG_SZ, &type, nullptr, &size) == ERROR_SUCCESS;
}

void RefreshLaunchAtLogin()
{
    wchar_t val[MAX_PATH + 4];
    DWORD size = sizeof(val);
    if (RegGetValueW(HKEY_CURRENT_USER, kRunKey, L"WinterDesk", RRF_RT_REG_SZ, nullptr, val, &size) != ERROR_SUCCESS) return;
    wchar_t exe[MAX_PATH];
    DWORD n = GetModuleFileNameW(nullptr, exe, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return;
    std::wstring want = L"\"" + std::wstring(exe) + L"\"";
    if (_wcsicmp(val, want.c_str()) != 0) {
        Logf(L"launch at login pointed to %s; updating to this exe", val);
        SetLaunchAtLogin(true);
    }
}

void SetLaunchAtLogin(bool on)
{
    HKEY k;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &k, nullptr) != ERROR_SUCCESS) return;
    if (on) {
        wchar_t exe[MAX_PATH];
        DWORD n = GetModuleFileNameW(nullptr, exe, MAX_PATH);
        if (n > 0 && n < MAX_PATH) {
            std::wstring cmd = L"\"" + std::wstring(exe) + L"\"";
            RegSetValueExW(k, L"WinterDesk", 0, REG_SZ, (const BYTE*)cmd.c_str(), (DWORD)((cmd.size() + 1) * sizeof(wchar_t)));
        }
    } else {
        RegDeleteValueW(k, L"WinterDesk");
    }
    RegCloseKey(k);
    Logf(L"launch at login -> %d", on ? 1 : 0);
}

// ---------------------------------------------------------------------------------------------
// Crash / hang sentinel (%APPDATA%\WinterDesk\sentinel.txt): "running" while a run has not yet
// been healthy for 10 s, "stop:<reason>" after a safety stop; absent after a clean run.
// ---------------------------------------------------------------------------------------------
static std::wstring SentinelPath() { std::wstring d = AppDataDir(); return d.empty() ? d : d + L"\\sentinel.txt"; }

bool ArmSentinel(std::wstring& lastReason)
{
    std::wstring path = SentinelPath();
    if (path.empty()) return false;
    std::string prev;
    bool unhealthy = ReadText(path, prev) && !prev.empty();
    if (unhealthy) {
        lastReason = prev.compare(0, 5, "stop:") == 0 ? Wide(prev.substr(5)) : L"";
    }
    WriteText(path, "running");
    return unhealthy;
}

void ClearSentinel()
{
    std::wstring path = SentinelPath();
    if (!path.empty()) DeleteFileW(path.c_str());
}

void RecordSafetyStop(const wchar_t* reason)
{
    std::wstring path = SentinelPath();
    if (path.empty()) return;
    HANDLE f = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    std::string s = "stop:" + Utf8(reason);
    DWORD put = 0;
    WriteFile(f, s.data(), (DWORD)s.size(), &put, nullptr);
    CloseHandle(f);
}

// ---------------------------------------------------------------------------------------------
// --diag CSV + always-on ring
// ---------------------------------------------------------------------------------------------
static std::mutex g_diagLock;
static FILE* g_diag = nullptr;
static std::wstring g_diagPath;
static std::vector<std::string> g_diagBuf;
static size_t g_diagRows = 0;
static std::deque<std::string> g_ring;

static std::string Stamp()
{
    SYSTEMTIME st;
    GetLocalTime(&st);
    char b[32];
    sprintf_s(b, "%04u%02u%02u-%02u%02u%02u", st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
    return b;
}

void DiagOpen()
{
    std::wstring dir = LogsDir();
    if (dir.empty()) return;
    g_diagPath = dir + L"\\diag-" + Wide(Stamp()) + L".csv";
    g_diag = _wfsopen(g_diagPath.c_str(), L"wb", _SH_DENYWR);
    if (g_diag) {
        fputs("t,event,id,x,y,w,h,note\n", g_diag);
        fflush(g_diag);
        Logf(L"--diag CSV: %s", g_diagPath.c_str());
    }
}

bool DiagEnabled() { return g_diag != nullptr; }

void Diag(const char* event, HWND id, const RECT* r, const std::wstring& note)
{
    char head[160];
    char rect[96] = ",,,";
    if (r) sprintf_s(rect, "%ld,%ld,%ld,%ld", r->left, r->top, r->right - r->left, r->bottom - r->top);
    char idb[24] = "";
    if (id) sprintf_s(idb, "%llx", (unsigned long long)(uintptr_t)id);
    sprintf_s(head, "%.4f,%s,%s,%s,", NowSec(), event, idb, rect);
    std::string n = Utf8(note);
    std::replace(n.begin(), n.end(), ',', ';');
    std::string line = head + n;
    std::lock_guard<std::mutex> lock(g_diagLock);
    if (strcmp(event, "liveFrame") != 0) {
        g_ring.push_back(line);
        if (g_ring.size() > 2000) g_ring.pop_front();
    }
    if (g_diag && g_diagRows < 200000) {
        g_diagBuf.push_back(line);
        g_diagRows++;
    }
}

void DiagFlush()
{
    std::lock_guard<std::mutex> lock(g_diagLock);
    if (!g_diag || g_diagBuf.empty()) return;
    for (const std::string& l : g_diagBuf) { fputs(l.c_str(), g_diag); fputc('\n', g_diag); }
    g_diagBuf.clear();
    fflush(g_diag);
}

std::wstring DumpGlitchRing(const std::wstring& state)
{
    std::wstring dir = LogsDir();
    if (dir.empty()) return L"";
    std::wstring path = dir + L"\\glitch-" + Wide(Stamp()) + L".csv";
    std::string text = "t,event,id,x,y,w,h,note\n";
    {
        std::lock_guard<std::mutex> lock(g_diagLock);
        for (const std::string& l : g_ring) text += l + "\n";
    }
    char b[64];
    sprintf_s(b, "%.4f,state,,,,,,", NowSec());
    std::string s = Utf8(state);
    std::replace(s.begin(), s.end(), ',', ';');
    text += b + s + "\n";
    return WriteText(path, text) ? path : L"";
}
