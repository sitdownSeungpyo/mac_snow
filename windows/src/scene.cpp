// The winter scene for the internal display, in monitor-local physical pixels (y down).
// Ported behaviour-for-behaviour from the mac WinterScene / WindowSnow / Santa / Gift / Snowball
// code; mac sizes are points and are multiplied by S (monitor DPI / 96).
#include "winterdesk.h"

using D2D1::Matrix3x2F;
using D2D1::Point2F;

namespace {
const float kDeerX[3] = {72, 124, 176};
const D2D1_POINT_2F kHips[4] = {{6, 14}, {4, 14.5f}, {-7, 14}, {-9, 14.5f}};
const D2D1_POINT_2F kArmPivot = {-6, 31};
const D2D1_POINT_2F kHeadPivot = {-15, 34};
const D2D1_POINT_2F kNeck = {9, 23};
const D2D1_POINT_2F kNose = {27.5f, 29.5f};
const int kMaxBalls = 24;               // mac maxBalls
const float kBallMaxPt = 80;            // Snowball.maxRadius
const float kBallGravityPt = 1800;
const float kGravityPt = 1500;
const size_t kMaxGrains = 600;          // WinterScene.maxGrains
const float kGrainAreaPt = 1.2f;        // pt^2 per grain
const size_t kMaxClumps = 120;
const float kTol = D2D1_DEFAULT_FLATTENING_TOLERANCE;
// window caps (WindowCap / WinterScene constants)
const float kCapColPt = 2, kCapMaxPt = 5.0f, kCapReposePt = 1.1f, kCapStartLo = 2.4f, kCapStartHi = 3.0f;
const float kCapGrowth = 0.25f;         // caps grow at 1/4 of the ground rate
const double kSettleDelay = 0.4;        // a window at rest this long gets its snow back
const double kSettleInDelay = 1.0;      // a new window is decorated after 1 s at rest
const float kKeepFraction = 0.4f;       // regrow to 40% of the height it had
const float kRegrowDuration = 1.2f;
const float kRiderFallAccelPt = 70000;  // pt/s^2: only a violent shake throws riders off
const float kShedAccelPt = 8000;
const double kShedCooldown = 0.34;
const float kShedStopSpeedPt = 600;
const float kFlingSpeedPt = 2500;
const double kDragEndAfter = 0.12;      // no live events this long = the drag is over
const float kAccumulation[3] = {0.02f, 0.05f, 0.12f};   // pt/s (Intensity.accumulation)

inline float Sq(float v) { return v * v; }
}  // namespace

// =============================================================================================
// GroundSnow: heightmap on top of the taskbar (or the bottom of the screen)
// =============================================================================================

GroundSnow::GroundSnow(int width, float base, float scale) : baseY(base), scale_(scale), width_(width)
{
    colW = std::max(3.f, 6.f * scale);
    n = (int)std::ceil(width / colW) + 1;
    h_.assign(n, 0);
    jit_.assign(n, 0);
    float p1 = Rand(0, 6.28f), p2 = Rand(0, 6.28f);
    for (int i = 0; i < n; i++) jit_[i] = 3 * std::sin(i * 0.11f + p1) + 1.5f * std::sin(i * 0.29f + p2) - 2;
    Reset();
}

void GroundSnow::Reset()
{
    for (int i = 0; i < n; i++)
        h_[i] = std::max(0.f, (startPt + 1.2f * std::sin(i * 0.17f) + 0.6f * std::sin(i * 0.41f + 1.3f)) * scale_);
    urgent_ = true;
}

void GroundSnow::Clear()
{
    std::fill(h_.begin(), h_.end(), 0.f);
    urgent_ = true;
}

int GroundSnow::Col(float x) const { return std::max(0, std::min(n - 1, (int)std::lround(x / colW))); }

float GroundSnow::HeightAt(float x) const
{
    if (!std::isfinite(x)) return 0;
    float f = Clampf(x / colW, 0, (float)(n - 1));
    int i = (int)f;
    int j = std::min(n - 1, i + 1);
    float t = f - i;
    return h_[i] * (1 - t) + h_[j] * t;
}

void GroundSnow::AddFlake(float x, float amount)
{
    // GroundSnow.accumulate: a lump spread over 7 columns, bounded by the snowfall limit
    static const float w[7] = {0.06f, 0.12f, 0.18f, 0.28f, 0.18f, 0.12f, 0.06f};
    int c = Col(x);
    for (int k = 0; k < 7; k++) {
        int i = c + k - 3;
        if (i < 0 || i >= n || h_[i] >= Max(i)) continue;
        h_[i] = std::min(Max(i), h_[i] + amount * w[k]);
        dirty_ = true;
    }
}

float GroundSnow::Take(float x, float halfW, float depth)
{
    int a = Col(x - halfW), b = Col(x + halfW);
    float area = 0;
    for (int i = a; i <= b; i++) {
        float d = std::min(depth, h_[i]);
        h_[i] -= d;
        area += d * colW;
    }
    if (area > 0) urgent_ = true;
    return area;
}

float GroundSnow::Scrape(float x, float halfW, float level)
{
    int a = Col(x - halfW), b = Col(x + halfW);
    float area = 0;
    for (int i = a; i <= b; i++)
        if (h_[i] > level) { area += (h_[i] - level) * colW; h_[i] = level; }
    if (area > 0) urgent_ = true;
    return area;
}

void GroundSnow::Deposit(float x, float area)
{
    if (area <= 0 || !std::isfinite(area) || !std::isfinite(x)) return;
    int c = Col(x);
    int spread = std::max(2, (int)(std::sqrt(area) / colW) + 1);
    float pile = pilePt * scale_;
    float total = 0;
    for (int k = -spread; k <= spread; k++) total += (float)(spread + 1 - std::abs(k));
    for (int k = -spread; k <= spread; k++) {
        int i = c + k;
        if (i < 0 || i >= n) continue;
        h_[i] = std::min(pile, h_[i] + area * (spread + 1 - std::abs(k)) / total / colW);
    }
    urgent_ = true;
}

void GroundSnow::Relax()
{
    float maxStep = colW * 0.7f;
    bool changed = false;
    for (int pass = 0; pass < 2; pass++)
        for (int i = 0; i + 1 < n; i++) {
            float d = h_[i] - h_[i + 1];
            if (d > maxStep) { float m = (d - maxStep) * 0.4f; h_[i] -= m; h_[i + 1] += m; changed = true; }
            else if (-d > maxStep) { float m = (-d - maxStep) * 0.4f; h_[i] += m; h_[i + 1] -= m; changed = true; }
        }
    if (changed) urgent_ = true;
}

void GroundSnow::Draw(Renderer& r, double now)
{
    if (RebuildDue(now)) {
        maxH_ = 0;
        for (float v : h_) maxH_ = std::max(maxH_, v);
        ComPtr<ID2D1PathGeometry> body = r.NewPath(), ridge = r.NewPath();
        ComPtr<ID2D1GeometrySink> s;
        body->Open(&s);
        s->BeginFigure(Point2F(0, baseY + 1.5f * scale_), D2D1_FIGURE_BEGIN_FILLED);
        for (int i = 0; i < n; i++) s->AddLine(Point2F(i * colW, baseY - h_[i]));
        s->AddLine(Point2F((n - 1) * colW, baseY + 1.5f * scale_));
        s->EndFigure(D2D1_FIGURE_END_CLOSED);
        s->Close();
        s.Reset();
        ridge->Open(&s);
        s->BeginFigure(Point2F(0, baseY - h_[0]), D2D1_FIGURE_BEGIN_HOLLOW);
        for (int i = 1; i < n; i++) s->AddLine(Point2F(i * colW, baseY - h_[i]));
        s->EndFigure(D2D1_FIGURE_END_OPEN);
        s->Close();
        fill_.Reset();
        rim_.Reset();
        r.dc->CreateFilledGeometryRealization(body.Get(), kTol, &fill_);
        r.dc->CreateStrokedGeometryRealization(ridge.Get(), kTol, 1.5f, r.bevelStroke.Get(), &rim_);
        lastBuild_ = now;
        dirty_ = urgent_ = false;
    }
    if (maxH_ < 0.3f || !fill_) return;
    r.groundBrush->SetStartPoint(Point2F(0, baseY));
    r.groundBrush->SetEndPoint(Point2F(0, baseY - std::max(8 * scale_, maxH_)));
    r.dc->DrawGeometryRealization(fill_.Get(), r.groundBrush.Get());
    if (rim_) r.dc->DrawGeometryRealization(rim_.Get(), r.Solid(Rgb(0.86f, 0.91f, 1, 0.9f)));
    (void)width_;
}

// =============================================================================================
// WinCap: the mac WindowCap (granular heightmap anchored to the window's top-left corner)
// =============================================================================================

void WinCap::Init(float scale, float regrowPt, float regrowDuration)
{
    S = scale;
    colW = kCapColPt * S;
    int n = std::max(2, (int)((rect.right - rect.left) / colW) + 1);
    jit.resize(n);
    for (float& j : jit) j = Rand(-0.5f, 0.5f) * S;
    h.assign(n, 0);
    regrowTarget.clear();
    regrowLeft = 0;
    if (regrowPt > 0) {
        std::vector<float> target(n);
        for (int i = 0; i < n; i++) target[i] = Clampf(regrowPt * Rand(0.85f, 1.15f), 1, kCapMaxPt) * S;
        if (regrowDuration > 0) {
            for (int i = 0; i < n; i++) h[i] = std::min(target[i], 0.6f * S);
            regrowTarget = target;
            regrowLeft = regrowDuration;
        } else {
            h = target;
        }
    } else {
        for (float& v : h) v = Rand(kCapStartLo, kCapStartHi) * S;
    }
    // start at rest: both unsupported ends already at the angle of repose (the small eaves)
    auto repose = [this](std::vector<float>& v) {
        int m = (int)v.size();
        for (int i = 0; i < m; i++) v[i] = std::min(v[i], kCapReposePt * S * (float)(std::min(i, m - 1 - i) + 1) * 0.95f);
    };
    repose(h);
    if (!regrowTarget.empty()) repose(regrowTarget);
    urgent = dirty = true;
    awake = true;
}

void WinCap::Resize(const RECT& nr)
{
    float dL = (float)(nr.left - rect.left), dR = (float)(nr.right - rect.right);
    if (std::fabs(dL - dR) > 0.25f) {
        // the snow stays where it is in the world: re-indexed from the new left edge, what is no
        // longer supported pours off, new room starts empty and the pile is pushed into it
        regrowTarget.clear();
        regrowLeft = 0;
        int n = std::max(2, (int)((nr.right - nr.left) / colW) + 1);
        std::vector<float> nh((size_t)n, 0.f);
        for (size_t i = 0; i < h.size(); i++) {
            if (h[i] <= 0) continue;
            float x = i * colW - dL;
            float f = x / colW;
            int a = (int)std::floor(f);
            float u = f - std::floor(f);
            for (int k = 0; k < 2; k++) {
                int j = a + k;
                float part = k == 0 ? 1 - u : u;
                if (part <= 0) continue;
                if (j >= 0 && j < n) nh[j] += h[i] * part;
                else spills.push_back({nr.left + j * colW, h[i] * part * colW});
            }
        }
        h.swap(nh);
        size_t old = jit.size();
        jit.resize((size_t)n);
        for (size_t i = old; i < jit.size(); i++) jit[i] = Rand(-0.5f, 0.5f) * S;
        if (dR > 0.25f) edgeBias = std::min(2.2f, edgeBias + 0.8f);
        else if (dL < -0.25f) edgeBias = std::max(-2.2f, edgeBias - 0.8f);
        awake = true;
        urgent = true;
    }
    rect = nr;
}

bool WinCap::VisibleAt(float x) const
{
    for (size_t k = 0; k + 1 < vis.size(); k += 2)
        if (x >= vis[k] && x <= vis[k + 1]) return true;
    return false;
}

float WinCap::HeightAt(float x) const
{
    if (h.empty() || !std::isfinite(x)) return 0;
    float f = Clampf((x - rect.left) / colW, 0, (float)(h.size() - 1));
    size_t i = (size_t)f;
    size_t j = std::min(h.size() - 1, i + 1);
    return h[i] + (h[j] - h[i]) * (f - i);
}

float WinCap::SurfaceAtRiding(float x) const
{
    if (unsettled || !std::isfinite(x) || x < rect.left || x > rect.right) return NAN;
    return rect.top - HeightAt(x);
}

float WinCap::SurfaceAt(float x) const
{
    if (!VisibleAt(x)) return NAN;
    return SurfaceAtRiding(x);
}

void WinCap::Accumulate(float ratePt, double dt)
{
    if (h.empty()) return;
    budget += ratePt * S * (float)dt * (float)h.size();
    const float lump = 0.5f * S;
    const float w[3] = {0.2f, 0.6f, 0.2f};
    while (budget >= lump) {
        budget -= lump;
        int c = RandInt((int)h.size());
        for (int k = 0; k < 3; k++) {
            int i = c + k - 1;
            if (i < 0 || i >= (int)h.size()) continue;
            float cap = kCapMaxPt * S + jit[i];
            if (h[i] < cap) {
                float add = std::min(cap - h[i], lump * w[k]);
                h[i] += add;
                grown += add;
            }
        }
    }
    if (grown > 0.4f * S * h.size()) { grown = 0; dirty = true; }   // repaint once it visibly grew
}

void WinCap::Deposit(float x, float area)
{
    if (h.empty() || !std::isfinite(x) || !std::isfinite(area) || area <= 0) return;
    int c = (int)Clampf((x - rect.left) / colW, 0, (float)(h.size() - 1));
    float per = area / colW;
    const float w[3] = {0.25f, 0.5f, 0.25f};
    for (int k = 0; k < 3; k++) {
        int i = c + k - 1;
        if (i >= 0 && i < (int)h.size()) h[i] += per * w[k];   // never clipped: the flow spreads it
    }
    urgent = true;
    awake = true;
}

float WinCap::Take(float x, float halfW, float depth)
{
    if (h.empty()) return 0;
    int lo = (int)Clampf((x - halfW - rect.left) / colW, 0, (float)(h.size() - 1));
    int hi = (int)Clampf((x + halfW - rect.left) / colW, 0, (float)(h.size() - 1));
    float removed = 0;
    for (int i = lo; i <= hi; i++) {
        float t = std::min(depth, h[i]);
        h[i] -= t;
        removed += t * colW;
    }
    if (removed > 0) { urgent = true; awake = true; }
    return removed;
}

std::vector<Spill> WinCap::Launch(int pieces, float keepPt)
{
    std::vector<Spill> out;
    if (pieces <= 0 || h.empty()) return out;
    size_t per = std::max<size_t>(1, h.size() / pieces);
    float keep = keepPt * S;
    for (size_t i = 0; i < h.size();) {
        size_t hi = std::min(h.size(), i + per);
        float area = 0;
        for (size_t k = i; k < hi; k++)
            if (h[k] > keep) { area += (h[k] - keep) * colW; h[k] = keep; }
        if (area > 0) out.push_back({rect.left + (i + hi) / 2.f * colW, area});
        i = hi;
    }
    if (!out.empty()) urgent = true;
    return out;
}

bool WinCap::Step(double dt)
{
    int n = (int)h.size();
    if (n < 2 || dt <= 0) return false;
    edgeBias *= (float)std::exp(-dt / 0.15);
    if (std::fabs(edgeBias) < 0.02f) edgeBias = 0;
    float bias = Clampf(lateral + edgeBias, -3, 3);
    if (!awake && bias == 0) return false;
    const float tRight = (kCapReposePt - bias) * S, tLeft = (kCapReposePt + bias) * S;
    int passes = std::min(8, 1 + (int)(std::fabs(bias) * 2.5f)) * std::max(1, (int)std::lround(dt * 60));
    float moved = 0;
    for (int p = 0; p < passes; p++) {
        if (h[0] - tLeft > 0) {
            float m = std::min(h[0], h[0] - std::max(tLeft, 0.f));
            if (m > 0.0005f * S) { h[0] -= m; moved += m; spills.push_back({rect.left - 0.5f * S, m * colW}); }
        }
        if (h[n - 1] - tRight > 0) {
            float m = std::min(h[n - 1], h[n - 1] - std::max(tRight, 0.f));
            if (m > 0.0005f * S) { h[n - 1] -= m; moved += m; spills.push_back({rect.right + 0.5f * S, m * colW}); }
        }
        bool forward = (sweep++ % 2) == 0;
        for (int k = 0; k < n - 1; k++) {
            int i = forward ? k : n - 2 - k;
            float d = h[i] - h[i + 1];
            if (d > tRight) {
                float m = std::min(h[i], (d - tRight) * 0.5f);
                if (m > 0) { h[i] -= m; h[i + 1] += m; moved += m; }
            } else if (-d > tLeft) {
                float m = std::min(h[i + 1], (-d - tLeft) * 0.5f);
                if (m > 0) { h[i + 1] -= m; h[i] += m; moved += m; }
            }
        }
    }
    flowing = moved > 0.002f * S;
    if (flowing) urgent = true;
    awake = moved > 0.0005f * S || bias != 0;
    return moved > 0.0005f * S;
}

void WinCap::Regrow(double dt)
{
    if (regrowLeft <= 0 || regrowTarget.size() != h.size() || dt <= 0) return;
    float k = (float)std::min(1.0, dt / regrowLeft);
    regrowLeft = std::max(0.f, regrowLeft - (float)dt);
    for (size_t i = 0; i < h.size(); i++)
        if (regrowTarget[i] > h[i]) h[i] += (regrowTarget[i] - h[i]) * k;
    urgent = true;
    if (regrowLeft == 0) regrowTarget.clear();
}

float WinCap::AverageH() const
{
    if (h.empty()) return 0;
    float s = 0;
    for (float v : h) s += v;
    return s / h.size();
}

bool WinCap::Empty() const
{
    for (float v : h) if (v >= 0.5f * S) return false;
    return true;
}

// =============================================================================================
// WindowSnow: the visible app windows on the internal display (z-order, popups, decoration)
// =============================================================================================

WinCap* WindowSnow::Find(HWND h)
{
    auto it = map_.find(h);
    return it == map_.end() ? nullptr : it->second.get();
}

const WinCap* WindowSnow::Find(HWND h) const
{
    auto it = map_.find(h);
    return it == map_.end() ? nullptr : it->second.get();
}

bool WindowSnow::PointOverWindow(float x, float y) const
{
    for (const RECT& r : allRects)
        if (x >= r.left && x < r.right && y >= r.top && y < r.bottom) return true;
    return false;
}

bool WindowSnow::Covered(const WinCap& c, float x, float y) const
{
    for (int z = 0; z < c.zAll && z < (int)allRects.size(); z++) {
        const RECT& o = allRects[z];
        if (x >= o.left && x < o.right && y >= o.top && y < o.bottom) return true;
    }
    return false;
}

bool WindowSnow::AnyMoving() const
{
    for (const WinCap* c : caps)
        if (c->unsettled || c->live || c->regrowLeft > 0 || c->flowing) return true;
    return false;
}

std::vector<DWORD> WindowSnow::Pids() const
{
    std::vector<DWORD> p;
    for (const WinCap* c : caps)
        if (std::find(p.begin(), p.end(), c->pid) == p.end()) p.push_back(c->pid);
    return p;
}

void WindowSnow::ReleaseDevice()
{
    for (auto& kv : map_) {
        kv.second->fill.Reset();
        kv.second->ridge.Reset();
        kv.second->urgent = true;
    }
}

namespace {
BOOL CALLBACK CollectProc(HWND h, LPARAM data)
{
    reinterpret_cast<std::vector<HWND>*>(data)->push_back(h);
    return TRUE;
}
struct Cand { HWND h; RECT local; DWORD pid; std::wstring owner; int zAll; bool eligible; };
}  // namespace

bool WindowSnow::Poll(const DisplayInfo& d, float scale, double now, bool trackCaps,
                      const std::function<void(WinCap&)>& onSlide, const std::function<void(WinCap&)>& onGone,
                      const std::function<void(WinCap&)>& onNew)
{
    static std::vector<HWND> order;
    order.clear();
    EnumWindows(CollectProc, reinterpret_cast<LPARAM>(&order));
    const RECT& mon = d.bounds;
    const DWORD ownPid = GetCurrentProcessId();
    const int monW = mon.right - mon.left;
    std::vector<RECT> rects;
    std::vector<HWND> hwnds;
    std::vector<Cand> cands;
    bool changed = false;
    const float minW = 120 * scale, minH = 80 * scale;

    for (HWND hw : order) {
        if (!IsWindowVisible(hw) || IsIconic(hw)) continue;
        RECT wr;
        if (!GetWindowRect(hw, &wr)) continue;
        RECT inter;
        if (!IntersectRect(&inter, &wr, &mon)) continue;          // other monitor: irrelevant
        DWORD pid = 0;
        GetWindowThreadProcessId(hw, &pid);
        if (pid == ownPid) continue;
        wchar_t cls[64];
        ClassOf(hw, cls, 64);
        if (!wcscmp(cls, L"Progman") || !wcscmp(cls, L"WorkerW")) continue;
        LONG ex = GetWindowLongW(hw, GWL_EXSTYLE);
        if ((ex & WS_EX_TRANSPARENT) && (ex & WS_EX_LAYERED)) continue;   // click-through overlays
        if (IsCloaked(hw)) continue;
        RECT sr;
        if (!FrameBounds(hw, &sr) || sr.right <= sr.left || sr.bottom <= sr.top) continue;
        RECT local = {sr.left - mon.left, sr.top - mon.top, sr.right - mon.left, sr.bottom - mon.top};
        Cand c{hw, local, pid, L"", (int)rects.size(), false};
        rects.push_back(local);
        hwnds.push_back(hw);
        if (!trackCaps) continue;
        if (!wcscmp(cls, L"Shell_TrayWnd") || !wcscmp(cls, L"Shell_SecondaryTrayWnd")) continue;
        if ((ex & WS_EX_TOOLWINDOW) && !(ex & WS_EX_APPWINDOW)) continue;
        if ((ex & WS_EX_NOACTIVATE) && !(ex & WS_EX_APPWINDOW)) continue;
        if (sr.right - sr.left < minW || sr.bottom - sr.top < minH) continue;
        if (sr.top <= mon.top + 2 || sr.top >= mon.bottom) continue;      // top edge on this monitor
        if (std::min(sr.right, mon.right) - std::max(sr.left, mon.left) < 40) continue;
        c.eligible = true;
        cands.push_back(c);
    }
    // popups (WindowTracker.splitChildWindows): a window mostly inside a bigger window of the same
    // process with a different top edge (dropdowns, autocomplete, sheets) is never decorated
    std::vector<Cand> kept;
    for (const Cand& w : cands) {
        float area = (float)(w.local.right - w.local.left) * (w.local.bottom - w.local.top);
        bool child = false;
        for (const Cand& o : cands) {
            if (o.h == w.h || o.pid != w.pid) continue;
            float oArea = (float)(o.local.right - o.local.left) * (o.local.bottom - o.local.top);
            if (oArea <= area) continue;
            RECT in;
            if (!IntersectRect(&in, &o.local, &w.local)) continue;
            if ((float)(in.right - in.left) * (in.bottom - in.top) >= 0.9f * area && std::abs(o.local.top - w.local.top) > 1) { child = true; break; }
        }
        if (!child && (int)kept.size() < kMaxWindows) kept.push_back(w);
    }
    // owner + rank of the handle among that exe's windows (persistence of riders and links)
    for (Cand& c : kept) c.owner = ExeNameOf(c.h);
    std::vector<WinCap*> newCaps;
    std::vector<HWND> seen;
    for (const Cand& c : kept) {
        seen.push_back(c.h);
        RECT prev = lastSeen_.count(c.h) ? lastSeen_[c.h] : c.local;
        bool moved = prev.left != c.local.left || prev.top != c.local.top;
        lastSeen_[c.h] = c.local;
        if (!stableSince_.count(c.h) || moved) stableSince_[c.h] = now;
        WinCap* cap = Find(c.h);
        if (!cap) {
            if (now - stableSince_[c.h] < kSettleInDelay) continue;     // settle-in: not decorated yet
            std::unique_ptr<WinCap> nc(new WinCap());
            nc->hwnd = c.h;
            nc->pid = c.pid;
            nc->rect = c.local;
            nc->Init(scale, 0, 0);
            cap = nc.get();
            map_[c.h] = std::move(nc);
            changed = true;
            Diag("stripCreate", c.h, &c.local, L"fresh");
            if (onNew) onNew(*cap);
        } else {
            const RECT old = cap->rect;
            bool liveRecently = NowSec() - cap->lastLiveEvent < 0.3;   // live events use the real clock
            if (!liveRecently && (old.left != c.local.left || old.top != c.local.top)) {
                // fallback mode (no live events for this move): the snow slides off, regrows at rest
                if (!cap->unsettled) {
                    remembered_[c.h] = cap->AverageH();
                    if (onSlide) onSlide(*cap);
                    cap->unsettled = true;
                    Diag("slideOff", c.h, &old, L"poll");
                }
                cap->stillFor = 0;
                cap->restedFor = 0;
                cap->rect = c.local;
                cap->h.assign(cap->h.size(), 0.f);
                cap->fill.Reset();
                changed = true;
            } else if (!liveRecently && old.right - old.left != c.local.right - c.local.left) {
                cap->Resize(c.local);
                changed = true;
            } else if (!liveRecently && old.bottom != c.local.bottom) {
                cap->rect = c.local;                 // height-only change: nothing happens to the snow
            }
            if (cap->unsettled) {
                cap->stillFor = now - stableSince_[c.h];
                if (cap->stillFor >= kSettleDelay) {
                    float keep = std::max(2.5f, remembered_.count(c.h) ? remembered_[c.h] / scale * kKeepFraction : kCapStartLo);
                    remembered_.erase(c.h);
                    cap->rect = c.local;
                    cap->Init(scale, keep, kRegrowDuration);
                    cap->unsettled = false;
                    cap->restedFor = 0;
                    changed = true;
                    Diag("regrow", c.h, &c.local, L"target=" + std::to_wstring((int)keep));
                }
            }
        }
        cap->owner = c.owner;
        cap->zAll = c.zAll;
        newCaps.push_back(cap);
    }
    // owner index: rank of the handle value among that owner's kept windows
    for (WinCap* c : newCaps) {
        int idx = 0;
        for (WinCap* o : newCaps)
            if (o != c && o->owner == c->owner && (uintptr_t)o->hwnd < (uintptr_t)c->hwnd) idx++;
        c->ownerIndex = idx;
    }
    if (rects.size() != allRects.size() || !std::equal(rects.begin(), rects.end(), allRects.begin(),
            [](const RECT& a, const RECT& b) { return a.left == b.left && a.top == b.top && a.right == b.right && a.bottom == b.bottom; }))
        changed = true;
    allRects.swap(rects);
    allHwnds.swap(hwnds);
    for (auto it = map_.begin(); it != map_.end();) {
        if (std::find(seen.begin(), seen.end(), it->first) == seen.end()) {
            WinCap& gone = *it->second;
            Diag("vanish", gone.hwnd, &gone.rect, L"poll");
            if (onGone) onGone(gone);
            remembered_.erase(it->first);
            it = map_.erase(it);
            changed = true;
        } else {
            ++it;
        }
    }
    for (auto it = stableSince_.begin(); it != stableSince_.end();) {
        if (std::find(seen.begin(), seen.end(), it->first) == seen.end()) { lastSeen_.erase(it->first); it = stableSince_.erase(it); }
        else ++it;
    }
    if (newCaps != caps) changed = true;
    caps.swap(newCaps);
    for (WinCap* c : caps) ComputeVisibility(*c, monW);
    if (changed) layoutVersion++;
    return changed;
}

void WindowSnow::Vanish(HWND h, const std::function<void(WinCap&)>& onGone)
{
    auto it = map_.find(h);
    if (it == map_.end()) return;
    if (onGone) onGone(*it->second);
    caps.erase(std::remove(caps.begin(), caps.end(), it->second.get()), caps.end());
    remembered_.erase(h);
    map_.erase(it);
    stableSince_.erase(h);
    lastSeen_.erase(h);
    layoutVersion++;
}

void WindowSnow::Recompute(int monWidth)
{
    for (WinCap* c : caps) ComputeVisibility(*c, monWidth);
}

void WindowSnow::ComputeVisibility(WinCap& c, int monWidth)
{
    std::vector<float> iv;
    float a0 = (float)std::max(0L, c.rect.left), b0 = (float)std::min((LONG)monWidth, c.rect.right);
    if (b0 > a0) { iv.push_back(a0); iv.push_back(b0); }
    LONG y = c.rect.top - (LONG)std::lround(c.S);           // 1 pt above the top edge (mac isVisible)
    std::vector<float> next;
    for (int z = 0; z < c.zAll && z < (int)allRects.size() && !iv.empty(); z++) {
        const RECT& o = allRects[z];
        if (o.top > y || o.bottom <= y) continue;
        next.clear();
        for (size_t k = 0; k + 1 < iv.size(); k += 2) {
            float a = iv[k], b = iv[k + 1];
            if (o.right <= a || o.left >= b) { next.push_back(a); next.push_back(b); continue; }
            if (o.left > a) { next.push_back(a); next.push_back((float)o.left); }
            if (o.right < b) { next.push_back((float)o.right); next.push_back(b); }
        }
        iv.swap(next);
    }
    std::vector<float> vis;
    for (size_t k = 0; k + 1 < iv.size(); k += 2)
        if (iv[k + 1] - iv[k] >= 1) { vis.push_back(iv[k]); vis.push_back(iv[k + 1]); }
    if (vis != c.vis) { c.vis.swap(vis); layoutVersion++; }
}

// =============================================================================================
// Actors
// =============================================================================================

Ball::Ball(float x_, float y_, float r_) : x(x_), y(y_), r(r_)
{
    for (int i = 0; i < 10; i++) {
        spR[i] = Rand(1.6f, 3.f);
        spD[i] = 40 * (float)std::sqrt(Rand01());
        spA[i] = Rand(0, 6.28f);
    }
}

bool SantaObj::Hit(float px, float py, float s) const
{
    if (phase == Waiting || alpha < 0.3f) return false;
    float lx = (px - x) / s * dir, ly = -(py - VisualY(s)) / s;
    // per part (the gaps between the reindeer stay click-through): sleigh + Santa, then each reindeer
    if (lx > -62 && lx < 42 && ly > -6 && ly < 74) return true;
    const float deer[3] = {72, 124, 176};
    for (float dx : deer)
        if (lx > dx - 22 && lx < dx + 36 && ly > -14 && ly < 56) return true;
    return false;
}

float SantaObj::VisualY(float s) const { return y - hopY * s; }

// =============================================================================================
// Scene
// =============================================================================================

Scene::Scene(const DisplayInfo& d, int groundLocalY, Settings& s, const std::vector<SavedGift>* saved, bool allowDefaultGift,
             bool wantDefaultSnowman)
    : S(std::max(0.5f, d.scale)), W(d.bounds.right - d.bounds.left), H(d.bounds.bottom - d.bounds.top), disp_(d), settings_(s)
{
    ground_.reset(new GroundSnow(W, (float)groundLocalY, S));
    const float sz[4] = {2.2f, 3.f, 4.2f, 6.f};
    for (int i = 0; i < 4; i++) flakeSizePx_[i] = std::max(2, (int)std::lround(sz[i] * S));
    int target = settings_.snowFalling ? TargetFlakes() : 0;
    while ((int)flakes_.size() < target) flakes_.push_back(NewFlake(Rand(-20, (float)H)));
    bool hasDefault = false;
    if (saved) {
        // static bottom-up placement so piles come back as saved (WinterScene.restoreGifts)
        std::vector<SavedGift> list = *saved;
        list.erase(std::remove_if(list.begin(), list.end(), [](const SavedGift& g) { return !std::isfinite(g.x) || !std::isfinite(g.y); }), list.end());
        std::sort(list.begin(), list.end(), [](const SavedGift& a, const SavedGift& b) { return a.y > b.y; });
        float hw = 15 * S, hh = 12 * S;
        for (const SavedGift& g : list) {
            float x = g.x < 0 ? -g.x * W : g.x;                    // legacy: fraction of the width
            x = Clampf(x, hw, W - hw);
            float savedBottom = g.y < 0 ? 1e9f : Clampf(g.y, hh, H - hh) + hh;
            float y = std::min(ground_->SurfaceY(x), savedBottom) - hh + 1;
            for (auto& o : gifts_)
                if (std::fabs(o->x - x) < hw * 2 - 6 * S && o->y - hh >= savedBottom - 3 * S) y = std::min(y, o->y - hh - hh);
            GiftObj* made = SpawnGift(x, std::max(y, hh), g.variant, g.isDefault, 0, 0, false);
            if (made && g.isDefault) { hasDefault = true; defaultGift_ = made; }
        }
    }
    if (allowDefaultGift && !hasDefault) {
        float x = W * 0.3f;
        defaultGift_ = SpawnGift(x, ground_->SurfaceY(x) - 12 * S + 1, 0, true, 0, 0, false);
    }
    for (int i = 0; i < 120; i++) StepGifts(1 / 60.f);     // settle restored gifts instantly
    giftsDirty = false;
    wantDefaultSnowman_ = wantDefaultSnowman;
    santa_.timer = 4;
    if (settings_.snowplow) EnsurePlow(true);
}

// ---------------------------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------------------------

void Scene::SetGroundLine(int localY)
{
    if (std::fabs(localY - ground_->baseY) < 1) return;
    bool wasTaskbar = ground_->baseY < H - 1;
    ground_.reset(new GroundSnow(W, (float)localY, S));
    ground_->Clear();             // taskbar hid / reappeared: the snow on it is gone, start fresh
    Logf(L"ground line moved to y=%d (%s)", localY, wasTaskbar ? L"taskbar hidden/moved" : L"taskbar back");
    needsRedraw = true;
}

void Scene::ResetSnow()
{
    ground_->Reset();
    for (WinCap* c : windows_.caps) if (!c->unsettled) c->Init(S, 0, 0);
    needsRedraw = true;
}

void Scene::ClearBalls()
{
    balls_.clear();
    if (held_.kind == KBall) held_ = Ref();
    hover_ = Ref();
    pendingBall_ = nullptr;
    contextBall_ = nullptr;
    ValidateCustomize();
    needsRedraw = true;
}

void Scene::ClearSnowmenAndGifts()
{
    ClearBalls();
    for (auto& g : gifts_) if (g->isDefault) defaultGiftRemoved = true;
    if (defaultGift_ && onDefaultGiftGone) onDefaultGiftGone();
    defaultGift_ = nullptr;
    gifts_.clear();
    held_ = Ref();
    hoverGift_ = nullptr;
    giftsDirty = true;
    needsRedraw = true;
}

bool Scene::AddGift()
{
    if ((int)gifts_.size() >= kMaxGifts) { Toast(L"Gifts are full (30)"); return false; }
    float x = Clampf(W * 0.3f + Rand(-60, 60) * S, 20 * S, W - 20 * S);
    Logf(L"TEST add gift at x=%.0f", x);
    return SpawnGift(x, ground_->SurfaceY(x) - 140 * S, RandInt(4), false, 0, 0, true) != nullptr;
}

void Scene::SettingsChanged()
{
    if (!settings_.santa && santa_.phase != SantaObj::Waiting) {
        if (held_.kind == KSanta) held_ = Ref();
        santa_.fadingOut = true;               // fades out over 0.5 s, then waits
    }
    if (settings_.santa && santa_.phase == SantaObj::Waiting && santa_.timer > 3) santa_.timer = 3;
    EnsurePlow(settings_.snowplow);
    strandSig_.clear();
    needsRedraw = true;
}

void Scene::EnsurePlow(bool on)
{
    if (on && !plow_) {
        plow_.reset(new PlowObj());
        plow_->x = W * 0.15f;
        plow_->y = ground_->SurfaceY(plow_->x) - 60 * S;
        plow_->airborne = true;
    } else if (!on && plow_) {
        if (plow_->drift > 0) ground_->Deposit(plow_->BladeX(S), plow_->drift);
        if (held_.kind == KPlow) held_ = Ref();
        if (hover_.kind == KPlow) hover_ = Ref();
        plow_.reset();
    }
}

std::vector<SavedGift> Scene::SnapshotGifts() const
{
    std::vector<SavedGift> list;
    for (const auto& g : gifts_)
        if (std::isfinite(g->x) && std::isfinite(g->y)) list.push_back({g->x, g->y, g->variant, g == nullptr ? false : g.get() == defaultGift_});
    return list;
}

std::vector<SavedRider> Scene::SnapshotRiders() const
{
    std::vector<SavedRider> out;
    for (const auto& bp : balls_) {
        Ball* b = bp.get();
        if (b->below || !b->restOn) continue;
        const WinCap* c = windows_.Find(b->restOn);
        if (!c || c->owner.empty()) continue;
        SavedRider r;
        r.owner = c->owner;
        r.index = c->ownerIndex;
        r.fx = Clampf((b->x - c->rect.left) / std::max(1.f, (float)(c->rect.right - c->rect.left)), 0, 1);
        for (Ball* x = b; x; x = x->above) r.radiiPt.push_back(x->r / S);
        r.outfit = b->outfit;
        out.push_back(r);
    }
    return out;
}

std::vector<SavedRider> Scene::RestoreRiders(const std::vector<SavedRider>& saved)
{
    std::vector<SavedRider> rest;
    for (const SavedRider& r : saved) {
        WinCap* match = nullptr;
        int n = 0;
        for (WinCap* c : windows_.caps)
            if (c->owner == r.owner && c->ownerIndex == r.index && !c->unsettled) { match = c; n++; }
        if (n != 1 || r.radiiPt.empty() || (int)balls_.size() + (int)r.radiiPt.size() > kMaxBalls) { rest.push_back(r); continue; }
        PlaceSnowman(0, r.radiiPt, r.outfit, match, r.fx);
        Logf(L"TEST rider restored on %s#%d fx=%.2f tiers=%d", r.owner.c_str(), r.index, r.fx, (int)r.radiiPt.size());
    }
    return rest;
}

void Scene::ForceSantaPass()
{
    if (santa_.phase == SantaObj::Waiting) santa_.timer = 0;
}

Ball* Scene::SpawnTestBall(float x, float rPt)
{
    if ((int)balls_.size() >= kMaxBalls) return nullptr;
    float r = rPt * S;
    std::unique_ptr<Ball> b(new Ball(Clampf(x, r, W - r), ground_->SurfaceY(x) - r * 0.9f, r));
    Ball* raw = b.get();
    balls_.push_back(std::move(b));
    needsRedraw = true;
    return raw;
}

std::wstring Scene::StateLine() const
{
    wchar_t b[256];
    std::wstring s;
    swprintf_s(b, L"santa phase=%d x=%.0f y=%.0f dir=%.0f; ", santa_.phase, santa_.x, santa_.VisualY(S), santa_.dir);
    s += b;
    s += L"balls=";
    for (const auto& bp : balls_) {
        swprintf_s(b, L"[%.0f,%.0f r=%.1f below=%d above=%d on=%d outfit=%S] ", bp->x, bp->y, bp->r, bp->below ? 1 : 0, bp->above ? 1 : 0,
                   bp->restOn ? 1 : 0, bp->outfit.Key().c_str());
        s += b;
    }
    s += L"; gifts=";
    for (const auto& g : gifts_) {
        swprintf_s(b, L"[%.0f,%.0f lvl=%d] ", g->x, g->y, g->stackLevel);
        s += b;
    }
    if (plow_) { swprintf_s(b, L"; plow=%.0f,%.0f beacon=%d", plow_->x, plow_->y, plow_->beacon ? 1 : 0); s += b; }
    swprintf_s(b, L"; caps=%d links=%d strands=%d grains=%d clumps=%d", (int)windows_.caps.size(), (int)userLinks_.size(),
               (int)strands_.size(), (int)grains_.size(), (int)clumps_.size());
    s += b;
    for (const WinCap* c : windows_.caps) {
        swprintf_s(b, L" cap[%s#%d %ld,%ld %ldx avg=%.1fpt vis=%d live=%d unsettled=%d]", c->owner.c_str(), c->ownerIndex, c->rect.left,
                   c->rect.top, c->rect.right - c->rect.left, c->AverageH() / S, (int)c->vis.size() / 2, c->live ? 1 : 0, c->unsettled ? 1 : 0);
        s += b;
    }
    return s;
}

// ---------------------------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------------------------

void Scene::PollWindows(double dt)
{
    (void)dt;
    bool changed = windows_.Poll(disp_, S, time_, TrackWindows(), [this](WinCap& c) { SlideOff(c); },
                                 [this](WinCap& c) { WindowGone(c); }, [this](WinCap& c) { WindowNew(c); });
    if (changed) needsRedraw = true;
}

void Scene::OnMoveSizeStart(HWND h)
{
    WinCap* c = windows_.Find(h);
    if (c) Diag("grab", h, &c->rect, settings_.liveTracking ? L"live" : L"fallback");
}

void Scene::OnMoveSizeEnd(HWND h) { (void)h; }

/// A live window position (EVENT_OBJECT_LOCATIONCHANGE): everything on it follows exactly; the
/// granular snow leans toward the trailing side; flicks shed soft clumps; a violent shake throws
/// the riders off. (WinterScene.liveWindowFrame / stepLive / applyLive.)
void Scene::OnWindowLive(HWND h, const RECT& screen)
{
    if (!settings_.liveTracking || !TrackWindows()) return;
    WinCap* c = windows_.Find(h);
    if (!c || c->unsettled) return;
    RECT nr = {screen.left - disp_.bounds.left, screen.top - disp_.bounds.top, screen.right - disp_.bounds.left, screen.bottom - disp_.bounds.top};
    RECT old = c->rect;
    if (nr.left == old.left && nr.top == old.top && nr.right == old.right && nr.bottom == old.bottom) return;
    double now = NowSec();                                  // event time (the frame clock would bunch events)
    double gap = now - c->lastLiveEvent;
    float dx = (float)(nr.left - old.left), dy = (float)(nr.top - old.top);
    // teleport (snap / maximize / restore): snap everything, no velocity
    bool teleport = std::hypot(dx, dy) > 600 * S || (gap > 0.2 && std::hypot(dx, dy) > 120 * S);
    if (old.right - old.left != nr.right - nr.left) c->Resize(nr); else c->rect = nr;
    c->lastLiveEvent = now;
    c->live = true;
    liveDragging_ = true;
    if (h != liveHwnd_) { liveHwnd_ = h; liveVx_ = liveVy_ = livePrevVx_ = livePrevVy_ = 0; liveT_ = now; }
    float edt = (float)std::max(1.0 / 240, std::min(0.1, now - liveT_));
    liveT_ = now;
    float vx = 0, vy = 0, ax = 0, ay = 0;
    if (!teleport && gap < 0.2) {
        float rawx = dx / edt, rawy = dy / edt;
        float kv = 1 - std::exp(-edt / 0.06f);
        vx = liveVx_ + (rawx - liveVx_) * kv;
        vy = liveVy_ + (rawy - liveVy_) * kv;
        ax = (vx - liveVx_) / edt;
        ay = (vy - liveVy_) / edt;
    }
    bool reversal = vx * liveVx_ < 0 && std::fabs(vx) > 150 * S && std::fabs(liveVx_) > 150 * S;
    if (reversal) lastReversal_ = now;                    // shaking = a fast direction reversal in the last 0.35 s
    bool shaking = now - lastReversal_ < 0.35;
    livePrevVx_ = liveVx_;
    livePrevVy_ = liveVy_;
    liveVx_ = vx;
    liveVy_ = vy;
    float accelPt = std::hypot(ax, ay) / S;
    // riders: thrown off on a hard shake, otherwise carried along (with a wobble)
    if (!teleport && shaking && accelPt > kRiderFallAccelPt) {
        for (auto& bp : balls_) {
            Ball* b = bp.get();
            if (b->below || b->held || b->restOn != h) continue;
            b->restOn = nullptr;
            b->vy = -320 * S;
            b->vx = Clampf(-ax * 0.004f, -420 * S, 420 * S);
            b->tiltVel += ax > 0 ? -2.f : 2.f;
            Logf(L"TEST rider thrown off (accel %.0f pt/s^2)", accelPt);
        }
        for (auto& g : gifts_)
            if (g->restOn == h) { g->restOn = nullptr; g->vx = Clampf(vx * 0.5f, -1200 * S, 1200 * S); g->vy = std::min(0.f, vy * 0.5f); }
    } else {
        for (auto& bp : balls_) {
            Ball* b = bp.get();
            if (b->below || b->restOn != h) continue;
            if (!b->held) b->x += dx;
            b->y += dy;
            if (!teleport) b->tiltVel = Clampf(b->tiltVel + Clampf(ax / S * 0.000006f, -0.4f, 0.4f), -2.5f, 2.5f);
        }
        for (auto& g : gifts_)
            if (!g->held && g->restOn == h) { g->x += dx; g->y += dy; }
    }
    if (!teleport && settings_.dragSnowSlides) {
        float g = (-ax - vx * 5) / S;               // >= ~1100 pt/s flat snow starts to slide
        c->lateral = Clampf(g / 5000, -2.6f, 2.6f);
    }
    // flick (hard brake while moving fast): a few soft clumps, <= 3/s
    float prevSpeedPt = std::hypot(livePrevVx_, livePrevVy_) / S;
    bool braking = ax * livePrevVx_ + ay * livePrevVy_ < 0;
    if (!teleport && braking && accelPt > kShedAccelPt * 2 && prevSpeedPt > 300 && now - lastShed_ >= kShedCooldown) {
        lastShed_ = now;
        ShedClumps(*c, ax, ay);
    }
    windows_.Recompute(W);
    needsRedraw = true;
    if (DiagEnabled()) {
        wchar_t note[96];
        swprintf_s(note, L"vx=%.0f vy=%.0f a=%.0f lateral=%.2f", vx / S, vy / S, accelPt, c->lateral);
        Diag("liveFrame", h, &nr, note);
    }
}

void Scene::OnWindowVanished(HWND h, const wchar_t* why)
{
    if (!windows_.Find(h)) return;
    Diag("vanish", h, nullptr, why);
    windows_.Vanish(h, [this](WinCap& c) { WindowGone(c); });
    needsRedraw = true;
}

/// Fallback slide-off: the strip breaks into soft clumps that slide off opposite to the motion,
/// tumble and fall; riders fall; lights on it drop until the window rests again.
void Scene::SlideOff(WinCap& c)
{
    for (auto& b : balls_) if (b->restOn == c.hwnd) b->restOn = nullptr;
    for (auto& g : gifts_) if (g->restOn == c.hwnd) g->restOn = nullptr;
    if (!CapsActive() || c.Empty()) return;
    float width = (float)(c.rect.right - c.rect.left);
    int pieces = std::max(4, std::min(8, (int)(width / (70 * S))));
    float dir = RandInt(2) ? 1.f : -1.f;
    std::vector<Spill> parts = c.Launch(pieces, 0);
    for (size_t k = 0; k < parts.size(); k++) {
        float spread = (float)k / std::max<size_t>(parts.size() - 1, 1) - 0.5f;
        float vx = dir * Rand(50, 130) * S + spread * 60 * S, vy = -Rand(10, 70) * S;
        // a slice breaks into 2-4 clumps (5-13 pt) plus a little powder
        int n = std::max(2, std::min(4, (int)(parts[k].area / (120 * S * S)) + 1));
        for (int i = 0; i < n && clumps_.size() < kMaxClumps; i++) {
            float area = parts[k].area / n;
            float r = Clampf(std::sqrt(area * 0.6f) * 0.9f / S, 5, 13) * S / 2;
            clumps_.push_back({parts[k].x + Rand(-15, 15) * S, c.rect.top - c.AverageH() - 3 * S, vx + Rand(-40, 40) * S, vy, r, area, 0, c.hwnd});
        }
        Poof(parts[k].x, (float)c.rect.top - 2 * S, 2);
    }
    capsChanged_ = true;
}

void Scene::WindowNew(WinCap& c)
{
    (void)c;
    strandSig_.clear();
}

/// A window closed / minimized / hidden: its strip and lights vanish now, riders are parked
/// (restored when that window is listed again), gifts on it go quietly onto the snow below.
void Scene::WindowGone(WinCap& c)
{
    ParkRiders(c);
    for (auto& g : gifts_)
        if (g->restOn == c.hwnd) { g->restOn = nullptr; g->vx = g->vy = 0; g->y = ground_->SurfaceY(g->x) - 12 * S; }
    if (liveHwnd_ == c.hwnd) { liveHwnd_ = nullptr; liveDragging_ = false; }
    for (auto it = userLinks_.begin(); it != userLinks_.end();)
        it = it->Involves(c.hwnd) ? userLinks_.erase(it) : it + 1;
    strandSig_.clear();
}

void Scene::ParkRiders(WinCap& c)
{
    std::vector<Ball*> doomed;
    for (auto& bp : balls_) {
        Ball* r = bp.get();
        if (r->below || r->restOn != c.hwnd || r->held) continue;
        if (!c.owner.empty() && onRiderParked) {
            SavedRider sr;
            sr.owner = c.owner;
            sr.index = c.ownerIndex;
            sr.fx = Clampf((r->x - c.rect.left) / std::max(1.f, (float)(c.rect.right - c.rect.left)), 0, 1);
            for (Ball* x = r; x; x = x->above) sr.radiiPt.push_back(x->r / S);
            sr.outfit = r->outfit;
            onRiderParked(sr);
            Logf(L"TEST rider parked from %s#%d", c.owner.c_str(), c.ownerIndex);
        }
        for (Ball* x = r; x; x = x->above) doomed.push_back(x);
    }
    for (Ball* b : doomed) RemoveBallPtr(b);
    if (!doomed.empty()) ValidateCustomize();
}

// ---------------------------------------------------------------------------------------------
// Simulation
// ---------------------------------------------------------------------------------------------

int Scene::TargetFlakes() const
{
    const int base[3] = {70, 150, 300};
    float area = (W / S) * (H / S) / (1440.f * 900.f);
    return std::min(450, (int)(base[std::max(0, std::min(2, settings_.intensity))] * std::max(0.5f, area)));
}

Flake Scene::NewFlake(float y)
{
    Flake f;
    int size = RandInt(100) < 45 ? 0 : (RandInt(100) < 60 ? 1 : (RandInt(100) < 70 ? 2 : 3));
    int alpha = std::min(2, size == 0 ? RandInt(2) : 1 + RandInt(2));
    f.sprite = size * 3 + alpha;
    f.size = flakeSizePx_[size];
    f.x = Rand(-20, W + 20.f);
    f.y = y;
    f.vy = (28 + 14 * size + Rand(0, 18)) * S;
    f.phase = Rand(0, 6.28f);
    f.sway = Rand(6, 18) * S;
    return f;
}

/// Highest walkable surface at x not above `belowY` (y-down: surface y >= belowY - 4 pt): ground
/// snow or a visible window cap. `riding`: the window an object already rests on keeps supporting
/// it even where a front window covers that spot (WinterScene.support).
Scene::SupportHit Scene::Support(float x, float belowY, HWND riding)
{
    SupportHit best{ground_->SurfaceY(x), nullptr};
    if (!CapsActive()) return best;
    for (WinCap* c : windows_.caps) {
        float s = c->hwnd == riding ? c->SurfaceAtRiding(x) : c->SurfaceAt(x);
        if (std::isnan(s) || s < belowY - 4 * S || s >= best.y) continue;
        best = {s, c};
    }
    return best;
}

void Scene::Update(double dt)
{
    time_ += dt;
    float fdt = (float)dt;
    wind_ = (float)(std::sin(time_ * 0.13) * 10 + std::sin(time_ * 0.37) * 4) * S;
    anyMoving_ = false;
    capsChanged_ = false;

    // accumulation (Intensity.accumulation; caps at 1/4 of it): very slow, independent of flakes
    if (settings_.snowFalling) {
        float rate = kAccumulation[std::max(0, std::min(2, settings_.intensity))];
        static float groundBudget = 0;
        groundBudget += rate * S * fdt * ground_->n;
        float lump = 0.6f * S;
        while (groundBudget >= lump) { groundBudget -= lump; ground_->AddFlake(Rand(0, (float)W), lump); }
        if (CapsActive())
            for (WinCap* c : windows_.caps) if (!c->unsettled) c->Accumulate(rate * kCapGrowth, dt);
    }
    UpdateFlakes(fdt);
    relaxTimer_ += dt;
    if (relaxTimer_ >= 0.1) { relaxTimer_ = 0; ground_->Relax(); }

    // live drags end when events stop: a fast drag flings its snow, a fast stop sheds clumps
    liveDragging_ = false;
    for (WinCap* c : windows_.caps) {
        if (!c->live) continue;
        double wall = NowSec();
        if (wall - c->lastLiveEvent > kDragEndAfter) {
            float prevSpeedPt = std::hypot(liveVx_, liveVy_) / S;
            if (c->hwnd == liveHwnd_ && wall - lastShed_ >= kShedCooldown) {
                if (settings_.dragSnowSlides && prevSpeedPt > kFlingSpeedPt) {
                    std::vector<Spill> pieces = c->Launch(24, 0.4f);
                    Diag("fling", c->hwnd, &c->rect, L"pieces=" + std::to_wstring(pieces.size()));
                    Logf(L"TEST fling: %d pieces at %.0f pt/s", (int)pieces.size(), prevSpeedPt);
                    float spread = (c->rect.right - c->rect.left) / 24.f;
                    float vx = Clampf(liveVx_ * 0.5f, -1300 * S, 1300 * S), vy = Clampf(liveVy_ * 0.5f, -500 * S, 400 * S) - 160 * S;
                    for (const Spill& p : pieces) {
                        // small snowballs (3-8 pt) flying off, the rest as a sand spray
                        if (clumps_.size() < kMaxClumps && p.area > 20 * S * S) {
                            float r = Rand(1.5f, 4.f) * S;
                            float a = std::min(p.area * 0.5f, kPi * r * r);
                            clumps_.push_back({p.x, c->rect.top - 2 * S, vx + Rand(-80, 80) * S, vy + Rand(-60, 60) * S, r, a, 0, c->hwnd});
                            SpawnGrains(p.area - a, p.x, c->rect.top - 2 * S, spread, vx, vy, 160 * S, 120 * S, c->hwnd);
                        } else {
                            SpawnGrains(p.area, p.x, c->rect.top - 2 * S, spread, vx, vy, 160 * S, 120 * S, c->hwnd);
                        }
                    }
                } else if (prevSpeedPt > kShedStopSpeedPt) {
                    ShedClumps(*c, -liveVx_ / 0.05f, -liveVy_ / 0.05f);
                }
                lastShed_ = wall;
            }
            c->live = false;
            c->lateral = 0;
            if (c->hwnd == liveHwnd_) liveHwnd_ = nullptr;
            windows_.Recompute(W);
            strandSig_.clear();
            Diag("liveEnd", c->hwnd, &c->rect, L"");
        } else {
            liveDragging_ = true;
        }
    }
    // granular caps: regrow, flow, spills -> sand grains (bank per side as on the mac)
    for (WinCap* c : windows_.caps) {
        c->restedFor += dt;
        c->Regrow(dt);
        c->cooldown -= dt;
        if (c->Step(dt)) capsChanged_ = true;
        if (!c->spills.empty()) {
            float midx = (c->rect.left + c->rect.right) / 2.f;
            float left = 0, right = 0, l0 = 1e9f, l1 = -1e9f, r0 = 1e9f, r1 = -1e9f;
            for (const Spill& s : c->spills) {
                if (s.x < midx) { left += s.area; l0 = std::min(l0, s.x); l1 = std::max(l1, s.x); }
                else { right += s.area; r0 = std::min(r0, s.x); r1 = std::max(r1, s.x); }
            }
            c->spills.clear();
            float vx = c->live ? liveVx_ * 0.8f : 0, vy = c->live ? liveVy_ * 0.5f : 0;
            if (left > 0) SpawnGrains(left, (l0 + l1) / 2 - 0.8f * S, (float)c->rect.top - S, std::max(2 * S, l1 - l0 + 2 * S), vx - 8 * S, vy + 30 * S, 12 * S, 60 * S, c->hwnd);
            if (right > 0) SpawnGrains(right, (r0 + r1) / 2 + 0.8f * S, (float)c->rect.top - S, std::max(2 * S, r1 - r0 + 2 * S), vx + 8 * S, vy + 30 * S, 12 * S, 60 * S, c->hwnd);
        }
    }
    UpdateGrains(fdt);
    UpdateClumps(fdt);
    UpdateParticles(fdt);
    UpdateBalls(fdt);
    StepGifts(fdt);
    UpdateSanta(dt);
    UpdatePlow(fdt);
    PlaceDefaultSnowman();
    for (size_t i = texts_.size(); i-- > 0;) {
        texts_[i].life -= fdt;
        if (!texts_[i].emoji) texts_[i].y += texts_[i].vy * fdt;
        if (texts_[i].life <= 0) texts_.erase(texts_.begin() + i);
    }
    if (GetActivity() != ActIdle) needsRedraw = true;
}

void Scene::UpdateFlakes(float dt)
{
    int target = settings_.snowFalling ? TargetFlakes() : 0;
    for (size_t i = flakes_.size(); i-- > 0;) {
        Flake& f = flakes_[i];
        float oy = f.y;
        f.phase += dt * 1.3f;
        f.y += f.vy * dt;
        f.x += (wind_ + std::cos(f.phase) * f.sway) * dt;
        bool gone = false;
        if (CapsActive())
            for (WinCap* c : windows_.caps) {
                if (f.x < c->rect.left || f.x > c->rect.right) continue;
                float sy = c->SurfaceAt(f.x);
                if (!std::isnan(sy) && oy <= sy && f.y >= sy) { gone = true; break; }
            }
        if (!gone && f.y >= ground_->SurfaceY(f.x)) gone = true;
        if (!gone && (f.y > H + 10 || f.x < -60 || f.x > W + 60)) gone = true;
        if (gone) {
            if ((int)flakes_.size() > target) { flakes_[i] = flakes_.back(); flakes_.pop_back(); continue; }
            f = NewFlake(Rand(-30 * S, -4));
        }
    }
    int spawn = 0;
    while ((int)flakes_.size() < target && spawn++ < 8) flakes_.push_back(NewFlake(Rand(-30 * S, -4)));
}

/// Turns `area` px^2 of snow into falling grains around (x, y) (budgeted; heavier grains when the
/// budget is tight, and as a last resort the snow lands directly below). (spawnGrains)
void Scene::SpawnGrains(float area, float x, float y, float spreadX, float vx, float vy, float jx, float jy, HWND source)
{
    if (area <= 0 || !std::isfinite(x) || !std::isfinite(y)) return;
    size_t limit = powerSaving ? kMaxGrains / 2 : kMaxGrains;
    int freeSlots = (int)limit - (int)grains_.size();
    if (freeSlots <= 0) {
        SupportHit s = Support(x, y);
        if (s.cap) s.cap->Deposit(x, area); else ground_->Deposit(x, area);
        return;
    }
    int want = std::max(1, (int)(area / (kGrainAreaPt * S * S)));
    int count = std::min(want, std::min(std::max(1, freeSlots / 4), freeSlots));
    float each = area / count;
    for (int i = 0; i < count; i++)
        grains_.push_back({x + Rand(-0.5f, 0.5f) * spreadX, y + Rand(-0.5f, 2) * S, vx + Rand(-0.5f, 0.5f) * jx, vy + Rand(-0.5f, 0.5f) * jy,
                           each, 0, source, Rand(1.2f, 2.4f) * S});
}

void Scene::UpdateGrains(float dt)
{
    if (grains_.empty()) return;
    size_t keep = 0;
    for (size_t i = 0; i < grains_.size(); i++) {
        Grain g = grains_[i];
        g.age += dt;
        float oldY = g.y;
        g.vy += kGravityPt * S * 0.75f * dt;
        g.vx *= std::exp(-1.2f * dt);
        g.x += g.vx * dt;
        g.y += g.vy * dt;
        if (!std::isfinite(g.x) || !std::isfinite(g.y) || g.age > 8) continue;
        if (g.x < 1 || g.x > W - 1) { g.x = Clampf(g.x, 1, W - 1.f); g.vx = -g.vx * 0.2f; }
        float landY = ground_->SurfaceY(g.x);
        WinCap* landCap = nullptr;
        if (CapsActive())
            for (WinCap* c : windows_.caps) {
                if (c->hwnd == g.source && g.age < 0.25f) continue;
                float s = c->SurfaceAt(g.x);
                if (!std::isnan(s) && s >= oldY - 0.5f * S && s < landY) { landY = s; landCap = c; }
            }
        if (g.y >= landY) {
            if (landCap) landCap->Deposit(g.x, g.area); else ground_->Deposit(g.x, g.area);
            continue;
        }
        grains_[keep++] = g;
    }
    grains_.resize(keep);
}

void Scene::UpdateClumps(float dt)
{
    if (clumps_.empty()) return;
    size_t keep = 0;
    for (size_t i = 0; i < clumps_.size(); i++) {
        Clump c = clumps_[i];
        c.age += dt;
        float oldY = c.y;
        c.vy += kGravityPt * S * dt;
        c.x += c.vx * dt;
        c.y += c.vy * dt;
        if (!std::isfinite(c.x) || !std::isfinite(c.y) || c.age > 6) continue;
        if (c.x < 2 * S || c.x > W - 2 * S) { c.x = Clampf(c.x, 2 * S, W - 2 * S); c.vx = -c.vx * 0.25f; }
        float landY = ground_->SurfaceY(c.x);
        WinCap* landCap = nullptr;
        if (CapsActive())
            for (WinCap* w : windows_.caps) {
                if (w->hwnd == c.source) continue;
                float s = w->SurfaceAt(c.x);
                if (!std::isnan(s) && s >= oldY - S && s < landY) { landY = s; landCap = w; }
            }
        if (c.y + c.r >= landY) {
            if (c.vy > 150 * S && c.age < 5.9f) {          // one small bounce before settling
                c.vy = -c.vy * 0.28f;
                c.vx *= 0.6f;
                c.y = landY - c.r - 0.5f * S;
                c.age = 5.9f;
                clumps_[keep++] = c;
                continue;
            }
            if (landCap) landCap->Deposit(c.x, c.area); else ground_->Deposit(c.x, c.area);
            continue;
        }
        clumps_[keep++] = c;
    }
    clumps_.resize(keep);
}

/// Live drag flick / stop: 1-3 soft round clumps (7-12 pt) from the edge the snow slides off.
void Scene::ShedClumps(WinCap& c, float ax, float ay)
{
    if (c.Empty()) return;
    float am = std::hypot(ax, ay) / S;
    int count = am > kShedAccelPt * 3 ? 3 : (am > kShedAccelPt * 1.8f ? 2 : 1);
    bool fromRight = ax < 0;
    for (int i = 0; i < count && clumps_.size() < kMaxClumps; i++) {
        float x = fromRight ? c.rect.right - Rand(4, 60) * S : c.rect.left + Rand(4, 60) * S;
        float top = std::isnan(c.SurfaceAtRiding(x)) ? (float)c.rect.top : c.SurfaceAtRiding(x);
        float d = Rand(7, 12) * S;
        float area = d * d * 0.6f;
        c.Take(x, d / 2, area / std::max(d, 1.f));
        clumps_.push_back({x, top - d * 0.3f, Clampf(-ax * 0.004f, -140 * S, 140 * S) + Rand(-25, 25) * S, -Rand(50, 130) * S, d / 2, area, 0, c.hwnd});
    }
    Diag("shed", c.hwnd, &c.rect, L"clumps=" + std::to_wstring(count));
    Logf(L"TEST shed %d clumps", count);
}

void Scene::UpdateParticles(float dt)
{
    size_t keep = 0;
    for (size_t i = 0; i < particles_.size(); i++) {
        Particle p = particles_[i];
        p.life -= dt;
        if (p.life <= 0) continue;
        p.vy += p.gravity * dt;
        p.x += p.vx * dt;
        p.y += p.vy * dt;
        p.rot += p.spin * dt;
        particles_[keep++] = p;
    }
    particles_.resize(keep);
}

void Scene::Poof(float x, float y, int n)
{
    for (int i = 0; i < n; i++) {
        Particle p{};
        p.x = x + Rand(-6, 6) * S;
        p.y = y + Rand(-3, 3) * S;
        p.vx = Rand(-20, 20) * S / 0.6f;
        p.vy = Rand(20, 60) * S / 0.6f;
        p.life = p.maxLife = 0.6f;
        p.size = 5 * S;
        p.kind = 0;
        particles_.push_back(p);
    }
}

void Scene::Confetti(float x, float y)
{
    const D2D1_COLOR_F cols[6] = {Rgb(1, 0.25f, 0.3f), Rgb(1, 0.8f, 0.2f), Rgb(0.3f, 0.8f, 0.4f), Rgb(0.35f, 0.6f, 1), Rgb(0.85f, 0.45f, 1), Rgb(1, 1, 1)};
    for (int i = 0; i < 28; i++) {
        Particle p{};
        float a = Rand(0, 6.28f), dist = Rand(40, 110) * S;
        p.x = x;
        p.y = y;
        p.vx = std::cos(a) * dist / 0.6f;
        p.vy = (-std::sin(a) * dist - 30 * S) / 0.6f;
        p.gravity = 140 * S;
        p.life = p.maxLife = 0.9f;
        p.size = 4 * S;
        p.rot = Rand(0, 6.28f);
        p.spin = Rand(-6, 6) / 0.9f;
        p.color = cols[RandInt(6)];
        p.kind = 1;
        particles_.push_back(p);
    }
}

// ---------------------------------------------------------------------------------------------
// Snowballs (WinterScene MARK: Snowballs)
// ---------------------------------------------------------------------------------------------

void Scene::DragBall(Ball* b, float tx, float ty)
{
    float r = b->r;
    float nx = Clampf(tx, r, W - r);
    SupportHit sup = Support(nx, ty + r * 0.9f - 6 * S);
    float rest = sup.y - r * 0.9f;
    if (ty >= rest - 6 * S) {
        float dx = nx - b->x;
        if (!b->above && dx != 0) {
            b->spin += dx / b->r;
            if (b->r < kBallMaxPt * S) {
                int steps = std::max(1, (int)(std::fabs(dx) / (4 * S)));
                float stepDx = dx / steps, removed = 0;
                for (int k = 1; k <= steps; k++) {
                    float x = b->x + stepDx * k;
                    float hw = std::max(4 * S, b->r * 0.45f), depth = std::fabs(stepDx) * 0.15f;
                    if (sup.cap) removed += sup.cap->Take(x, hw, depth) * 0.2f;   // a thin window line: modest growth
                    else removed += ground_->Take(x, hw, depth);
                }
                if (removed > 0) b->r = Clampf(std::sqrt((kPi * b->r * b->r + removed * 2.5f) / kPi), 4 * S, kBallMaxPt * S);
            }
        }
        float x = Clampf(nx, b->r, W - b->r);
        SupportHit s = Support(x, ty + r * 0.9f - 6 * S);
        b->x = x;
        b->y = s.y - b->r * 0.9f;
        b->restOn = s.cap ? s.cap->hwnd : nullptr;
    } else {
        b->x = nx;
        b->y = std::max(ty, r);
        b->restOn = nullptr;
    }
    b->vy = 0;
}

void Scene::UpdateBalls(float dt)
{
    std::vector<Ball*> roots;
    for (auto& bp : balls_) if (!bp->below) roots.push_back(bp.get());
    for (Ball* b : roots) {
        if (b->tilt != 0 || b->tiltVel != 0) {                // rider wobble: damped spring (~2 Hz)
            b->tiltVel += (-80 * b->tilt - 6 * b->tiltVel) * dt;
            b->tilt = Clampf(b->tilt + b->tiltVel * dt, -0.5f, 0.5f);
            if (!std::isfinite(b->tilt) || !std::isfinite(b->tiltVel)) { b->tilt = 0; b->tiltVel = 0; }
            if (std::fabs(b->tilt) < 0.001f && std::fabs(b->tiltVel) < 0.01f) { b->tilt = 0; b->tiltVel = 0; }
            anyMoving_ = true;
        }
    }
    for (Ball* b : roots) {
        if (b->held) continue;
        float ox = b->x, oy = b->y;
        float oldBottom = b->y + b->r * 0.9f;
        b->vy += kBallGravityPt * S * dt;
        float py = b->y + b->vy * dt;
        float px = b->x;
        if (b->vx != 0) { px += b->vx * dt; if (!std::isfinite(b->vx)) b->vx = 0; }
        px = Clampf(px, b->r, W - b->r);
        SupportHit sup = Support(px, oldBottom - S, b->vx == 0 ? b->restOn : nullptr);
        float rest = sup.y - b->r * 0.9f;
        if (py >= rest) {
            py = rest;
            b->vy = 0;
            b->vx *= std::pow(0.001f, dt);                 // rolls to a stop after landing
            if (std::fabs(b->vx) < 5 * S) b->vx = 0;
            HWND was = b->restOn;
            b->restOn = sup.cap ? sup.cap->hwnd : nullptr;
            if (b->restOn && b->restOn != was) Logf(L"TEST ball resting on window %s", sup.cap->owner.c_str());
        } else {
            b->restOn = nullptr;
        }
        b->x = px;
        b->y = py;
        if (py < rest - 0.5f * S) LandOnStacks(b);
        // hidden where a front window covers the spot it rests on (WinterScene.updateRiderOcclusion)
        const WinCap* c = b->restOn ? windows_.Find(b->restOn) : nullptr;
        b->hidden = c && windows_.Covered(*c, b->x, b->y + b->r * 0.9f - S);
        if (std::fabs(b->x - ox) > 0.05f || std::fabs(b->y - oy) > 0.05f) anyMoving_ = true;
    }
    // side-by-side separation of resting roots
    for (size_t i = 0; i + 1 < roots.size(); i++)
        for (size_t j = i + 1; j < roots.size(); j++) {
            Ball* a = roots[i];
            Ball* b = roots[j];
            if (a->vy != 0 || b->vy != 0) continue;
            float dx = b->x - a->x, minD = (a->r + b->r) * 0.92f;
            if (std::fabs(dx) >= minD || std::fabs(b->y - a->y) >= (a->r + b->r) * 0.9f) continue;
            float s = dx >= 0 ? 1.f : -1.f, overlap = minD - std::fabs(dx);
            float wa = a->held ? 0.f : (b->held ? 1.f : 0.5f), wb = b->held ? 0.f : (a->held ? 1.f : 0.5f);
            a->x = Clampf(a->x - s * overlap * wa, a->r, W - a->r);
            b->x = Clampf(b->x + s * overlap * wb, b->r, W - b->r);
        }
    // layout the stacks (tilt leans the whole snowman)
    for (Ball* root : roots) {
        float tilt = std::isfinite(root->tilt) ? Clampf(root->tilt, -0.5f, 0.5f) : 0.f;
        for (Ball* b = root; b->above; b = b->above) {
            float d = b->r * 0.8f + b->above->r * 0.8f;
            b->above->x = b->x - std::sin(tilt) * d;
            b->above->y = b->y - std::cos(tilt) * d;
            b->above->vy = 0;
            b->above->hidden = root->hidden;
            b->above->restOn = nullptr;
        }
    }
}

/// A falling ball either snaps onto a compatible stack top or slides off it.
void Scene::LandOnStacks(Ball* b)
{
    int count = b->StackCount();
    for (auto& tp : balls_) {
        Ball* t = tp.get();
        if (t->above) continue;
        Ball* tr = t->Root();
        if (tr == b || tr->held) continue;
        float dx = b->x - t->x, dy = t->y - b->y;            // dy > 0: b above t
        float d = std::hypot(dx, dy);
        if (d >= b->r + t->r || dy <= 0) continue;
        if (count + tr->StackCount() <= 3 && b->r <= t->r * 1.1f && std::fabs(dx) < t->r * 0.8f) {
            t->above = b;
            b->below = t;
            b->vy = 0;
            b->restOn = nullptr;
            Logf(L"TEST stacked: %d tiers", tr->StackCount());
            ValidateCustomize();
            return;
        }
        float nx = d > 0.01f ? dx / d : 1, ny = d > 0.01f ? dy / d : 0;
        b->x = t->x + nx * (b->r + t->r);
        b->y = t->y - ny * (b->r + t->r);
        if (std::fabs(nx) < 0.2f) b->x += (dx >= 0 ? 1 : -1) * 2 * S;
        b->vy *= 0.3f;
    }
}

std::vector<Ball*> Scene::PlaceSnowman(float x, const std::vector<float>& radiiPt, const Outfit& o, WinCap* on, float fx)
{
    std::vector<Ball*> made;
    if (radiiPt.empty()) return made;
    if (on) x = Clampf(on->rect.left + Clampf(fx, 0.05f, 0.95f) * (on->rect.right - on->rect.left), 10 * S, W - 10 * S);
    for (float rp : radiiPt) {
        float r = Clampf(rp, 4, kBallMaxPt) * S;
        std::unique_ptr<Ball> b(new Ball(x, 0, r));
        Ball* raw = b.get();
        if (!made.empty()) {
            made.back()->above = raw;
            raw->below = made.back();
            raw->y = made.back()->y - made.back()->r * 0.8f - r * 0.8f;
        } else {
            raw->y = on ? std::max(r, (float)on->rect.top - on->HeightAt(x) - r * 0.9f) : ground_->SurfaceY(x) - r * 0.9f;
            raw->restOn = on ? on->hwnd : nullptr;
            raw->outfit = o;
        }
        balls_.push_back(std::move(b));
        made.push_back(raw);
    }
    needsRedraw = true;
    return made;
}

/// First run / no saved window snowmen: a small snowman in a Santa hat on the front-most big
/// window's top edge (else on the taskbar snow). (placeDefaultSnowmanIfNeeded)
void Scene::PlaceDefaultSnowman()
{
    if (!wantDefaultSnowman_ || time_ < kSettleInDelay + 0.3 + 0.5) return;
    wantDefaultSnowman_ = false;
    Outfit o;
    o.hat = 1;          // Santa hat
    o.face = 0;
    o.clothes = 1;      // red scarf
    const std::vector<float> radii = {11, 8, 6};
    WinCap* best = nullptr;
    if (CapsActive())
        for (WinCap* c : windows_.caps) {
            if (c->unsettled || (c->rect.right - c->rect.left) < 400 * S || (c->rect.bottom - c->rect.top) < 250 * S || c->rect.top < 50 * S) continue;
            best = c;
            break;
        }
    if (best) PlaceSnowman(0, radii, o, best, 0.72f);
    else PlaceSnowman(W * 0.2f, radii, o, nullptr, 0);
    Logf(L"TEST default snowman placed %s", best ? (L"on " + best->owner).c_str() : L"on the ground");
}

void Scene::RemoveBallPtr(Ball* b)
{
    if (hover_.kind == KBall && hover_.p == b) hover_ = Ref();
    if (held_.kind == KBall && held_.p == b) held_ = Ref();
    if (pendingBall_ == b) pendingBall_ = nullptr;
    if (contextBall_ == b) contextBall_ = nullptr;
    for (size_t i = 0; i < balls_.size(); i++)
        if (balls_[i].get() == b) { balls_.erase(balls_.begin() + i); return; }
}

/// Removes `b` and every ball above it (a bottom ball => the whole snowman), with a poof; the
/// snow goes back into the ground. (deleteBalls)
void Scene::DeleteBalls(Ball* b)
{
    std::vector<Ball*> victims;
    for (Ball* x = b; x; x = x->above) victims.push_back(x);
    if (b->below) b->below->above = nullptr;
    b->below = nullptr;
    for (Ball* v : victims) {
        Poof(v->x, v->y, 5);
        ground_->Deposit(v->x, kPi * v->r * v->r * 0.5f);
        RemoveBallPtr(v);
    }
    hover_ = Ref();
    ValidateCustomize();
    needsRedraw = true;
    Logf(L"TEST deleted %d ball(s)", (int)victims.size());
}

void Scene::DeleteBallFromMenu()
{
    if (!contextBall_) return;
    Ball* b = contextBall_;
    contextBall_ = nullptr;
    DeleteBalls(b);
}

// ---------------------------------------------------------------------------------------------
// Gifts (WinterScene MARK: Gifts)
// ---------------------------------------------------------------------------------------------

GiftObj* Scene::SpawnGift(float x, float y, int variant, bool isDefault, float vx, float vy, bool spin)
{
    // at the cap nothing new appears (Santa just stops dropping); old gifts are never evicted
    if ((int)gifts_.size() >= kMaxGifts || !std::isfinite(x) || !std::isfinite(y)) return nullptr;
    std::unique_ptr<GiftObj> g(new GiftObj());
    float hw = 15 * S, hh = 12 * S;
    g->x = Clampf(x, hw, W - hw);
    g->y = Clampf(y, hh, H - hh);
    g->vx = vx;
    g->vy = vy;
    g->angVel = spin ? Rand(-2, 2) : 0;
    g->variant = ((variant % 4) + 4) % 4;
    g->isDefault = isDefault;
    GiftObj* raw = g.get();
    gifts_.push_back(std::move(g));
    giftsDirty = true;
    needsRedraw = true;
    return raw;
}

/// Gift physics: gravity onto snow / caps / other gifts (box stacking, max 3), horizontal-only
/// separation, off-centre or over-tall stacks topple sideways. (updateGifts)
void Scene::StepGifts(float dt)
{
    const float hw = 15 * S, hh = 12 * S, g0 = kGravityPt * S;
    std::vector<GiftObj*> order;
    for (auto& gp : gifts_) order.push_back(gp.get());
    for (GiftObj* g : order) if (!std::isfinite(g->x) || !std::isfinite(g->y)) { g->x = W / 2.f; g->y = 12 * S; g->vx = g->vy = 0; }
    std::sort(order.begin(), order.end(), [](GiftObj* a, GiftObj* b) { return a->y > b->y; });   // bottom-up
    for (GiftObj* g : order) {
        if (g->held) continue;
        float ox = g->x, oy = g->y;
        float oldBottom = g->y + hh;
        g->vy += g0 * dt;
        float px = g->x + g->vx * dt, py = g->y + g->vy * dt;
        if (px < hw) { px = hw; g->vx = std::fabs(g->vx) * 0.6f; }
        if (px > W - hw) { px = W - hw; g->vx = -std::fabs(g->vx) * 0.6f; }
        if (py < hh) { py = hh; g->vy = std::fabs(g->vy) * 0.5f; }
        SupportHit sup = Support(px, oldBottom - S, g->restOn);
        float floor = sup.y - hh + 1;
        GiftObj* under = nullptr;
        for (GiftObj* o : order) {
            if (o == g || o->held || std::fabs(o->x - px) >= hw * 2 - 6 * S) continue;
            float top = o->y - hh;
            if (top < oldBottom - 0.5f * S) continue;          // only boxes below (no climbing)
            if (top - hh < floor) { floor = top - hh; under = o; }
        }
        bool grounded = false;
        g->restOn = nullptr;
        if (py >= floor) {
            py = floor;
            g->restOn = under == nullptr && sup.cap ? sup.cap->hwnd : nullptr;
            if (g->vy > 90 * S) {
                g->vy = -g->vy * 0.38f;
                g->vx *= 0.8f;
                g->angVel *= -0.5f;
            } else {
                g->vy = 0;
                grounded = true;
            }
        }
        g->stackLevel = under ? under->stackLevel + 1 : 0;
        if (grounded) {
            g->vx *= std::pow(0.02f, dt);
            if (std::fabs(g->vx) < 0.5f * S) g->vx = 0;
            g->rot += (0 - g->rot) * std::min(1.f, 12 * dt);
            g->angVel = 0;
            if (under) {
                float off = px - under->x;
                bool centred = false, left = false, right = false;
                for (GiftObj* o : order) {
                    if (o == g || o->held || std::fabs(o->x - px) >= hw * 2 - 6 * S) continue;
                    float d = (o->y - hh - hh) - py;
                    if (d < -0.5f * S || d > 3 * S) continue;
                    float dx = o->x - px;
                    if (std::fabs(dx) <= hw * 0.8f) centred = true;
                    if (dx < 0) left = true; else right = true;
                }
                bool unstable = !centred && !(left && right);
                if (g->stackLevel >= 3 || unstable) {
                    float dir = off > 0 ? 1.f : -1.f;
                    if (g->stackLevel >= 3) dir = px < W / 2.f ? -1.f : 1.f;
                    px = Clampf(px + dir * 90 * S * dt, hw, W - hw);
                }
            }
        } else {
            g->rot += g->angVel * dt;
        }
        g->x = px;
        g->y = py;
        const WinCap* c = g->restOn ? windows_.Find(g->restOn) : nullptr;
        g->hidden = c && windows_.Covered(*c, g->x, g->y);
        if (std::fabs(g->x - ox) > 0.05f || std::fabs(g->y - oy) > 0.05f) anyMoving_ = true;
    }
    for (size_t i = 0; i + 1 < order.size(); i++)
        for (size_t j = i + 1; j < order.size(); j++) {
            GiftObj* a = order[i];
            GiftObj* b = order[j];
            if (std::fabs(b->y - a->y) >= hh * 2 - 6 * S) continue;
            float dx = b->x - a->x, overlap = hw * 2 - std::fabs(dx);
            if (overlap <= 0 || (a->held && b->held)) continue;
            float s = dx >= 0 ? 1.f : -1.f;
            float wa = a->held ? 0.f : (b->held ? 1.f : 0.5f), wb = 1 - wa;
            a->x = Clampf(a->x - s * overlap * wa, hw, W - hw);
            b->x = Clampf(b->x + s * overlap * wb, hw, W - hw);
            float rv = (b->vx - a->vx) * s;
            if (rv < 0) {
                if (wa > 0) a->vx += rv * s * 0.5f * (wb > 0 ? 1 : 2);
                if (wb > 0) b->vx -= rv * s * 0.5f * (wa > 0 ? 1 : 2);
            }
        }
}

void Scene::RemoveGiftPtr(GiftObj* g)
{
    if (g == defaultGift_) {
        defaultGift_ = nullptr;
        defaultGiftRemoved = true;
        if (onDefaultGiftGone) onDefaultGiftGone();
    }
    if (hoverGift_ == g) hoverGift_ = nullptr;
    if (held_.kind == KGift && held_.p == g) held_ = Ref();
    for (size_t i = 0; i < gifts_.size(); i++)
        if (gifts_[i].get() == g) { gifts_.erase(gifts_.begin() + i); break; }
    giftsDirty = true;
    needsRedraw = true;
}

void Scene::DeleteGift(GiftObj* g)
{
    float x = g->x, y = g->y;
    RemoveGiftPtr(g);
    for (int i = 0; i < 8; i++) {
        Particle p{};
        float a = Rand(0, 6.28f);
        p.x = x;
        p.y = y;
        p.vx = std::cos(a) * 26 * S / 0.35f;
        p.vy = std::sin(a) * 26 * S / 0.35f;
        p.life = p.maxLife = 0.35f;
        p.size = 10 * S;
        particles_.push_back(p);
    }
    Logf(L"TEST gift deleted");
}

void Scene::OpenGift(GiftObj* g)
{
    float x = g->x, y = g->y;
    RemoveGiftPtr(g);
    Confetti(x, y);
    static const wchar_t* surprises[] = {L"\U0001F36A", L"⭐", L"\U0001F9F8", L"\U0001F36C", L"❄", L"\U0001F36D",
                                         L"\U0001F384", L"\U0001F9E6", L"☕", L"\U0001F98C"};
    FloatText sparkle{L"✨", x, y, 0, 0.5f, 0.5f, Rgb(1, 1, 1), true, 30 * 0.3f * S, 30 * 1.5f * S};
    texts_.push_back(sparkle);
    FloatText gift{surprises[RandInt(10)], x, y, -55 * S / 0.6f, 2.2f, 2.2f, Rgb(1, 1, 1), true, 34 * 0.2f * S, 34 * 1.25f * S};
    texts_.push_back(gift);
    needsRedraw = true;
    Logf(L"TEST gift opened");
}

// ---------------------------------------------------------------------------------------------
// Santa (Santa.swift state machine)
// ---------------------------------------------------------------------------------------------

void Scene::StartSantaPass()
{
    SantaObj& s = santa_;
    s.dir = RandInt(2) == 0 ? 1.f : -1.f;
    s.cruiseY = H * Rand(0.15f, 0.4f);                       // y-up 60-85% of the height
    s.x = s.dir > 0 ? -210 * S : W + 210 * S;
    s.y = s.cruiseY;
    s.velocity = 150 * S;
    s.willLand = Rand01() < 0.5;
    float touchdown = s.dir > 0 ? W * 0.2f : W * 0.8f;
    s.descendStartX = touchdown - s.dir * 320 * S;
    s.dropPlanned = Rand01() < kSantaGiftDropChance;
    s.dropX = Rand(W * 0.15f, W * 0.85f);
    s.phase = SantaObj::Flying;
    s.alpha = 1;
    s.fadingOut = false;
    s.tilt = 0;
    Logf(L"santa takes off (dir %+.0f, landing %d, gift drop planned %d)", s.dir, s.willLand ? 1 : 0, s.dropPlanned ? 1 : 0);
}

void Scene::Celebrate()
{
    santa_.hopT = 0;
    santa_.waveT = 0;
    santa_.blinkT = 0;
}

void Scene::UpdateSanta(double dt)
{
    SantaObj& s = santa_;
    float fdt = (float)dt;
    s.clock += dt;
    for (int i = 0; i < 16; i++)
        if (s.spLife[i] > 0) { s.spLife[i] -= fdt; s.spY[i] += 10 * S * fdt; }
    if (s.hopT >= 0) {                                       // happy hop: up 7 pt in 0.14 s, down in 0.22 s
        s.hopT += dt;
        double t = s.hopT;
        s.hopY = t < 0.14 ? (float)(7 * (t / 0.14)) : (t < 0.36 ? (float)(7 * (1 - (t - 0.14) / 0.22)) : 0.f);
        if (t > 0.5) { s.hopT = -1; s.hopY = 0; }
    }
    if (s.waveT >= 0) { s.waveT += dt; if (s.waveT > 1.2) s.waveT = -1; }
    if (s.blinkT >= 0) { s.blinkT += dt; if (s.blinkT > (s.hopT >= 0 ? 0.5 : 0.13)) s.blinkT = -1; }
    if (s.bubbleT >= 0) { s.bubbleT += dt; if (s.bubbleT > 2.35) s.bubbleT = -1; }
    s.nextBlink -= dt;
    if (s.nextBlink <= 0) { s.blinkT = 0; s.nextBlink = Rand(1, 7); }
    if (s.fadingOut) {
        s.alpha -= fdt / 0.5f;
        if (s.alpha <= 0) { s.alpha = 0; s.fadingOut = false; s.phase = SantaObj::Waiting; s.timer = 3; }
    }

    auto surfaceAt = [this](float x, float y) { return Support(x, y).y; };
    bool sliding = s.phase == SantaObj::Sliding;
    switch (s.phase) {
    case SantaObj::Waiting:
        if (!settings_.santa) return;
        s.timer -= dt;
        if (s.timer <= 0) StartSantaPass();
        return;
    case SantaObj::Held:
        s.gallop += dt * 16;
        return;
    case SantaObj::Flying:
        s.x += s.dir * s.velocity * fdt;
        s.y = s.cruiseY - (float)std::sin(s.clock * 1.8) * 14 * S;
        if (s.willLand && (s.x - s.descendStartX) * s.dir >= 0) {
            s.willLand = false;
            s.phase = SantaObj::Descending;
            s.startX = s.x;
            s.startY = s.y;
        }
        s.nextWave -= dt;
        if (s.nextWave <= 0) { s.waveT = 0; s.nextWave = Rand(3, 19); }
        break;
    case SantaObj::Descending: {
        s.x += s.dir * s.velocity * fdt;
        float p = std::min(1.f, std::fabs(s.x - s.startX) / (320 * S));
        s.y = s.startY + (surfaceAt(s.x, s.startY) - s.startY) * Smooth(p);
        if (p >= 1) { s.phase = SantaObj::Sliding; s.slideTimer = Rand(2.5f, 4.5f); Logf(L"TEST santa landed and slides"); }
        break;
    }
    case SantaObj::Sliding: {
        s.velocity = std::max(50 * S, s.velocity - 35 * S * fdt);
        s.x += s.dir * s.velocity * fdt;
        float ground = surfaceAt(s.x, s.y - 4 * S);
        if (ground > s.y + 12 * S) { s.phase = SantaObj::Ascending; s.startX = s.x; s.startY = s.y; }   // slid off a window edge
        else s.y = ground;
        s.slideTimer -= dt;
        bool nearEdge = s.dir > 0 ? s.x + 200 * S > W : s.x - 200 * S < 0;
        if (s.phase == SantaObj::Sliding && (s.slideTimer <= 0 || nearEdge)) {
            s.phase = SantaObj::Ascending;
            s.startX = s.x;
            s.startY = s.y;
            Logf(L"TEST santa takes off again");
        }
        break;
    }
    case SantaObj::Ascending: {
        s.velocity = std::min(150 * S, s.velocity + 60 * S * fdt);
        s.x += s.dir * s.velocity * fdt;
        float p = std::min(1.f, std::fabs(s.x - s.startX) / (380 * S));
        s.y = s.startY + (H * 0.28f - s.startY) * Smooth(p);
        if (p >= 1) { s.phase = SantaObj::Flying; s.cruiseY = s.y + (float)std::sin(s.clock * 1.8) * 14 * S; }
        break;
    }
    default: break;
    }
    if (s.phase == SantaObj::Waiting) return;
    s.gallop += dt * (sliding ? 7 : 11);
    if (s.dropPlanned && (s.x - s.dropX) * s.dir >= 0) {
        s.dropPlanned = false;
        Celebrate();
        SpawnGift(s.x - s.dir * 30 * S, s.y - 30 * S, RandInt(4), false, s.dir * 90 * S, -30 * S, true);
        Logf(L"TEST santa auto-dropped a gift");
    }
    float tiltTarget = s.phase == SantaObj::Ascending ? 0.06f : (s.phase == SantaObj::Descending ? -0.05f : 0.f);
    s.tilt += (tiltTarget * s.dir - s.tilt) * std::min(1.f, 4 * fdt);
    s.spTimer -= dt;
    if (s.spTimer <= 0) {
        s.spTimer = sliding ? 0.2 : 0.07;
        int k = s.spNext++ % 16;
        s.spX[k] = s.x - s.dir * (54 + Rand(-4, 4)) * S;
        s.spY[k] = s.VisualY(S) - Rand(4, 30) * S;
        s.spLife[k] = Rand(0.6f, 0.95f);
        s.spTint[k] = k % 3 == 0 ? 0 : 1;
    }
    bool off = s.dir > 0 ? s.x - 70 * S > W : s.x + 70 * S < 0;
    if (off) { s.phase = SantaObj::Waiting; s.timer = Rand(20, 45); s.bubbleT = -1; }
}

// ---------------------------------------------------------------------------------------------
// Toy snowplow
// ---------------------------------------------------------------------------------------------

void Scene::UpdatePlow(float dt)
{
    PlowObj* p = plow_.get();
    if (!p) return;
    if (p->honkT >= 0) { p->honkT += dt; if (p->honkT > 0.3) p->honkT = -1; }
    if (p->held) return;
    float surf = ground_->SurfaceY(p->x);
    if (p->airborne) {
        p->vy += kGravityPt * S * dt;
        p->y += p->vy * dt;
        if (p->y >= surf) { p->y = surf; p->vy = 0; p->airborne = false; }
        return;
    }
    p->x += p->dir * 26 * S * dt;                           // WinterScene.plowSpeed
    float blade = p->BladeX(S);
    p->drift += ground_->Scrape(blade, ground_->colW * 0.6f, 2 * S);
    float target = ground_->SurfaceY(p->x);
    p->y += (target - p->y) * std::min(1.f, dt * 10);
    bool edge = (p->dir > 0 && blade > W - 8 * S) || (p->dir < 0 && blade < 8 * S);
    if (p->DriftFull(S) || edge) {
        float L = std::max(4.f, p->DriftHeight(S) * 2.2f);
        if (p->drift > 0) ground_->Deposit(Clampf(blade + p->dir * L * 0.4f, 0, W - 1.f), p->drift);
        p->drift = 0;
        p->dir = -p->dir;
    }
}

void Scene::AddText(const std::wstring& t, float x, float y, D2D1_COLOR_F c)
{
    texts_.push_back({t, x, y, -24 * S, 1.3f, 1.3f, c, false, 0, 0});
    needsRedraw = true;
}

Activity Scene::GetActivity() const
{
    if (held_.kind != KNone || linkDrag_ || liveDragging_) return ActHigh;
    if (santa_.phase != SantaObj::Waiting || !flakes_.empty() || !grains_.empty() || !clumps_.empty() || !particles_.empty() ||
        !texts_.empty() || anyMoving_ || plow_ || lightEdit_)
        return ActNormal;
    for (int i = 0; i < 16; i++) if (santa_.spLife[i] > 0) return ActNormal;
    if (hover_.kind == KBall && !BallDeleteVisible()) return ActNormal;
    if (ground_->Urgent() || capsChanged_ || windows_.AnyMoving()) return ActLow;
    if (LightsActive() && !strands_.empty()) return ActLow;     // twinkle
    return ActIdle;
}

bool Scene::RedrawDue() const
{
    if (ground_->RebuildDue(time_)) return true;
    if (!CapsActive()) return false;
    for (const WinCap* c : windows_.caps)
        if (!c->unsettled && !c->vis.empty() && !c->Empty() && c->RebuildDue()) return true;
    return false;
}

// ---------------------------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------------------------

void Scene::ReleaseDevice()
{
    ground_->ReleaseDevice();
    windows_.ReleaseDevice();
    wires_.Reset();
    wiresKey_.clear();
    for (auto& b : balls_) { b->cache.Reset(); b->cacheKey.clear(); }
    bulbList_.ReleaseDevice();
    sparkleList_.ReleaseDevice();
    flakeList_.ReleaseDevice();
    grainList_.ReleaseDevice();
    dotList_.ReleaseDevice();
    particleList_.ReleaseDevice();
}

void Scene::Render(Renderer& r)
{
    ID2D1DeviceContext1* dc = r.dc.Get();
    ground_->Draw(r, time_);
    if (CapsActive()) DrawCaps(r);
    if (LightsActive()) DrawLights(r);
    if (plow_) DrawPlow(r);
    dc->SetTransform(Matrix3x2F::Identity());
    for (auto& g : gifts_) if (!g->hidden) DrawGift(r, *g);
    for (auto& b : balls_) {
        if (b->below) continue;
        int tiers = b->StackCount(), k = 0;
        for (Ball* x = b.get(); x; x = x->above) DrawBall(r, *x, tiers, k++);
    }
    dc->SetTransform(Matrix3x2F::Identity());
    DrawDeleteButtons(r);
    DrawSanta(r);
    dc->SetTransform(Matrix3x2F::Identity());
    DrawGrains(r);
    flakeList_.Clear();
    for (const Flake& f : flakes_) flakeList_.Add(r.flakes[f.sprite], f.x, f.y);
    flakeList_.Draw(r);
    DrawParticles(r);
    if (lightEdit_) DrawLightEdit(r);
    for (const FloatText& t : texts_) DrawOutlinedText(r, t);
    needsRedraw = false;
}

/// The cap strip (WindowCap.render): lightly smoothed heightmap as a quadratic curve, bluish
/// underside -> white top gradient, 0.8 pt highlight, faint shadow just below the edge, clipped to
/// the parts no front window covers. Geometry is cap-local, so a dragged window only translates it.
void Scene::DrawCaps(Renderer& r)
{
    ID2D1DeviceContext1* dc = r.dc.Get();
    int budget = 2;                                         // at most 2 re-tessellations per frame
    for (size_t ci = windows_.caps.size(); ci-- > 0;) {
        WinCap& c = *windows_.caps[ci];
        if (c.unsettled || c.vis.empty() || c.h.empty()) continue;
        if (c.Empty()) { c.fill.Reset(); c.ridge.Reset(); continue; }
        float w = (float)(c.rect.right - c.rect.left);
        if (c.RebuildDue() && (budget > 0 || !c.fill)) {
            budget--;
            int n = (int)c.h.size();
            std::vector<float> sm((size_t)n);
            for (int i = 0; i < n; i++) {
                float sum = 0, ws = 0;
                for (int j = std::max(0, i - 2); j <= std::min(n - 1, i + 2); j++) {
                    float wt = (float)(3 - std::abs(i - j));
                    sum += c.h[j] * wt;
                    ws += wt;
                }
                sm[i] = sum / std::max(ws, 1.f);
            }
            std::vector<D2D1_POINT_2F> pts;
            for (int i = 0; i < n; i += 2) pts.push_back(Point2F(std::min(i * c.colW, w), -sm[i]));
            if ((n - 1) % 2 != 0) pts.push_back(Point2F(w, -sm[n - 1]));
            ComPtr<ID2D1PathGeometry> body = r.NewPath(), ridge = r.NewPath();
            ComPtr<ID2D1GeometrySink> s, rs;
            body->Open(&s);
            ridge->Open(&rs);
            s->BeginFigure(Point2F(0, 0.6f * S), D2D1_FIGURE_BEGIN_FILLED);
            s->AddLine(Point2F(0, pts[0].y));
            rs->BeginFigure(Point2F(0, pts[0].y), D2D1_FIGURE_BEGIN_HOLLOW);
            for (size_t k = 0; k + 1 < pts.size(); k++) {
                D2D1_POINT_2F mid = Point2F((pts[k].x + pts[k + 1].x) / 2, (pts[k].y + pts[k + 1].y) / 2);
                s->AddQuadraticBezier(D2D1::QuadraticBezierSegment(pts[k], mid));
                rs->AddQuadraticBezier(D2D1::QuadraticBezierSegment(pts[k], mid));
            }
            s->AddLine(Point2F(w, pts.back().y));
            rs->AddLine(Point2F(w, pts.back().y));
            s->AddLine(Point2F(w, 0.6f * S));
            s->EndFigure(D2D1_FIGURE_END_CLOSED);
            rs->EndFigure(D2D1_FIGURE_END_OPEN);
            s->Close();
            rs->Close();
            c.fill.Reset();
            c.ridge.Reset();
            dc->CreateFilledGeometryRealization(body.Get(), kTol, &c.fill);
            dc->CreateStrokedGeometryRealization(ridge.Get(), kTol, 0.8f * S, r.roundStroke.Get(), &c.ridge);
            c.builtAvg = c.AverageH();
            c.urgent = c.dirty = false;
            c.cooldown = 2.0;
        }
        if (!c.fill) continue;
        float top = (float)c.rect.top, left = (float)c.rect.left;
        for (size_t k = 0; k + 1 < c.vis.size(); k += 2) {
            dc->SetTransform(Matrix3x2F::Identity());
            dc->PushAxisAlignedClip(D2D1::RectF(c.vis[k], top - 30 * S, c.vis[k + 1], top + 4 * S), D2D1_ANTIALIAS_MODE_ALIASED);
            dc->SetTransform(Matrix3x2F::Translation(left, top));
            // faint soft shadow just below the line
            r.capShadowBrush->SetStartPoint(Point2F(0, 0));
            r.capShadowBrush->SetEndPoint(Point2F(0, 3 * S));
            dc->FillRectangle(D2D1::RectF(-1, 0, w + 1, 3 * S), r.capShadowBrush.Get());
            r.capBrush->SetStartPoint(Point2F(0, 0.6f * S));
            r.capBrush->SetEndPoint(Point2F(0, -std::max(2 * S, c.builtAvg)));
            dc->DrawGeometryRealization(c.fill.Get(), r.capBrush.Get());
            if (c.ridge) dc->DrawGeometryRealization(c.ridge.Get(), r.Solid(Rgb(1, 1, 1, 0.95f)));
            dc->SetTransform(Matrix3x2F::Identity());
            dc->PopAxisAlignedClip();
        }
    }
}

void Scene::DrawGrains(Renderer& r)
{
    ID2D1DeviceContext1* dc = r.dc.Get();
    if (!grains_.empty()) {
        grainList_.Clear();
        float base = r.grain.w - 2;
        for (const Grain& g : grains_) grainList_.Add(r.grain, g.x, g.y, g.size / std::max(1.f, base));
        grainList_.Draw(r);
    }
    for (const Clump& c : clumps_) {
        r.ballBrush->SetCenter(Point2F(c.x, c.y));
        r.ballBrush->SetRadiusX(c.r);
        r.ballBrush->SetRadiusY(c.r);
        r.ballBrush->SetGradientOriginOffset(Point2F(-c.r * 0.25f, -c.r * 0.3f));
        dc->FillEllipse(D2D1::Ellipse(Point2F(c.x, c.y), c.r, c.r), r.ballBrush.Get());
    }
}

void Scene::DrawParticles(Renderer& r)
{
    if (particles_.empty()) return;
    ID2D1DeviceContext1* dc = r.dc.Get();
    particleList_.Clear();
    for (const Particle& p : particles_) {
        float a = p.life / p.maxLife;
        if (p.kind == 0) {
            float grow = 1 + (1 - a);                       // puffs grow to 2x while fading
            float base = r.puff.w - 2;
            dc->SetTransform(Matrix3x2F::Identity());
            float sz = p.size * grow;
            dc->DrawBitmap(r.atlas.Get(), D2D1::RectF(p.x - sz / 2, p.y - sz / 2, p.x + sz / 2, p.y + sz / 2), a * 0.8f,
                           D2D1_BITMAP_INTERPOLATION_MODE_LINEAR,
                           D2D1::RectF((float)r.puff.src.left, (float)r.puff.src.top, (float)r.puff.src.right, (float)r.puff.src.bottom));
            (void)base;
        } else {
            float alpha = p.maxLife - p.life < 0.5f ? 1.f : a / (0.4f / p.maxLife);
            dc->SetTransform(Matrix3x2F::Rotation(p.rot * 180 / kPi) * Matrix3x2F::Translation(p.x, p.y));
            dc->FillRectangle(D2D1::RectF(-p.size / 2, -p.size * 0.875f, p.size / 2, p.size * 0.875f), r.Solid(WithA(p.color, std::min(1.f, alpha))));
        }
    }
    dc->SetTransform(Matrix3x2F::Identity());
}

void Scene::DrawGift(Renderer& r, const GiftObj& g)
{
    ID2D1DeviceContext1* dc = r.dc.Get();
    if (std::fabs(g.rot) > 0.002f) {
        dc->SetTransform(Matrix3x2F::Rotation(-g.rot * 180 / kPi, Point2F(g.x, g.y)));
        r.DrawSprite(r.gifts[g.variant], g.x, g.y);
        dc->SetTransform(Matrix3x2F::Identity());
    } else {
        r.DrawSprite(r.gifts[g.variant], g.x, g.y);
    }
}

void Scene::PrepareCaches(Renderer& r)
{
    ID2D1DeviceContext1* dc = r.dc.Get();
    for (auto& rootp : balls_) {
        if (rootp->below) continue;
        int tiers = rootp->StackCount(), k = 0;
        for (Ball* bp = rootp.get(); bp; bp = bp->above, k++) {
            Ball& b = *bp;
            char key[96];
            sprintf_s(key, "%.2f|%s|%d|%d|%.2f", std::round(b.r * 4) / 4, rootp->outfit.Key().c_str(), tiers, k, std::round(b.spin * 20) / 20);
            if (b.cache && b.cacheKey == key) continue;
            b.cacheKey = key;
            b.cache.Reset();
            // decor reaches 130 ball units sideways / above and 105 below the centre
            float u = b.r / 50;
            int w = (int)std::ceil(270 * u) + 4, h = (int)std::ceil(240 * u) + 4;
            float ox = 135 * u + 2, oy = 132 * u + 2;
            D2D1_BITMAP_PROPERTIES1 bpp = D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET,
                D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
            if (FAILED(dc->CreateBitmap(D2D1::SizeU((UINT32)w, (UINT32)h), nullptr, 0, &bpp, &b.cache))) continue;
            dc->SetTarget(b.cache.Get());
            dc->BeginDraw();
            dc->Clear(Rgb(0, 0, 0, 0));
            Matrix3x2F m = Matrix3x2F::Scale(u, -u) * Matrix3x2F::Translation(ox, oy);
            DrawBallDecor(dc, rootp->outfit, tiers, k, true, m);
            dc->SetTransform(Matrix3x2F::Identity());
            r.ballBrush->SetCenter(Point2F(ox, oy));
            r.ballBrush->SetRadiusX(b.r);
            r.ballBrush->SetRadiusY(b.r);
            r.ballBrush->SetGradientOriginOffset(Point2F(-b.r * 0.25f, -b.r * 0.3f));
            dc->FillEllipse(D2D1::Ellipse(Point2F(ox, oy), b.r, b.r), r.ballBrush.Get());
            dc->DrawEllipse(D2D1::Ellipse(Point2F(ox, oy), b.r - 0.5f, b.r - 0.5f), r.Solid(Rgb(0.78f, 0.84f, 0.95f, 0.45f)), std::max(1.f, b.r / 64));
            if (b.r > 6) {
                dc->SetTransform(m);
                ID2D1SolidColorBrush* sp = r.Solid(Rgb(0.76f, 0.83f, 0.94f, 0.55f));
                for (int i = 0; i < 10; i++) {
                    float a = b.spA[i] - b.spin;
                    dc->FillEllipse(D2D1::Ellipse(Point2F(b.spD[i] * std::cos(a), b.spD[i] * std::sin(a)), b.spR[i], b.spR[i]), sp);
                }
                dc->SetTransform(Matrix3x2F::Identity());
            }
            DrawBallDecor(dc, rootp->outfit, tiers, k, false, m);
            dc->SetTransform(Matrix3x2F::Identity());
            dc->EndDraw();
            b.cacheOx = ox;
            b.cacheOy = oy;
            b.cacheW = (float)w;
            b.cacheH = (float)h;
        }
    }
    dc->SetTarget(r.target.Get());
}

void Scene::DrawBall(Renderer& r, Ball& b, int tiers, int tierIndex)
{
    (void)tiers;
    (void)tierIndex;
    if (b.hidden || !b.cache) return;
    ID2D1DeviceContext1* dc = r.dc.Get();
    float tilt = b.Root()->tilt;
    dc->SetTransform(Matrix3x2F::Rotation(-tilt * 180 / kPi, Point2F(b.x, b.y)));
    if (!b.below && b.r > 4)
        dc->FillEllipse(D2D1::Ellipse(Point2F(b.x, b.y + b.r * 0.94f), b.r * 0.86f, b.r * 0.14f), r.Solid(Rgb(0.2f, 0.3f, 0.5f, 0.16f)));
    float l = b.x - b.cacheOx, t = b.y - b.cacheOy;
    dc->DrawBitmap(b.cache.Get(), D2D1::RectF(l, t, l + b.cacheW, t + b.cacheH), 1.f, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
    dc->SetTransform(Matrix3x2F::Identity());
}

void Scene::DrawSanta(Renderer& r)
{
    SantaObj& s = santa_;
    ID2D1DeviceContext1* dc = r.dc.Get();
    dc->SetTransform(Matrix3x2F::Identity());
    sparkleList_.Clear();
    for (int i = 0; i < 16; i++) {
        if (s.spLife[i] <= 0) continue;
        int lvl = std::max(0, std::min(3, (int)(s.spLife[i] / 0.9f * 4)));
        sparkleList_.Add(r.sparkles[s.spTint[i]][lvl], s.spX[i], s.spY[i], 0.55f + 0.5f * s.spLife[i]);
    }
    sparkleList_.Draw(r);
    if (s.phase == SantaObj::Waiting || s.alpha <= 0) return;

    const float S_ = S;
    float vy = s.VisualY(S_);
    Matrix3x2F m0 = Matrix3x2F::Scale(s.dir, 1) * Matrix3x2F::Rotation(-s.tilt * 180 / kPi) * Matrix3x2F::Translation(s.x, vy);
    bool layered = s.alpha < 0.999f;
    if (layered) dc->PushLayer(D2D1::LayerParameters1(D2D1::InfiniteRect(), nullptr, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE, D2D1::IdentityMatrix(), s.alpha), nullptr);
    dc->SetTransform(m0);
    r.DrawSprite(r.reins, 0, 0);
    bool sliding = s.phase == SantaObj::Sliding;
    float swingAmp = (sliding ? 0.3f : 0.6f) * 180 / kPi;
    for (int k = 0; k < 3; k++) {
        float g = (float)s.gallop + k * 1.1f;
        float dx = kDeerX[k] * S_;
        float dy = -(std::max(0.f, std::sin(2 * g)) * (sliding ? 0.8f : 2.f) + std::sin((float)s.clock * 2 + k) * 0.8f) * S_;
        for (int leg = 0; leg < 4; leg++) {
            bool isFar = leg % 2 == 1;
            float swing = std::sin(g + (leg < 2 ? 0 : kPi) + (isFar ? 0.6f : 0)) * swingAmp;
            dc->SetTransform(Matrix3x2F::Rotation(-swing) * Matrix3x2F::Translation(dx + kHips[leg].x * S_, dy - kHips[leg].y * S_) * m0);
            r.DrawSprite(isFar ? r.legFar : r.legNear, 0, 0);
        }
        dc->SetTransform(m0);
        r.DrawSprite(r.deerBody, dx, dy);
        bool lead = k == 2;
        dc->SetTransform(Matrix3x2F::Rotation(-std::sin(2 * g - 1.6f) * 0.07f * 180 / kPi) *
                         Matrix3x2F::Translation(dx + kNeck.x * S_, dy - kNeck.y * S_) * m0);
        r.DrawSprite(lead ? r.headLead : r.headPlain, 0, 0);
        if (lead) r.DrawSprite(r.noseGlow, (kNose.x - kNeck.x) * S_, -(kNose.y - kNeck.y) * S_, 0.775f + 0.225f * (float)std::sin(s.clock * 4.5));
    }
    float sy = -(float)std::sin(s.clock * 2.6) * 0.9f * S_;
    dc->SetTransform(m0);
    r.DrawSprite(r.santaBody, 0, 0);
    float headRot = (float)std::sin(s.clock * 1.7) * 0.06f * 180 / kPi;
    dc->SetTransform(Matrix3x2F::Rotation(-headRot, Point2F(kHeadPivot.x * S_, -kHeadPivot.y * S_ + sy)) * m0);
    r.DrawSprite(r.santaHead, kHeadPivot.x * S_, -kHeadPivot.y * S_ + sy);
    if (s.blinkT >= 0) r.DrawSprite(r.santaEyes, kHeadPivot.x * S_, -kHeadPivot.y * S_ + sy);
    float arm = -0.6f;
    if (s.waveT >= 0) {
        double t = s.waveT;
        arm = t < 0.16 ? (float)(-0.6 + (0.95 + 0.6) * t / 0.16) : (t < 0.94 ? 0.875f + 0.325f * (float)std::sin((t - 0.16) / 0.26 * kPi * 2) : -0.6f);
    }
    dc->SetTransform(Matrix3x2F::Rotation(-arm * 180.f / kPi) * Matrix3x2F::Translation(kArmPivot.x * S_, -kArmPivot.y * S_ + sy) * m0);
    r.DrawSprite(r.santaArm, 0, 0);
    // speech bubble ("Ho Ho Ho!"): white rounded box with a tail, red bold text
    if (s.bubbleT >= 0) {
        double t = s.bubbleT;
        float scale = t < 0.15 ? (float)(0.1 + 0.9 * t / 0.15) : 1.f;
        float alpha = t > 1.95 ? (float)std::max(0.0, 1 - (t - 1.95) / 0.4) : 1.f;
        const wchar_t* text = L"Ho Ho Ho!";
        float bw = 92 * S_, bh = 26 * S_;
        float cx = s.x - 10 * S_ * s.dir, cy = vy - 84 * S_;
        dc->SetTransform(Matrix3x2F::Scale(scale, scale, Point2F(cx, cy)));
        D2D1_ROUNDED_RECT rr = D2D1::RoundedRect(D2D1::RectF(cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2), 10 * S_, 10 * S_);
        dc->FillRoundedRectangle(rr, r.Solid(Rgb(1, 1, 1, alpha)));
        dc->DrawRoundedRectangle(rr, r.Solid(Rgb(0.7f, 0.7f, 0.75f, alpha)), S_);
        ComPtr<ID2D1PathGeometry> tail = r.NewPath();
        ComPtr<ID2D1GeometrySink> ts;
        tail->Open(&ts);
        ts->BeginFigure(Point2F(cx - 6 * S_, cy + bh / 2 - S_), D2D1_FIGURE_BEGIN_FILLED);
        ts->AddLine(Point2F(cx, cy + bh / 2 + 8 * S_));
        ts->AddLine(Point2F(cx + 6 * S_, cy + bh / 2 - S_));
        ts->EndFigure(D2D1_FIGURE_END_CLOSED);
        ts->Close();
        dc->FillGeometry(tail.Get(), r.Solid(Rgb(1, 1, 1, alpha)));
        dc->DrawText(text, (UINT32)wcslen(text), r.bubbleText.Get(), rr.rect, r.Solid(Rgb(0.75f, 0.08f, 0.1f, alpha)));
    }
    if (layered) dc->PopLayer();
    dc->SetTransform(Matrix3x2F::Identity());
}

void Scene::DrawPlow(Renderer& r)
{
    PlowObj& p = *plow_;
    ID2D1DeviceContext1* dc = r.dc.Get();
    dc->SetTransform(Matrix3x2F::Identity());
    float dh = p.DriftHeight(S);
    if (dh >= 0.5f) {
        float L = std::max(4.f, dh * 2.2f);
        float bx = p.BladeX(S), d = p.dir;
        ComPtr<ID2D1PathGeometry> g = r.NewPath();
        ComPtr<ID2D1GeometrySink> s;
        g->Open(&s);
        s->BeginFigure(Point2F(bx, p.y), D2D1_FIGURE_BEGIN_FILLED);
        s->AddLine(Point2F(bx, p.y - dh * 0.82f));
        s->AddQuadraticBezier(D2D1::QuadraticBezierSegment(Point2F(bx + d * L * 0.02f, p.y - dh * 1.02f), Point2F(bx + d * L * 0.16f, p.y - dh)));
        s->AddBezier(D2D1::BezierSegment(Point2F(bx + d * L * 0.45f, p.y - dh * 0.98f), Point2F(bx + d * L * 0.7f, p.y - dh * 0.12f),
                                         Point2F(bx + d * L, p.y)));
        s->EndFigure(D2D1_FIGURE_END_CLOSED);
        s->Close();
        r.driftBrush->SetStartPoint(Point2F(0, p.y));
        r.driftBrush->SetEndPoint(Point2F(0, p.y - dh));
        dc->FillGeometry(g.Get(), r.driftBrush.Get());
    }
    float squash = 1, lift = 0;
    if (p.honkT >= 0) {
        float t = (float)p.honkT;
        if (t < 0.07f) { squash = 1 - 0.18f * (t / 0.07f); lift = t / 0.07f; }
        else if (t < 0.16f) { squash = 0.82f + 0.3f * ((t - 0.07f) / 0.09f); lift = 1 - 6 * ((t - 0.07f) / 0.09f); }
        else if (t < 0.28f) { squash = 1.12f - 0.12f * ((t - 0.16f) / 0.12f); lift = -5 + 5 * ((t - 0.16f) / 0.12f); }
    }
    dc->SetTransform(Matrix3x2F::Scale(p.dir, squash) * Matrix3x2F::Translation(p.x, p.y + lift * S));
    r.DrawSprite(r.plow, 0, 0);
    bool on = p.beacon && std::sin(time_ * 11) > 0;
    D2D1_COLOR_F bc = p.beacon ? (on ? Rgb(1, 0.6f, 0.1f) : Rgb(0.7f, 0.35f, 0.08f)) : Rgb(0.45f, 0.4f, 0.35f);
    if (on) r.DrawSprite(r.plowGlow, -3 * S, -28 * S);
    dc->FillEllipse(D2D1::Ellipse(Point2F(-3 * S, -28 * S), 2.4f * S, 2.4f * S), r.Solid(bc));
    dc->SetTransform(Matrix3x2F::Identity());
}

void Scene::DrawOutlinedText(Renderer& r, const FloatText& t)
{
    ID2D1DeviceContext1* dc = r.dc.Get();
    if (t.emoji) {
        float age = t.maxLife - t.life;
        if (t.maxLife < 1) {                                   // the open-gift sparkle: grows and fades
            float k = std::min(1.f, age / t.maxLife);
            DrawLabel(dc, t.text.c_str(), t.x, t.y, t.size + (t.growTo - t.size) * k, Rgb(1, 1, 1), 1 - k);
        } else {                                               // the surprise: pops up, rises, holds, fades
            float rise = 55 * S * Smooth(std::min(1.f, age / 0.6f)) + (age > 1.6f ? 20 * S * std::min(1.f, (age - 1.6f) / 0.6f) : 0);
            float size = t.size + (t.growTo - t.size) * std::min(1.f, age / 0.25f);
            float alpha = age > 1.6f ? std::max(0.f, 1 - (age - 1.6f) / 0.6f) : 1.f;
            DrawLabel(dc, t.text.c_str(), t.x, t.y - rise, size, Rgb(1, 1, 1), alpha);
        }
        return;
    }
    float a = std::min(1.f, t.life / 0.4f);
    D2D1_RECT_F box = D2D1::RectF(t.x - 300 * S, t.y - 30 * S, t.x + 300 * S, t.y + 30 * S);
    ID2D1SolidColorBrush* outline = r.Solid(Rgb(0.45f, 0.08f, 0.1f, a * 0.8f));
    const float o = 1.5f * S;
    const float offs[8][2] = {{-o, 0}, {o, 0}, {0, -o}, {0, o}, {-o, -o}, {o, -o}, {-o, o}, {o, o}};
    for (const auto& d : offs) {
        D2D1_RECT_F b2 = D2D1::RectF(box.left + d[0], box.top + d[1], box.right + d[0], box.bottom + d[1]);
        dc->DrawText(t.text.c_str(), (UINT32)t.text.size(), r.fxText.Get(), b2, outline, D2D1_DRAW_TEXT_OPTIONS_NONE);
    }
    dc->DrawText(t.text.c_str(), (UINT32)t.text.size(), r.fxText.Get(), box, r.Solid(WithA(t.color, a)), D2D1_DRAW_TEXT_OPTIONS_NONE);
}

// ---------------------------------------------------------------------------------------------
// Hover / hit testing / delete buttons
// ---------------------------------------------------------------------------------------------

bool Scene::RiderCovered(float x, float y, HWND on) const
{
    if (!on) return false;
    const WinCap* c = windows_.Find(on);
    return c && windows_.Covered(*c, x, y);
}

Ball* Scene::BallAt(float x, float y)
{
    Ball* best = nullptr;
    for (auto& bp : balls_) {
        Ball* b = bp.get();
        if (b->hidden || std::hypot(x - b->x, y - b->y) > b->r || RiderCovered(x, y, b->Root()->restOn)) continue;
        if (!best || b->StackCount() > 0) best = b;          // later (upper) balls win
    }
    return best;
}

GiftObj* Scene::GiftAt(float x, float y, bool includeDelete)
{
    float hw = 15 * S, hh = 12 * S;
    for (size_t i = gifts_.size(); i-- > 0;) {
        GiftObj* g = gifts_[i].get();
        if (g->hidden || RiderCovered(x, y, g->restOn)) continue;
        if (std::fabs(x - g->x) <= hw + 2 * S && y >= g->y - hh - 10 * S && y <= g->y + hh + S) return g;
        if (includeDelete && g == hoverGift_ && GiftDeleteHit(x, y)) return g;
    }
    return nullptr;
}

bool Scene::BallDeleteVisible() const
{
    return held_.kind == KNone && !pendingBall_ && hover_.kind == KBall && time_ - hoverSince_ >= 0.3;
}

D2D1_POINT_2F Scene::BallDeletePos() const
{
    Ball* top = static_cast<Ball*>(hover_.p)->Root()->Top();
    HWND on = static_cast<Ball*>(hover_.p)->Root()->restOn;
    const WinCap* c = on ? windows_.Find(on) : nullptr;
    float side = (c && top->x - top->r - c->rect.left < 80 * S) ? 1.f : -1.f;   // never over a window's left buttons
    return Point2F(top->x + side * top->r * 0.72f, top->y - top->r * 0.72f);
}

bool Scene::BallDeleteHit(float x, float y) const
{
    if (!BallDeleteVisible()) return false;
    D2D1_POINT_2F d = BallDeletePos();
    return std::hypot(x - d.x, y - d.y) <= 10 * S;
}

D2D1_POINT_2F Scene::GiftDeletePos(const GiftObj& g) const
{
    float hw = 15 * S, hh = 12 * S;
    const WinCap* c = g.restOn ? windows_.Find(g.restOn) : nullptr;
    bool right = c && g.x - hw - c->rect.left < 80 * S;
    return Point2F(g.x + (right ? hw + S : -hw - S), g.y - hh - S);
}

bool Scene::GiftDeleteHit(float x, float y) const
{
    if (!hoverGift_ || held_.kind != KNone) return false;
    D2D1_POINT_2F d = GiftDeletePos(*hoverGift_);
    return std::hypot(x - d.x, y - d.y) <= 10 * S;
}

void Scene::DrawDeleteButtons(Renderer& r)
{
    ID2D1DeviceContext1* dc = r.dc.Get();
    auto button = [&](D2D1_POINT_2F d) {
        float rad = 8 * S;
        dc->FillEllipse(D2D1::Ellipse(d, rad, rad), r.Solid(Rgb(0.15f, 0.15f, 0.18f, 0.88f)));
        ID2D1SolidColorBrush* w = r.Solid(Rgb(1, 1, 1, 0.9f));
        dc->DrawEllipse(D2D1::Ellipse(d, rad, rad), w, std::max(1.f, S));
        float k = 3.f * S, lw = std::max(1.2f, 1.6f * S);
        dc->DrawLine(Point2F(d.x - k, d.y - k), Point2F(d.x + k, d.y + k), w, lw, r.roundStroke.Get());
        dc->DrawLine(Point2F(d.x - k, d.y + k), Point2F(d.x + k, d.y - k), w, lw, r.roundStroke.Get());
    };
    if (BallDeleteVisible()) button(BallDeletePos());
    if (hoverGift_ && held_.kind == KNone && !hoverGift_->hidden) button(GiftDeletePos(*hoverGift_));
}

bool Scene::InGroundZone(float x, float y) const
{
    if (x < 0 || x >= W) return false;
    float hgt = ground_->HeightAt(x);
    if (hgt < 2 * S) return false;
    float top = ground_->baseY - hgt;
    // never over another window: the strip above the taskbar may overlap a window's bottom edge
    return y >= top - 2 * S && y <= ground_->baseY + 1 && !windows_.PointOverWindow(x, y);
}

std::wstring Scene::MouseTargetName(float x, float y)
{
    if (lightEdit_) {
        LightAnchor a;
        D2D1_POINT_2F p;
        if (AnchorHit(x, y, &a, &p) || UserStrandNear(x, y, 6 * S)) return L"lightEdit";
    }
    if (santa_.Hit(x, y, S)) return L"santa";
    if (plow_ && plow_->Hit(x, y, S)) return L"plow";
    if (GiftDeleteHit(x, y)) return L"giftDelete";
    if (BallDeleteHit(x, y)) return L"ballDelete";
    if (GiftAt(x, y, false)) return L"gift";
    if (BallAt(x, y)) return L"ball";
    if (InGroundZone(x, y)) return L"groundSnow";
    return L"";
}

/// 60 Hz cursor poll (local px). Returns true when the overlay should take the mouse.
bool Scene::UpdateCursor(float x, float y, bool inside, bool desktopMode)
{
    if (held_.kind != KNone || linkDrag_ || pendingBall_) return true;
    if (!inside || (desktopMode && windows_.PointOverWindow(x, y))) {
        if (hover_.kind || hoverGift_) needsRedraw = true;
        hover_ = Ref();
        hoverGift_ = nullptr;
        return false;
    }
    GiftObj* g = GiftAt(x, y, true);
    if (g != hoverGift_) { hoverGift_ = g; needsRedraw = true; }
    Ref h;
    if (!g && !BallDeleteHit(x, y)) {
        Ball* b = BallAt(x, y);
        if (b) { h.kind = KBall; h.p = b; }
    } else if (!g) {
        h = hover_;                                         // keep the X reachable
    }
    if (h != hover_) { hover_ = h; hoverSince_ = time_; needsRedraw = true; }
    return !MouseTargetName(x, y).empty();
}

// ---------------------------------------------------------------------------------------------
// Mouse input (only arrives while the overlay is not click-through)
// ---------------------------------------------------------------------------------------------

void Scene::MouseDown(float x, float y, bool right, int clicks)
{
    needsRedraw = true;
    if (right) {
        Ball* b = BallAt(x, y);
        contextBall_ = b;                                   // the app shows the "삭제" menu
        return;
    }
    if (lightEdit_ && EditMouseDown(x, y)) return;
    lastMx_ = x;
    lastMy_ = y;
    dragDistance_ = 0;
    history_.clear();
    history_.push_back({time_, x, y});
    if (BallDeleteHit(x, y)) { DeleteBalls(static_cast<Ball*>(hover_.p)); return; }
    if (plow_ && plow_->Hit(x, y, S)) {
        plow_->held = true;
        held_.kind = KPlow;
        held_.p = plow_.get();
        heldDx_ = plow_->x - x;
        heldDy_ = plow_->y - y;
        return;
    }
    if (hoverGift_ && GiftDeleteHit(x, y)) { DeleteGift(hoverGift_); return; }
    if (santa_.Hit(x, y, S)) {
        if (santa_.phase != SantaObj::Held) santa_.savedPhase = santa_.phase;
        santa_.phase = SantaObj::Held;
        held_.kind = KSanta;
        held_.p = &santa_;
        heldDx_ = santa_.x - x;
        heldDy_ = santa_.y - y;
        return;
    }
    if (GiftObj* g = GiftAt(x, y, false)) {
        if (clicks >= 2) { OpenGift(g); return; }
        g->held = true;
        g->vx = g->vy = 0;
        g->angVel = 0;
        g->restOn = nullptr;
        held_.kind = KGift;
        held_.p = g;
        heldDx_ = g->x - x;
        heldDy_ = g->y - y;
        return;
    }
    if (Ball* b = BallAt(x, y)) {
        pendingBall_ = b;
        heldDx_ = b->x - x;
        heldDy_ = b->y - y;
        return;
    }
    if (InGroundZone(x, y)) {
        if ((int)balls_.size() >= kMaxBalls) {
            Ball* old = nullptr;
            for (auto& bp : balls_) if (!bp->below && !bp->above && !bp->held) { old = bp.get(); break; }
            if (!old) return;
            RemoveBallPtr(old);
        }
        float r = 7 * S;
        std::unique_ptr<Ball> nb(new Ball(Clampf(x, r, W - r), ground_->SurfaceY(x) - r * 0.9f, r));
        ground_->Take(x, 4 * S, 1.5f * S);
        nb->held = true;
        held_.kind = KBall;
        held_.p = nb.get();
        heldDx_ = nb->x - x;
        heldDy_ = nb->y - y;
        balls_.push_back(std::move(nb));
        Logf(L"TEST snowball started at %.0f,%.0f", x, y);
    }
}

void Scene::MouseMove(float x, float y)
{
    if (linkDrag_) { EditMouseMove(x, y); return; }
    if (held_.kind == KNone && !pendingBall_) return;
    needsRedraw = true;
    dragDistance_ += std::hypot(x - lastMx_, y - lastMy_);
    lastMx_ = x;
    lastMy_ = y;
    history_.push_back({time_, x, y});
    if (history_.size() > 12) history_.erase(history_.begin());
    if (pendingBall_ && dragDistance_ > 3 * S) {
        Ball* b = pendingBall_;
        pendingBall_ = nullptr;
        if (b->below) {                                     // pulled off a stack: separate snowmen
            Ball* below = b->below;
            below->above = nullptr;
            b->below = nullptr;
            b->outfit = Outfit();
            (void)below;
            ValidateCustomize();
        }
        b->held = true;
        held_.kind = KBall;
        held_.p = b;
    }
    float tx = x + heldDx_, ty = y + heldDy_;
    switch (held_.kind) {
    case KBall: DragBall(static_cast<Ball*>(held_.p), tx, ty); break;
    case KSanta: santa_.x = Clampf(tx, 0, (float)W); santa_.y = Clampf(ty, 60 * S, (float)H); break;
    case KGift: {
        GiftObj* g = static_cast<GiftObj*>(held_.p);
        g->x = Clampf(tx, 15 * S, W - 15 * S);
        g->y = Clampf(ty, 12 * S, H - 12 * S);
        break;
    }
    case KPlow: plow_->x = Clampf(tx, 20 * S, W - 20 * S); plow_->y = Clampf(ty, 40 * S, (float)H); break;
    default: break;
    }
}

void Scene::MouseUp(float x, float y)
{
    if (linkDrag_) { EditMouseUp(x, y); return; }
    needsRedraw = true;
    if (pendingBall_) {
        Ball* root = pendingBall_->Root();
        pendingBall_ = nullptr;
        if (root->above) OpenCustomizer(root);              // click on a 2+ tier snowman
        return;
    }
    Ref h = held_;
    held_ = Ref();
    if (h.kind == KNone) return;
    switch (h.kind) {
    case KBall: {
        Ball* b = static_cast<Ball*>(h.p);
        b->held = false;
        b->vy = 0;
        Logf(L"TEST snowball released r=%.1fpt", b->r / S);
        break;
    }
    case KSanta:
        if (dragDistance_ < 4 * S) {
            santa_.phase = santa_.savedPhase;
            if (santa_.phase == SantaObj::Flying) santa_.cruiseY = santa_.y + (float)std::sin(santa_.clock * 1.8) * 14 * S;
            santa_.bubbleT = 0;
            Celebrate();
            SpawnGift(santa_.x - santa_.dir * 30 * S, santa_.y - 30 * S, RandInt(4), false, santa_.dir * 60 * S, -120 * S, true);
            Logf(L"TEST santa clicked: Ho Ho Ho + gift");
        } else {
            santa_.phase = SantaObj::Ascending;
            santa_.startX = santa_.x;
            santa_.startY = santa_.y;
            santa_.velocity = 70 * S;
            Logf(L"TEST santa dragged and released");
        }
        break;
    case KGift: {
        GiftObj* g = static_cast<GiftObj*>(h.p);
        g->held = false;
        D2D1_POINT_2F v = ThrowVelocity();
        g->vx = v.x;
        g->vy = v.y;
        g->angVel = v.x / S * 0.01f;
        giftsDirty = true;
        Logf(L"TEST gift released v=%.0f,%.0f", v.x / S, v.y / S);
        break;
    }
    case KPlow:
        plow_->held = false;
        plow_->vy = 0;
        plow_->airborne = true;
        if (dragDistance_ < 4 * S) {
            plow_->beacon = !plow_->beacon;
            plow_->honkT = 0;
            AddText(L"빵!", plow_->x + plow_->dir * 14 * S, plow_->y - 34 * S, Rgb(1, 0.85f, 0.3f));
            Logf(L"TEST plow honk beacon=%d", plow_->beacon ? 1 : 0);
        }
        break;
    default: break;
    }
}

void Scene::CancelCapture()
{
    if (linkDrag_) { linkDrag_ = false; snapping_ = false; }
    pendingBall_ = nullptr;
    Ref h = held_;
    held_ = Ref();
    switch (h.kind) {
    case KBall: static_cast<Ball*>(h.p)->held = false; break;
    case KSanta: santa_.phase = SantaObj::Ascending; santa_.startX = santa_.x; santa_.startY = santa_.y; santa_.velocity = 70 * S; break;
    case KGift: static_cast<GiftObj*>(h.p)->held = false; break;
    case KPlow: plow_->held = false; plow_->airborne = true; break;
    default: break;
    }
}

D2D1_POINT_2F Scene::ThrowVelocity() const
{
    if (history_.size() < 2 || time_ - history_.back().t > 0.08) return Point2F(0, 0);
    const Sample& last = history_.back();
    const Sample* old = &last;
    for (const Sample& s : history_) if (last.t - s.t <= 0.1) { old = &s; break; }
    double dt = last.t - old->t;
    if (dt <= 0.004) return Point2F(0, 0);
    float vx = (float)((last.x - old->x) / dt), vy = (float)((last.y - old->y) / dt);
    float m = std::hypot(vx, vy), lim = 2600 * S;
    if (m > lim) { vx *= lim / m; vy *= lim / m; }
    return Point2F(vx, vy);
}

void Scene::OpenCustomizer(Ball* root)
{
    if (!onOpenCustomizer) return;
    float maxR = 0, topY = root->y;
    for (Ball* b = root; b; b = b->above) { maxR = std::max(maxR, b->r); topY = std::min(topY, b->y - b->r); }
    RECT r = {(LONG)(root->x - maxR), (LONG)topY, (LONG)(root->x + maxR), (LONG)(root->y + root->r)};
    Logf(L"TEST customizer opened for a %d-tier snowman", root->StackCount());
    onOpenCustomizer(root, r);
}

bool Scene::IsSnowmanRoot(Ball* b) const
{
    for (const auto& bp : balls_)
        if (bp.get() == b) return !b->below && b->above;
    return false;
}

void Scene::SetOutfit(Ball* root, const Outfit& o)
{
    if (!IsSnowmanRoot(root)) return;
    root->outfit = o;
    needsRedraw = true;
}

std::wstring Scene::SupportInfo(float x, float y)
{
    SupportHit h = Support(x, y);
    wchar_t b[256];
    std::wstring caps;
    for (WinCap* c : windows_.caps) {
        wchar_t cb[128];
        swprintf_s(cb, L" [%s top=%ld x=%ld..%ld surf=%.1f vis=%d z=%d", c->owner.c_str(), c->rect.top, c->rect.left, c->rect.right, c->SurfaceAt(x),
                   c->VisibleAt(x) ? 1 : 0, c->zAll);
        caps += cb;
        for (int z = 0; z < c->zAll && z < (int)windows_.allRects.size(); z++) {
            const RECT& o = windows_.allRects[z];
            if (x >= o.left && x < o.right && c->rect.top - S >= o.top && c->rect.top - S < o.bottom) {
                wchar_t cls[64];
                ClassOf(windows_.allHwnds[z], cls, 64);
                swprintf_s(cb, L" covered by z=%d %s/%s %ld,%ld,%ld,%ld", z, ExeNameOf(windows_.allHwnds[z]).c_str(), cls, o.left, o.top, o.right, o.bottom);
                caps += cb;
                break;
            }
        }
        caps += L"]";
    }
    swprintf_s(b, L"support(%.0f, below %.0f) = %.1f on %s; capsActive=%d;", x, y, h.y, h.cap ? h.cap->owner.c_str() : L"ground", CapsActive() ? 1 : 0);
    return b + caps;
}
