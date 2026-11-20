// The "WinterDesk 설정" window: a real top-level window (taskbar button, Alt+Tab) with a custom
// title bar, a sidebar and one page per effect group. Everything - controls, icons and the hero
// illustrations (cocoa, Rudolph, tree, snowy window, snowman) - is Direct2D geometry; no images.
// Animates at ~30 fps only while it is visible and not minimized; knobs apply live (saved at most
// every 300 ms while dragging and on release). Lives on the UI thread like the overlay.
#include "winterdesk.h"
#include <windowsx.h>
#include <dwmapi.h>
#include <shellscalingapi.h>

using D2D1::Point2F;
using D2D1::RectF;

namespace {

const wchar_t* kClass = L"WinterDeskSettings";
const float kSide = 210, kTitle = 44, kPad = 28;          // DIP
enum : UINT_PTR { TIMER_ANIM = 1 };

D2D1_COLOR_F Hex(uint32_t rgb, float a = 1.f)
{
    return D2D1::ColorF(((rgb >> 16) & 255) / 255.f, ((rgb >> 8) & 255) / 255.f, (rgb & 255) / 255.f, a);
}
D2D1_COLOR_F Mix(D2D1_COLOR_F a, D2D1_COLOR_F b, float t)
{
    return D2D1::ColorF(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t);
}
D2D1_COLOR_F Fade(D2D1_COLOR_F c, float k) { c.a *= k; return c; }

// palette: deep pine night, cranberry accent, warm gold, cream text
const D2D1_COLOR_F cBg0 = Hex(0x0E1F1A), cBg1 = Hex(0x122820), cCard = Hex(0x183229), cRed = Hex(0xE2414F), cRedHi = Hex(0xF2606C),
                   cRedLo = Hex(0xB82A3A), cGold = Hex(0xF4C35A), cCream = Hex(0xFFF4E6), cMuted = Hex(0xA9BFB4), cSnow = Hex(0xF7FBFF),
                   cWhite = D2D1::ColorF(1, 1, 1, 1);
// bulb colours / light-style palettes (match render.cpp kBulbColors and lights.cpp kPalettes)
const D2D1_COLOR_F kBulb[kBulbColorCount] = {{1, 0.22f, 0.22f, 1}, {0.25f, 0.95f, 0.4f, 1}, {0.3f, 0.55f, 1, 1}, {1, 0.76f, 0.2f, 1},
                                             {1, 0.86f, 0.6f, 1},  {1, 0.86f, 0.6f, 1},    {0.94f, 0.97f, 1, 1}, {0.35f, 0.9f, 1, 1},
                                             {1, 0.45f, 0.75f, 1}};
const struct { int n, c[5]; } kPal[5] = {{5, {0, 1, 2, 3, 4}}, {1, {5}}, {3, {0, 1, 3}}, {3, {2, 6, 7}}, {3, {0, 6, 8}}};
const wchar_t* const kPalName[5] = {L"멀티컬러", L"웜 화이트", L"클래식", L"아이시", L"캔디"};

ComPtr<IDWriteTextFormat> Fmt(float size, DWRITE_FONT_WEIGHT w, DWRITE_TEXT_ALIGNMENT a = DWRITE_TEXT_ALIGNMENT_LEADING,
                              DWRITE_PARAGRAPH_ALIGNMENT p = DWRITE_PARAGRAPH_ALIGNMENT_CENTER, bool wrap = false)
{
    ComPtr<IDWriteTextFormat> f;
    if (FAILED(DWFactory()->CreateTextFormat(L"Segoe UI", nullptr, w, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, L"ko-kr", &f)))
        return nullptr;
    f->SetTextAlignment(a);
    f->SetParagraphAlignment(p);
    // Korean breaks at spaces (whole words) where the system supports it (Windows 8.1+)
    if (!wrap) f->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    else if (FAILED(f->SetWordWrapping(DWRITE_WORD_WRAPPING_WHOLE_WORD))) f->SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP);
    return f;
}

float TextW(IDWriteTextFormat* f, const wchar_t* t)
{
    ComPtr<IDWriteTextLayout> l;
    if (!f || FAILED(DWFactory()->CreateTextLayout(t, (UINT32)wcslen(t), f, 4000, 100, &l))) return 80;
    DWRITE_TEXT_METRICS m{};
    l->GetMetrics(&m);
    return m.widthIncludingTrailingWhitespace;
}

template <class F> ComPtr<ID2D1PathGeometry> Geo(F build)
{
    ComPtr<ID2D1PathGeometry> g;
    ComPtr<ID2D1GeometrySink> s;
    if (FAILED(D2DFactory()->CreatePathGeometry(&g)) || FAILED(g->Open(&s))) return nullptr;
    build(s.Get());
    if (FAILED(s->Close())) return nullptr;
    return g;
}
D2D1_BEZIER_SEGMENT Bz(float x1, float y1, float x2, float y2, float x3, float y3) { return D2D1::BezierSegment(Point2F(x1, y1), Point2F(x2, y2), Point2F(x3, y3)); }
D2D1_QUADRATIC_BEZIER_SEGMENT Qz(float x1, float y1, float x2, float y2) { return D2D1::QuadraticBezierSegment(Point2F(x1, y1), Point2F(x2, y2)); }
D2D1_POINT_2F QPoint(D2D1_POINT_2F a, D2D1_POINT_2F c, D2D1_POINT_2F b, float t)
{
    float u = 1 - t;
    return Point2F(u * u * a.x + 2 * u * t * c.x + t * t * b.x, u * u * a.y + 2 * u * t * c.y + t * t * b.y);
}
float Ease(float v, float target, float dt, float tau = 0.045f) { return v + (target - v) * (1 - std::exp(-dt / tau)); }

// ---------------------------------------------------------------------------------------------
// Page description: cards of rows (label + helper text on the left, a control on the right)
// ---------------------------------------------------------------------------------------------
enum Kind { KToggle, KSlider, KSegment, KPalette, KButtons, KNote, KKeys, KFooter };
struct Btn {
    const wchar_t* text;
    const wchar_t* confirm;            // non-null: two-step ("한 번 더 누르면 ...")
    bool primary;
    int cmd;                           // SettingsCmd
    std::function<bool()> en;
    float w = 0;
    D2D1_RECT_F r{};
};
struct Row {
    Kind kind = KToggle;
    const wchar_t* label = L"";
    const wchar_t* help = L"";
    std::function<bool()> en;          // null = always enabled
    std::function<bool()> on;          // toggle state
    int cmd = -1;                      // toggle command
    int* field = nullptr;              // slider
    int lo = 0, hi = 100, step = 5;
    bool perMille = false;
    const wchar_t* zero = nullptr;     // slider text at lo
    std::vector<const wchar_t*> opts;  // segment
    std::function<int()> get;
    std::function<void(int)> set;
    std::function<bool()> reselect;    // segment: true = set() runs even for the option already shown
    std::vector<Btn> btns;
    std::function<const wchar_t*()> note;
    // layout (content DIP, before scrolling)
    bool shown = true;
    float y = 0, h = 0, cy = 0;
    D2D1_RECT_F ctl{};
};
struct Card {
    const wchar_t* title = nullptr;
    std::vector<Row> rows;
    bool bare = false;
    float y = 0, h = 0;
};

struct BgFlake { float x, y, r, speed, phase, alpha; bool star; };

const wchar_t* const kNav[5] = {L"눈", L"산타 · 선물", L"전구", L"창 효과", L"일반"};
const wchar_t* const kKicker[5] = {L"SNOW", L"SANTA & GIFTS", L"LIGHTS", L"WINDOWS", L"GENERAL"};
const wchar_t* const kHeroTitle[5] = {L"눈 내리기", L"산타와 선물", L"반짝이는 전구", L"창 위의 겨울", L"일반"};
const wchar_t* const kHeroDesc[5] = {
    L"눈송이의 양과 크기, 떨어지는 속도와 바람, 쌓이는 빠르기를 조절해요.",
    L"루돌프 썰매가 얼마나 자주 지나가고, 선물을 얼마나 떨어뜨릴지 정해요.",
    L"창 위에 걸리는 전구와 가랜드. 색상을 고르면 트리에서 바로 미리 볼 수 있어요.",
    L"열린 창 위에 쌓이는 눈과, 창을 끌 때 눈이 어떻게 움직일지 정해요.",
    L"자동 실행, 선물과 눈사람 정리, 그리고 단축키 모음."};

// hit ids
enum : int { HIT_NONE = 0, HIT_CLOSE = 1, HIT_MIN = 2, HIT_EFFECTS = 3, HIT_RESET = 4, HIT_NAV = 10, HIT_ROW = 1000 };
int RowId(int ci, int ri, int sub = 0) { return HIT_ROW + ci * 100 + ri * 10 + sub; }

class SettingsWindow {
public:
    ~SettingsWindow() { Close(); }
    void Open(const SettingsUiHost& h, int tab);
    void Close();
    void Refresh();
    HWND Hwnd() const { return hwnd_; }
    LRESULT Proc(HWND h, UINT m, WPARAM w, LPARAM l);

private:
    void Build();
    void Layout();
    void Render();
    bool CreateDevice();
    void DiscardDevice();
    void EnsureGeometry();
    void StartTimer();
    void Settle() { settleUntil_ = NowSec() + 0.6; StartTimer(); }
    int Hit(float x, float y);
    void MouseDown(float x, float y);
    void MouseMove(float x, float y);
    void MouseUp(float x, float y);
    void Activate(int id);
    void SetTab(int tab);
    void SliderTo(Row& r, float x);
    void FlushKnobs(bool force);
    bool Armed(int id) const { return armedId_ == id && NowSec() - armedAt_ < 3.0; }
    float& Anim(int id, float init) { auto it = anim_.find(id); if (it == anim_.end()) it = anim_.emplace(id, init).first; return it->second; }
    Row* RowOf(int id);

    // drawing helpers (DIP)
    ID2D1SolidColorBrush* B(D2D1_COLOR_F c) { brush_->SetColor(c); return brush_.Get(); }
    void RR(D2D1_RECT_F r, float rad, D2D1_COLOR_F c) { rt_->FillRoundedRectangle(D2D1::RoundedRect(r, rad, rad), B(c)); }
    void RRS(D2D1_RECT_F r, float rad, D2D1_COLOR_F c, float w = 1) { rt_->DrawRoundedRectangle(D2D1::RoundedRect(r, rad, rad), B(c), w); }
    void Ell(float x, float y, float rx, float ry, D2D1_COLOR_F c) { rt_->FillEllipse(D2D1::Ellipse(Point2F(x, y), rx, ry), B(c)); }
    void EllS(float x, float y, float rx, float ry, D2D1_COLOR_F c, float w) { rt_->DrawEllipse(D2D1::Ellipse(Point2F(x, y), rx, ry), B(c), w, round_.Get()); }
    void Ln(float x0, float y0, float x1, float y1, D2D1_COLOR_F c, float w) { rt_->DrawLine(Point2F(x0, y0), Point2F(x1, y1), B(c), w, round_.Get()); }
    void FillG(ID2D1Geometry* g, D2D1_COLOR_F c) { if (g) rt_->FillGeometry(g, B(c)); }
    void FillG(ID2D1Geometry* g, ID2D1Brush* b) { if (g && b) rt_->FillGeometry(g, b); }
    void StrokeG(ID2D1Geometry* g, D2D1_COLOR_F c, float w, ID2D1StrokeStyle* st = nullptr) { if (g) rt_->DrawGeometry(g, B(c), w, st ? st : round_.Get()); }
    void Glow(ID2D1RadialGradientBrush* g, float x, float y, float r, float opacity);
    ID2D1Brush* Lin(ID2D1LinearGradientBrush* b, float x0, float y0, float x1, float y1, D2D1_COLOR_F fallback);
    ComPtr<ID2D1LinearGradientBrush> MakeLin(D2D1_COLOR_F a, D2D1_COLOR_F b);
    ComPtr<ID2D1RadialGradientBrush> MakeGlow(D2D1_COLOR_F c);
    void Text(const wchar_t* t, IDWriteTextFormat* f, D2D1_RECT_F r, D2D1_COLOR_F c);
    void Push(const D2D1_MATRIX_3X2_F& m) { rt_->SetTransform(m * base_); }
    void Pop() { rt_->SetTransform(base_); }

    void DrawBackground();
    void DrawSidebar();
    void DrawNavIcon(int i, float cx, float cy, D2D1_COLOR_F c);
    void DrawFlake(float cx, float cy, float r, D2D1_COLOR_F c, float w);
    void DrawSparkle(float cx, float cy, float r, D2D1_COLOR_F c);
    void DrawToggle(D2D1_RECT_F r, float t, float alpha, bool hot);
    void DrawHero(float y);
    void DrawCocoa();
    void DrawRudolph();
    void DrawTree();
    void DrawWindowArt();
    void DrawGifts();
    void DrawBulb(float x, float y, float r, int color, float bright);
    void DrawCard(int ci, Card& c);
    void DrawRow(int ci, int ri, Row& r, float L, float R);
    void DrawTitleBar();

    SettingsUiHost host_;
    HWND hwnd_ = nullptr;
    float s_ = 1.f, W_ = 860, H_ = 600;
    int tab_ = 0;
    std::vector<Card> cards_;
    float contentH_ = 0, scroll_ = 0, scrollTarget_ = 0;
    double t0_ = 0, last_ = 0;
    float t_ = 0;
    float mx_ = -1, my_ = -1;
    bool tracking_ = false, inMove_ = false, inMenuLoop_ = false, logLayout_ = false;
    double settleUntil_ = 0;            // unfocused: animate until then (eases finish), then stop
    int hot_ = HIT_NONE, pressed_ = HIT_NONE, dragSlider_ = HIT_NONE;
    int armedId_ = HIT_NONE;
    double armedAt_ = 0;
    bool knobApply_ = false, knobSave_ = false;
    double lastApply_ = 0, lastSave_ = 0;
    bool login_ = false;
    UINT timerMs_ = 0;
    std::unordered_map<int, float> anim_;
    std::unordered_map<const wchar_t*, std::wstring> keepAll_;
    BgFlake bg_[30] = {};
    D2D1_MATRIX_3X2_F base_ = D2D1::Matrix3x2F::Identity();

    // device resources
    ComPtr<ID2D1HwndRenderTarget> rt_;
    ComPtr<ID2D1SolidColorBrush> brush_;
    ComPtr<ID2D1LinearGradientBrush> bgLin_, redLin_, mugLin_, treeLin_, capLin_, heroLin_[5], cardLin_;
    ComPtr<ID2D1RadialGradientBrush> glowGold_, glowRed_, glowWhite_, glowBlue_, glowBulb_[kBulbColorCount], snowBall_;
    // device-independent
    ComPtr<ID2D1StrokeStyle> round_, cane_;
    ComPtr<ID2D1PathGeometry> steam_, caneGeo_, antlerL_, antlerR_, neck_, smile_, star_, tier_[3], garland_[3], cap_, icicles_, carrot_,
        hatIcon_, flakeIcon_, rimHatch_;
    ComPtr<IDWriteTextFormat> fTitle_, fLogo_, fLogoSub_, fNav_, fKicker_, fHeroTitle_, fHeroDesc_, fCardTitle_, fLabel_, fHelp_, fValue_,
        fSeg_, fBtn_, fChip_, fKey_, fFoot_, fNote_, fBubble_;
};

std::unique_ptr<SettingsWindow> g_win;

LRESULT CALLBACK SettingsProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (g_win && (g_win->Hwnd() == h || g_win->Hwnd() == nullptr)) return g_win->Proc(h, m, w, l);
    return DefWindowProcW(h, m, w, l);
}

// =============================================================================================
// Lifecycle
// =============================================================================================

void SettingsWindow::Open(const SettingsUiHost& h, int tab)
{
    host_ = h;
    login_ = GetLaunchAtLogin();
    EnsureGeometry();
    if (hwnd_) {
        if (IsIconic(hwnd_)) ShowWindow(hwnd_, SW_RESTORE);
        SetForegroundWindow(hwnd_);
        if (tab >= 0) SetTab(tab);              // -1 (menu / double-click / hotkey): keep the current tab
        logLayout_ = host_.test;
        Settle();
        InvalidateRect(hwnd_, nullptr, FALSE);
        return;
    }
    static bool registered = false;
    HINSTANCE inst = GetModuleHandleW(nullptr);
    if (!registered) {
        WNDCLASSEXW wc{};
        wc.cbSize = sizeof(wc);
        wc.lpfnWndProc = SettingsProc;
        wc.hInstance = inst;
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.hIcon = host_.iconBig;
        wc.hIconSm = host_.iconSmall;
        wc.lpszClassName = kClass;
        registered = RegisterClassExW(&wc) != 0;
        if (!registered) { Logf(L"settings window class registration failed (%lu)", GetLastError()); return; }
    }
    // placement: centred on the internal display's work area, sized for its DPI, clamped to it
    const RECT& wk = host_.work;
    HMONITOR mon = MonitorFromRect(&wk, MONITOR_DEFAULTTONEAREST);
    UINT dpiX = 96, dpiY = 96;
    if (FAILED(GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, &dpiX, &dpiY))) dpiX = 96;
    float s = dpiX / 96.f;
    int ww = wk.right - wk.left, wh = wk.bottom - wk.top;
    int w = std::min((int)std::lround(860 * s), ww - (int)(16 * s)), hh = std::min((int)std::lround(600 * s), wh - (int)(16 * s));
    int x = wk.left + (ww - w) / 2, y = wk.top + (wh - hh) / 2;
    // WS_CAPTION keeps the DWM shadow, rounded corners and minimize animation; WM_NCCALCSIZE drops the frame
    hwnd_ = CreateWindowExW(WS_EX_APPWINDOW, kClass, L"WinterDesk 설정", WS_POPUP | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX, x, y, w, hh,
                            nullptr, nullptr, inst, nullptr);
    if (!hwnd_) { Logf(L"settings window creation failed (%lu)", GetLastError()); return; }
    if (host_.iconBig) SendMessageW(hwnd_, WM_SETICON, ICON_BIG, (LPARAM)host_.iconBig);
    if (host_.iconSmall) SendMessageW(hwnd_, WM_SETICON, ICON_SMALL, (LPARAM)host_.iconSmall);
    BOOL dark = TRUE;
    if (FAILED(DwmSetWindowAttribute(hwnd_, 20 /*DWMWA_USE_IMMERSIVE_DARK_MODE*/, &dark, sizeof(dark))))
        DwmSetWindowAttribute(hwnd_, 19, &dark, sizeof(dark));                  // pre-20H1 value; failure is fine
    DWORD corner = 2;                                                            // DWMWCP_ROUND (Windows 11 only)
    DwmSetWindowAttribute(hwnd_, 33 /*DWMWA_WINDOW_CORNER_PREFERENCE*/, &corner, sizeof(corner));
    COLORREF border = RGB(0x2A, 0x4A, 0x3E);
    DwmSetWindowAttribute(hwnd_, 34 /*DWMWA_BORDER_COLOR*/, &border, sizeof(border));
    MARGINS mg = {0, 0, 1, 0};                                                   // keeps the shadow on Windows 10
    DwmExtendFrameIntoClientArea(hwnd_, &mg);
    SetWindowPos(hwnd_, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE);
    s_ = GetDpiForWindow(hwnd_) / 96.f;
    if (s_ <= 0) s_ = 1;
    RECT cr;
    GetClientRect(hwnd_, &cr);
    W_ = cr.right / s_;
    H_ = cr.bottom / s_;
    for (BgFlake& f : bg_) {
        f = {Rand(0, 860), Rand(0, 600), Rand(0.8f, 2.2f), Rand(6, 16), Rand(0, 6.28f), Rand(0.08f, 0.22f), Rand01() < 0.25};
        if (f.star) f.r = Rand(3, 5.5f);
    }
    t0_ = last_ = NowSec();
    tab_ = std::max(0, std::min(4, tab));
    anim_.clear();
    Build();
    logLayout_ = host_.test;
    ShowWindow(hwnd_, SW_SHOW);
    SetForegroundWindow(hwnd_);
    StartTimer();
    Logf(L"TEST settings window opened tab=%d at %d,%d %dx%d scale=%.2f", tab_, x, y, w, hh, s_);
}

void SettingsWindow::Close()
{
    FlushKnobs(true);
    if (hwnd_) {
        HWND h = hwnd_;
        DestroyWindow(h);                     // WM_DESTROY clears hwnd_ and the device
        Logf(L"TEST settings window closed");
    }
    hwnd_ = nullptr;
}

void SettingsWindow::Refresh()
{
    if (!hwnd_) return;
    login_ = GetLaunchAtLogin();
    InvalidateRect(hwnd_, nullptr, FALSE);
    Settle();                                   // let toggles / segments ease to the new state, then stop
}

/// ~30 fps while focused (or briefly after a change / input so eases finish); no timer at all when
/// unfocused, minimized, hidden, cloaked (another virtual desktop), locked or suspended. WM_PAINT
/// (Refresh, input) still draws single frames.
void SettingsWindow::StartTimer()
{
    if (!hwnd_) return;
    bool canSee = IsWindowVisible(hwnd_) && !IsIconic(hwnd_) && !IsCloaked(hwnd_) && !(host_.paused && host_.paused());
    bool active = GetForegroundWindow() == hwnd_ || inMove_ || inMenuLoop_ || NowSec() < settleUntil_;
    UINT want = canSee && active ? 33 : 0;
    if (want == timerMs_) return;
    timerMs_ = want;
    if (want) SetTimer(hwnd_, TIMER_ANIM, want, nullptr);
    else KillTimer(hwnd_, TIMER_ANIM);
}

void SettingsWindow::SetTab(int tab)
{
    tab = std::max(0, std::min(4, tab));
    if (tab == tab_ && !cards_.empty()) return;
    FlushKnobs(true);
    tab_ = tab;
    scroll_ = scrollTarget_ = 0;
    armedId_ = HIT_NONE;
    hot_ = pressed_ = dragSlider_ = HIT_NONE;
    // per-row eases belong to the old page: drop them so the new controls start at their own values
    for (auto it = anim_.begin(); it != anim_.end();) it = it->first >= HIT_ROW ? anim_.erase(it) : std::next(it);
    Build();
    Logf(L"TEST settings tab -> %d", tab_);
}

// =============================================================================================
// Pages
// =============================================================================================

void SettingsWindow::Build()
{
    cards_.clear();
    Settings* s = host_.settings;
    if (!s) return;
    auto wf = [s] { return s->WindowFeatures(); };
    auto toggle = [](const wchar_t* label, const wchar_t* help, int cmd, std::function<bool()> on, std::function<bool()> en = nullptr) {
        Row r;
        r.kind = KToggle; r.label = label; r.help = help; r.cmd = cmd; r.on = std::move(on); r.en = std::move(en);
        return r;
    };
    auto slider = [](const wchar_t* label, const wchar_t* help, int* f, int lo, int hi, int step, std::function<bool()> en,
                     const wchar_t* zero = nullptr) {
        Row r;
        r.kind = KSlider; r.label = label; r.help = help; r.field = f; r.lo = lo; r.hi = hi; r.step = step; r.en = std::move(en); r.zero = zero;
        return r;
    };
    auto seg = [](const wchar_t* label, const wchar_t* help, std::vector<const wchar_t*> opts, std::function<int()> get,
                  std::function<void(int)> set, std::function<bool()> en = nullptr) {
        Row r;
        r.kind = KSegment; r.label = label; r.help = help; r.opts = std::move(opts); r.get = std::move(get); r.set = std::move(set); r.en = std::move(en);
        return r;
    };
    auto buttons = [](const wchar_t* label, const wchar_t* help, std::vector<Btn> b) {
        Row r;
        r.kind = KButtons; r.label = label; r.help = help; r.btns = std::move(b);
        return r;
    };
    auto note = [](std::function<const wchar_t*()> f) { Row r; r.kind = KNote; r.note = std::move(f); return r; };
    auto wfNote = [s]() -> const wchar_t* {
        if (s->safeMode) return L"안전 모드로 실행 중이라 이번에는 창 효과가 꺼져 있어요. 모드를 고르면 안전 모드가 끝나요.";
        if (s->mode != ModeOnTop) return L"창 위 효과는 '항상 위' 모드에서만 동작해요. 창 효과 탭에서 모드를 바꿀 수 있어요.";
        return nullptr;
    };
    auto snowOn = [s] { return s->snowFalling; };
    auto apply = [this] { if (host_.apply) host_.apply(true); };

    switch (tab_) {
    case 0: {
        Card a{L"눈 내리기 · Snowfall"};
        a.rows.push_back(toggle(L"눈 내리기", L"하늘에서 눈이 내려요 · Ctrl+Alt+Shift+S", SC_Snow, [s] { return s->snowFalling; }));
        a.rows.push_back(seg(L"눈 강도", L"한 번에 내리는 눈의 양", {L"가볍게", L"보통", L"펑펑"}, [s] { return s->intensity; },
                             [s, apply](int i) { s->intensity = i; apply(); }, snowOn));
        cards_.push_back(std::move(a));
        Card b{L"눈송이 · Flakes"};
        b.rows.push_back(slider(L"눈송이 양", L"화면에 떠 있는 눈송이 수", &s->snowDensity, 25, 250, 5, snowOn));
        b.rows.push_back(slider(L"눈송이 크기", L"작고 고운 눈부터 함박눈까지", &s->flakeSize, 60, 180, 5, snowOn));
        b.rows.push_back(slider(L"떨어지는 속도", L"눈송이가 내려오는 빠르기", &s->fallSpeed, 40, 250, 5, snowOn));
        b.rows.push_back(slider(L"바람 세기", L"눈송이가 옆으로 흩날리는 정도", &s->windStrength, 0, 300, 5, snowOn, L"바람 없음"));
        b.rows.push_back(slider(L"쌓이는 속도", L"바닥과 창 위에 눈이 쌓이는 빠르기", &s->accumulation, 0, 300, 5, snowOn, L"안 쌓임"));
        cards_.push_back(std::move(b));
        break;
    }
    case 1: {
        auto santaOn = [s] { return s->santa; };
        Card a{L"산타 · Santa"};
        a.rows.push_back(toggle(L"산타", L"썰매를 탄 산타가 하늘을 지나가요 · Ctrl+Alt+Shift+D", SC_Santa, santaOn));
        a.rows.push_back(seg(L"등장 빈도", L"산타가 다시 나타나기까지의 간격", {L"드물게", L"보통", L"자주"}, [s] { return s->santaFrequency; },
                             [s, apply](int i) { s->santaFrequency = i; apply(); }, santaOn));
        a.rows.push_back(slider(L"착륙 확률", L"지나가다 땅에 내려앉을 확률", &s->santaLandChance, 0, 100, 5, santaOn, L"안 내림"));
        Row g = slider(L"선물 떨어뜨릴 확률", L"한 번 지나갈 때 선물 상자를 떨어뜨릴 확률", &s->giftChance, 0, 1000, 1, santaOn, L"안 떨어뜨림");
        g.perMille = true;
        a.rows.push_back(std::move(g));
        a.rows.push_back(slider(L"비행 속도", L"썰매가 하늘을 가로지르는 빠르기", &s->santaSpeed, 50, 200, 5, santaOn));
        cards_.push_back(std::move(a));
        Card b{L"제설차 · Snowplow"};
        b.rows.push_back(toggle(L"제설차", L"바닥에 쌓인 눈을 밀고 다녀요 · Ctrl+Alt+Shift+P", SC_Plow, [s] { return s->snowplow; }));
        b.rows.push_back(slider(L"제설차 속도", L"제설차가 오가는 빠르기", &s->plowSpeed, 50, 250, 5, [s] { return s->snowplow; }));
        cards_.push_back(std::move(b));
        break;
    }
    case 2: {
        auto lightsOn = [s] { return s->WindowFeatures() && s->windowLights; };
        Card a{L"창 전구 · Window lights"};
        a.rows.push_back(note(wfNote));
        a.rows.push_back(toggle(L"창 전구", L"창 위쪽 가장자리를 따라 전구가 걸려요", SC_Lights, [s] { return s->windowLights; }, wf));
        a.rows.push_back(toggle(L"창 가랜드", L"전구와 함께 초록 가랜드를 걸어요", SC_Garlands, [s] { return s->windowGarlands; }, lightsOn));
        a.rows.push_back(seg(L"전구 연결", L"가까운 창끼리 전구를 자동으로 이어요", {L"자동", L"수동"}, [s] { return s->lightLinksAuto ? 0 : 1; },
                             [this](int i) { host_.command(i == 0 ? SC_LinksAuto : SC_LinksManual); }, lightsOn));
        cards_.push_back(std::move(a));
        Card b{L"색상과 반짝임 · Style"};
        Row p;
        p.kind = KPalette;
        p.label = L"전구 색상";
        p.help = L"고르는 즉시 위 트리와 화면의 전구에 반영돼요";
        b.rows.push_back(std::move(p));
        b.rows.push_back(slider(L"반짝임 속도", L"전구가 깜빡이는 빠르기", &s->twinkleSpeed, 0, 300, 5, nullptr, L"고정"));
        b.rows.push_back(buttons(L"전구 직접 연결하기", L"창 위 금색 점을 끌어 원하는 창끼리 이어요 · Ctrl+Alt+Shift+L",
                                 {Btn{L"전구 직접 연결하기…", nullptr, true, SC_EditLights, [this] { return host_.canEditLights && host_.canEditLights(); }}}));
        cards_.push_back(std::move(b));
        break;
    }
    case 3: {
        Card a{L"모드 · Mode"};
        a.rows.push_back(seg(L"모드", L"창 위 효과는 '항상 위' 모드에서만 동작", {L"바탕화면", L"항상 위"}, [s] { return s->EffMode() == ModeOnTop ? 1 : 0; },
                             [this](int i) { host_.command(i == 0 ? SC_ModeDesktop : SC_ModeOnTop); }));
        a.rows.back().reselect = [s] { return s->safeMode; };   // safe mode shows 바탕화면: picking it still ends safe mode
        a.rows.push_back(note([s]() -> const wchar_t* {
            if (s->safeMode) return L"안전 모드로 실행 중이에요. 모드를 고르면 안전 모드가 끝나요.";
            return s->mode == ModeDesktop ? L"바탕화면 모드: 눈이 아이콘 위, 모든 창 뒤에 내려요." : nullptr;
        }));
        cards_.push_back(std::move(a));
        Card b{L"창 위 눈 · Window snow"};
        b.rows.push_back(toggle(L"창 위 눈", L"열린 창의 위쪽 가장자리에 눈이 쌓여요", SC_WinSnow, [s] { return s->windowSnow; }, wf));
        b.rows.push_back(toggle(L"실시간 창 추적", L"창을 끄는 동안 눈과 전구가 따라와요 (실험적)", SC_Live, [s] { return s->liveTracking; }, wf));
        b.rows.push_back(seg(L"창 끌 때 눈", L"창을 움직이면 쌓인 눈이 어떻게 될지", {L"미끄러짐", L"붙어 있음"}, [s] { return s->dragSnowSlides ? 0 : 1; },
                             [this](int i) { host_.command(i == 0 ? SC_DragSlides : SC_DragStays); },
                             [s] { return s->WindowFeatures() && s->windowSnow; }));
        cards_.push_back(std::move(b));
        break;
    }
    default: {
        Card a{L"시작 · Startup"};
        a.rows.push_back(toggle(L"로그인 시 자동 실행", L"Windows에 로그인하면 WinterDesk도 함께 시작해요", SC_Login, [this] { return login_; }));
        cards_.push_back(std::move(a));
        Card b{L"선물과 눈사람 · Scene"};
        b.rows.push_back(buttons(L"선물 추가", L"하늘에서 선물 상자가 하나 떨어져요",
                                 {Btn{L"선물 추가", nullptr, true, SC_AddGift, [this] { return host_.canAddGift && host_.canAddGift(); }}}));
        b.rows.push_back(buttons(L"정리하기", L"바닥과 창 위의 물건을 치워요",
                                 {Btn{L"눈덩이·눈사람 지우기", L"한 번 더 누르면 지워요", false, SC_ClearBalls, nullptr},
                                  Btn{L"전부 지우기", L"한 번 더!", false, SC_ClearAll, nullptr}}));
        b.rows.push_back(buttons(L"눈 초기화", L"쌓인 눈을 모두 치우고 처음부터 다시 내려요",
                                 {Btn{L"눈 초기화", L"한 번 더 누르면 초기화", false, SC_ResetSnow, [s] { return s->effectsOn; }}}));
        cards_.push_back(std::move(b));
        Card k{L"단축키 · Shortcuts"};
        Row kr;
        kr.kind = KKeys;
        k.rows.push_back(std::move(kr));
        cards_.push_back(std::move(k));
        Card f;
        f.bare = true;
        Row fr;
        fr.kind = KFooter;
        f.rows.push_back(std::move(fr));
        cards_.push_back(std::move(f));
        break;
    }
    }
    for (Card& c : cards_)
        for (Row& r : c.rows)
            for (Btn& b : r.btns) b.w = std::max(TextW(fBtn_.Get(), b.text), b.confirm ? TextW(fBtn_.Get(), b.confirm) : 0.f) + 36;
}

void SettingsWindow::Layout()
{
    float L = kSide + kPad, R = W_ - kPad;
    float y = kTitle + 6 + 168 + 18;                          // below the hero
    for (Card& c : cards_) {
        c.y = y;
        float in = y + (c.title ? 44.f : 10.f);
        for (Row& r : c.rows) {
            r.shown = !(r.kind == KNote && (!r.note || !r.note()));
            if (!r.shown) continue;
            r.y = in;
            switch (r.kind) {
            case KPalette: r.h = 146; break;
            case KNote: r.h = 52; break;
            case KKeys: r.h = 4 * 36 + 6; break;
            case KFooter: r.h = 44; break;
            default: r.h = 64; break;
            }
            r.cy = r.kind == KPalette ? r.y + 26 : r.y + r.h / 2;
            float cr = R - 20;
            switch (r.kind) {
            case KToggle: r.ctl = RectF(cr - 46, r.cy - 13, cr, r.cy + 13); break;
            case KSlider: r.ctl = RectF(cr - 200, r.cy - 14, cr, r.cy + 14); break;
            case KSegment: { float w = r.opts.size() * 84.f + 6; r.ctl = RectF(cr - w, r.cy - 18, cr, r.cy + 18); break; }
            case KPalette: r.ctl = RectF(L + 20, r.y + 62, cr, r.y + 132); break;
            case KButtons: {
                float x = cr;
                for (int i = (int)r.btns.size() - 1; i >= 0; i--) {
                    r.btns[i].r = RectF(x - r.btns[i].w, r.cy - 17, x, r.cy + 17);
                    x -= r.btns[i].w + 10;
                }
                r.ctl = RectF(x + 10, r.cy - 17, cr, r.cy + 17);
                break;
            }
            default: r.ctl = RectF(L + 20, r.y, cr, r.y + r.h); break;
            }
            in += r.h;
        }
        c.h = in - y + (c.bare ? 0.f : 8.f);
        y += c.h + 16;
    }
    contentH_ = y + 8;
    float maxScroll = std::max(0.f, contentH_ - H_);
    scrollTarget_ = Clampf(scrollTarget_, 0, maxScroll);
    scroll_ = Clampf(scroll_, 0, maxScroll);
}

Row* SettingsWindow::RowOf(int id)
{
    if (id < HIT_ROW) return nullptr;
    int ci = (id - HIT_ROW) / 100, ri = ((id - HIT_ROW) % 100) / 10;
    if (ci >= (int)cards_.size() || ri >= (int)cards_[ci].rows.size()) return nullptr;
    return &cards_[ci].rows[ri];
}

// =============================================================================================
// Input
// =============================================================================================

int SettingsWindow::Hit(float x, float y)
{
    auto in = [](D2D1_RECT_F r, float px, float py, float m = 0) { return px >= r.left - m && px < r.right + m && py >= r.top - m && py < r.bottom + m; };
    if (y < 36 && x >= W_ - 46) return HIT_CLOSE;
    if (y < 36 && x >= W_ - 92 && x < W_ - 46) return HIT_MIN;
    if (x < kSide) {
        for (int i = 0; i < 5; i++)
            if (in(RectF(12, 104 + i * 46.f, kSide - 12, 104 + i * 46.f + 40), x, y)) return HIT_NAV + i;
        if (in(RectF(14, H_ - 132, kSide - 14, H_ - 80), x, y)) return HIT_EFFECTS;
        if (in(RectF(14, H_ - 66, kSide - 14, H_ - 28), x, y)) return HIT_RESET;
        return HIT_NONE;
    }
    if (y < kTitle) return HIT_NONE;
    Layout();
    float cy = y + scroll_;
    for (int ci = 0; ci < (int)cards_.size(); ci++) {
        Card& c = cards_[ci];
        for (int ri = 0; ri < (int)c.rows.size(); ri++) {
            Row& r = c.rows[ri];
            if (!r.shown || (r.en && !r.en())) continue;
            switch (r.kind) {
            case KToggle: if (in(r.ctl, x, cy, 6)) return RowId(ci, ri); break;
            case KSlider: if (in(RectF(r.ctl.left - 4, r.ctl.top - 4, r.ctl.right + 8, r.ctl.bottom + 4), x, cy)) return RowId(ci, ri); break;
            case KSegment:
                if (in(r.ctl, x, cy)) return RowId(ci, ri, 1 + std::max(0, std::min((int)r.opts.size() - 1, (int)((x - r.ctl.left - 3) / 84))));
                break;
            case KPalette: {
                float cw = (r.ctl.right - r.ctl.left - 4 * 10) / 5;
                for (int k = 0; k < 5; k++)
                    if (in(RectF(r.ctl.left + k * (cw + 10), r.ctl.top, r.ctl.left + k * (cw + 10) + cw, r.ctl.bottom), x, cy)) return RowId(ci, ri, 1 + k);
                break;
            }
            case KButtons:
                for (int k = 0; k < (int)r.btns.size(); k++)
                    if (in(r.btns[k].r, x, cy) && (!r.btns[k].en || r.btns[k].en())) return RowId(ci, ri, 1 + k);
                break;
            default: break;
            }
        }
    }
    return HIT_NONE;
}

void SettingsWindow::SliderTo(Row& r, float x)
{
    if (!r.field) return;
    float f = Clampf((x - r.ctl.left) / (r.ctl.right - r.ctl.left), 0, 1);
    int v = r.lo + (int)std::lround(f * (r.hi - r.lo) / r.step) * r.step;
    v = std::max(r.lo, std::min(r.hi, v));
    if (v == *r.field) return;
    *r.field = v;
    knobApply_ = knobSave_ = true;
    FlushKnobs(false);
}

/// Live knobs: the scene follows within 100 ms, settings.ini at most every 300 ms (and on release).
void SettingsWindow::FlushKnobs(bool force)
{
    if (!knobApply_ && !knobSave_) return;
    double now = NowSec();
    bool doApply = knobApply_ && (force || now - lastApply_ >= 0.1);
    bool doSave = knobSave_ && (force || now - lastSave_ >= 0.3);
    if (!doApply && !doSave) return;
    if (host_.apply) host_.apply(doSave);
    lastApply_ = now;
    knobApply_ = false;
    if (doSave) { lastSave_ = now; knobSave_ = false; }
}

void SettingsWindow::MouseDown(float x, float y)
{
    int id = Hit(x, y);
    pressed_ = id;
    if (id != armedId_ && id != HIT_NONE) armedId_ = HIT_NONE;
    Row* r = RowOf(id);
    if (r && r->kind == KSlider) {
        dragSlider_ = id;
        SetCapture(hwnd_);
        SliderTo(*r, x);
    } else if (id != HIT_NONE) {
        SetCapture(hwnd_);
    }
    InvalidateRect(hwnd_, nullptr, FALSE);
}

void SettingsWindow::MouseMove(float x, float y)
{
    mx_ = x;
    my_ = y;
    if (dragSlider_ != HIT_NONE) {
        Layout();
        if (Row* r = RowOf(dragSlider_)) SliderTo(*r, x);
        return;
    }
    hot_ = Hit(x, y);
}

void SettingsWindow::MouseUp(float x, float y)
{
    int was = pressed_, slider = dragSlider_;
    pressed_ = dragSlider_ = HIT_NONE;              // before ReleaseCapture (WM_CAPTURECHANGED)
    if (GetCapture() == hwnd_) ReleaseCapture();
    if (slider != HIT_NONE) {
        Row* r = RowOf(slider);
        FlushKnobs(true);
        if (r && r->field) Logf(L"TEST settings slider '%s' = %d", r->label, *r->field);
        return;
    }
    if (was != HIT_NONE && Hit(x, y) == was) Activate(was);
    if (hwnd_) InvalidateRect(hwnd_, nullptr, FALSE);
}

void SettingsWindow::Activate(int id)
{
    Settings* s = host_.settings;
    if (!s || !host_.command) return;
    if (id == HIT_CLOSE) { Close(); return; }
    if (id == HIT_MIN) { ShowWindow(hwnd_, SW_MINIMIZE); return; }
    if (id >= HIT_NAV && id < HIT_NAV + 5) { SetTab(id - HIT_NAV); return; }
    if (id == HIT_EFFECTS) { host_.command(SC_Effects); Logf(L"TEST settings effects -> %d", s->effectsOn ? 1 : 0); return; }
    if (id == HIT_RESET) {
        if (!Armed(id)) { armedId_ = id; armedAt_ = NowSec(); return; }
        armedId_ = HIT_NONE;
        host_.command(SC_ResetEffects);
        Logf(L"TEST settings reset to defaults");
        return;
    }
    Row* r = RowOf(id);
    if (!r) return;
    int sub = id % 10;
    switch (r->kind) {
    case KToggle:
        host_.command(r->cmd);
        Logf(L"TEST settings toggle '%s' -> %d", r->label, r->on && r->on() ? 1 : 0);
        break;
    case KSegment:
        if (sub >= 1 && r->get && r->set && (r->get() != sub - 1 || (r->reselect && r->reselect()))) {
            r->set(sub - 1);
            Logf(L"TEST settings segment '%s' -> %d", r->label, sub - 1);
        }
        break;
    case KPalette:
        if (sub >= 1 && s->lightStyle != sub - 1) {
            s->lightStyle = sub - 1;
            if (host_.apply) host_.apply(true);
            Logf(L"TEST settings light style -> %d", s->lightStyle);
        }
        break;
    case KButtons: {
        if (sub < 1 || sub > (int)r->btns.size()) break;
        Btn& b = r->btns[sub - 1];
        if (b.confirm && !Armed(id)) { armedId_ = id; armedAt_ = NowSec(); break; }
        armedId_ = HIT_NONE;
        Logf(L"TEST settings button '%s'", b.text);
        if (b.cmd == SC_EditLights) {
            // the coach mark and the edit overlay need the screen: get out of the way, but only once
            // Light Edit really started (otherwise the window stays and the app's toast explains why)
            bool on = host_.enterLightEdit && host_.enterLightEdit();
            Logf(L"TEST settings light edit started=%d", on ? 1 : 0);
            if (on && hwnd_) ShowWindow(hwnd_, SW_MINIMIZE);
        } else {
            host_.command(b.cmd);
        }
        break;
    }
    default: break;
    }
}

// =============================================================================================
// Device
// =============================================================================================

ComPtr<ID2D1LinearGradientBrush> SettingsWindow::MakeLin(D2D1_COLOR_F a, D2D1_COLOR_F b)
{
    D2D1_GRADIENT_STOP st[2] = {{0, a}, {1, b}};
    ComPtr<ID2D1GradientStopCollection> c;
    ComPtr<ID2D1LinearGradientBrush> br;
    if (SUCCEEDED(rt_->CreateGradientStopCollection(st, 2, &c)))
        rt_->CreateLinearGradientBrush(D2D1::LinearGradientBrushProperties(Point2F(0, 0), Point2F(0, 1)), c.Get(), &br);
    return br;
}

ComPtr<ID2D1RadialGradientBrush> SettingsWindow::MakeGlow(D2D1_COLOR_F c)
{
    D2D1_GRADIENT_STOP st[3] = {{0, WithA(c, 1)}, {0.35f, WithA(c, 0.45f)}, {1, WithA(c, 0)}};
    ComPtr<ID2D1GradientStopCollection> sc;
    ComPtr<ID2D1RadialGradientBrush> br;
    if (SUCCEEDED(rt_->CreateGradientStopCollection(st, 3, &sc)))
        rt_->CreateRadialGradientBrush(D2D1::RadialGradientBrushProperties(Point2F(0, 0), Point2F(0, 0), 1, 1), sc.Get(), &br);
    return br;
}

bool SettingsWindow::CreateDevice()
{
    if (rt_) return true;
    RECT cr;
    GetClientRect(hwnd_, &cr);
    D2D1_RENDER_TARGET_PROPERTIES p = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), 96.f * s_, 96.f * s_);
    // IMMEDIATELY: EndDraw never waits for vsync (this window shares the UI thread with the overlay)
    D2D1_HWND_RENDER_TARGET_PROPERTIES hp = D2D1::HwndRenderTargetProperties(
        hwnd_, D2D1::SizeU(std::max<LONG>(1, cr.right), std::max<LONG>(1, cr.bottom)), D2D1_PRESENT_OPTIONS_IMMEDIATELY);
    HRESULT hr = D2DFactory()->CreateHwndRenderTarget(p, hp, &rt_);
    if (FAILED(hr)) { Logf(L"settings: render target creation failed (0x%08lx)", (unsigned long)hr); rt_.Reset(); return false; }
    rt_->SetDpi(96.f * s_, 96.f * s_);
    rt_->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    if (FAILED(rt_->CreateSolidColorBrush(cWhite, &brush_))) { DiscardDevice(); return false; }
    bgLin_ = MakeLin(cBg0, cBg1);
    redLin_ = MakeLin(cRedHi, cRed);
    mugLin_ = MakeLin(Hex(0xF0505E), Hex(0xB8293A));
    treeLin_ = MakeLin(Hex(0x2C9C62), Hex(0x15573A));
    capLin_ = MakeLin(cSnow, Hex(0xD4E4EF));
    cardLin_ = MakeLin(D2D1::ColorF(1, 1, 1, 0.055f), D2D1::ColorF(1, 1, 1, 0.02f));
    const uint32_t hero[5][2] = {{0x1D4150, 0x152C27}, {0x4C1D27, 0x172D25}, {0x1F4A33, 0x132820}, {0x1D3550, 0x14281F}, {0x45361A, 0x15291F}};
    for (int i = 0; i < 5; i++) heroLin_[i] = MakeLin(Hex(hero[i][0]), Hex(hero[i][1]));
    glowGold_ = MakeGlow(cGold);
    glowRed_ = MakeGlow(Hex(0xFF3B3B));
    glowWhite_ = MakeGlow(cSnow);
    glowBlue_ = MakeGlow(Hex(0x7FB8FF));
    for (int i = 0; i < kBulbColorCount; i++) glowBulb_[i] = MakeGlow(kBulb[i]);
    {
        D2D1_GRADIENT_STOP st[2] = {{0, cSnow}, {1, Hex(0xC9DAE6)}};
        ComPtr<ID2D1GradientStopCollection> sc;
        if (SUCCEEDED(rt_->CreateGradientStopCollection(st, 2, &sc)))
            rt_->CreateRadialGradientBrush(D2D1::RadialGradientBrushProperties(Point2F(0, 0), Point2F(0, 0), 1, 1), sc.Get(), &snowBall_);
    }
    return true;
}

void SettingsWindow::DiscardDevice()
{
    brush_.Reset();
    bgLin_.Reset(); redLin_.Reset(); mugLin_.Reset(); treeLin_.Reset(); capLin_.Reset(); cardLin_.Reset();
    for (auto& b : heroLin_) b.Reset();
    glowGold_.Reset(); glowRed_.Reset(); glowWhite_.Reset(); glowBlue_.Reset(); snowBall_.Reset();
    for (auto& b : glowBulb_) b.Reset();
    rt_.Reset();
}

/// Device-independent resources (geometry in illustration units, strokes, text formats): built once.
void SettingsWindow::EnsureGeometry()
{
    if (round_) return;
    D2DFactory()->CreateStrokeStyle(D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND,
                                                                D2D1_LINE_JOIN_ROUND), nullptr, 0, &round_);
    float dash[2] = {1.1f, 1.1f};
    D2DFactory()->CreateStrokeStyle(D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT,
                                                                D2D1_LINE_JOIN_ROUND, 10, D2D1_DASH_STYLE_CUSTOM, 0.4f), dash, 2, &cane_);
    steam_ = Geo([](ID2D1GeometrySink* s) {
        s->BeginFigure(Point2F(0, 0), D2D1_FIGURE_BEGIN_HOLLOW);
        s->AddBezier(Bz(-6, -7, 6, -14, 0, -21));
        s->AddBezier(Bz(-6, -28, 6, -35, 0, -42));
        s->EndFigure(D2D1_FIGURE_END_OPEN);
    });
    caneGeo_ = Geo([](ID2D1GeometrySink* s) {
        s->BeginFigure(Point2F(153, 72), D2D1_FIGURE_BEGIN_HOLLOW);
        s->AddLine(Point2F(153, 30));
        s->AddArc(D2D1::ArcSegment(Point2F(171, 30), D2D1::SizeF(9, 9), 0, D2D1_SWEEP_DIRECTION_CLOCKWISE, D2D1_ARC_SIZE_SMALL));
        s->AddLine(Point2F(171, 38));
        s->EndFigure(D2D1_FIGURE_END_OPEN);
    });
    auto antler = [](float k) {                       // k = +1 left, -1 mirrored (x' = 260 - x)
        auto X = [k](float x) { return k > 0 ? x : 260 - x; };
        return Geo([&](ID2D1GeometrySink* s) {
            s->BeginFigure(Point2F(X(116), 54), D2D1_FIGURE_BEGIN_HOLLOW);
            s->AddBezier(Bz(X(110), 40, X(100), 28, X(86), 14));
            s->EndFigure(D2D1_FIGURE_END_OPEN);
            s->BeginFigure(Point2F(X(104), 36), D2D1_FIGURE_BEGIN_HOLLOW);
            s->AddBezier(Bz(X(97), 36, X(90), 39, X(83), 44));
            s->EndFigure(D2D1_FIGURE_END_OPEN);
            s->BeginFigure(Point2F(X(95), 25), D2D1_FIGURE_BEGIN_HOLLOW);
            s->AddBezier(Bz(X(96), 17, X(99), 11, X(104), 6));
            s->EndFigure(D2D1_FIGURE_END_OPEN);
        });
    };
    antlerL_ = antler(1);
    antlerR_ = antler(-1);
    neck_ = Geo([](ID2D1GeometrySink* s) {
        s->BeginFigure(Point2F(103, 104), D2D1_FIGURE_BEGIN_FILLED);
        s->AddBezier(Bz(98, 136, 90, 156, 84, 172));
        s->AddLine(Point2F(176, 172));
        s->AddBezier(Bz(170, 156, 162, 136, 157, 104));
        s->EndFigure(D2D1_FIGURE_END_CLOSED);
    });
    smile_ = Geo([](ID2D1GeometrySink* s) {
        s->BeginFigure(Point2F(121, 111), D2D1_FIGURE_BEGIN_HOLLOW);
        s->AddQuadraticBezier(Qz(130, 118, 139, 111));
        s->EndFigure(D2D1_FIGURE_END_OPEN);
    });
    star_ = Geo([](ID2D1GeometrySink* s) {
        for (int i = 0; i < 10; i++) {
            float a = -kPi / 2 + i * kPi / 5, r = i % 2 ? 5.6f : 13.f;
            D2D1_POINT_2F p = Point2F(std::cos(a) * r, std::sin(a) * r);
            if (i == 0) s->BeginFigure(p, D2D1_FIGURE_BEGIN_FILLED); else s->AddLine(p);
        }
        s->EndFigure(D2D1_FIGURE_END_CLOSED);
    });
    const float tiers[3][3] = {{26, 76, 34}, {48, 112, 52}, {78, 146, 68}};   // top, bottom, half width
    for (int i = 0; i < 3; i++) {
        float top = tiers[i][0], bot = tiers[i][1], hw = tiers[i][2];
        tier_[i] = Geo([&](ID2D1GeometrySink* s) {
            s->BeginFigure(Point2F(130, top), D2D1_FIGURE_BEGIN_FILLED);
            s->AddQuadraticBezier(Qz(130 - hw * 0.45f, bot - (bot - top) * 0.35f, 130 - hw, bot));
            s->AddQuadraticBezier(Qz(130, bot + 12, 130 + hw, bot));
            s->AddQuadraticBezier(Qz(130 + hw * 0.45f, bot - (bot - top) * 0.35f, 130, top));
            s->EndFigure(D2D1_FIGURE_END_CLOSED);
        });
        float gy = bot - (bot - top) * 0.32f, gx = hw * 0.62f;
        garland_[i] = Geo([&](ID2D1GeometrySink* s) {
            s->BeginFigure(Point2F(130 - gx, gy - 4), D2D1_FIGURE_BEGIN_HOLLOW);
            s->AddQuadraticBezier(Qz(130, gy + 14, 130 + gx, gy - 8));
            s->EndFigure(D2D1_FIGURE_END_OPEN);
        });
    }
    cap_ = Geo([](ID2D1GeometrySink* s) {
        s->BeginFigure(Point2F(34, 52), D2D1_FIGURE_BEGIN_FILLED);
        s->AddBezier(Bz(34, 42, 46, 37, 58, 39));
        s->AddBezier(Bz(70, 31, 86, 34, 98, 37));
        s->AddBezier(Bz(112, 29, 128, 32, 142, 36));
        s->AddBezier(Bz(156, 29, 172, 32, 186, 37));
        s->AddBezier(Bz(200, 31, 216, 36, 223, 43));
        s->AddBezier(Bz(228, 47, 227, 54, 221, 54));
        s->AddLine(Point2F(40, 54));
        s->AddBezier(Bz(36, 54, 34, 54, 34, 52));
        s->EndFigure(D2D1_FIGURE_END_CLOSED);
    });
    icicles_ = Geo([](ID2D1GeometrySink* s) {
        const float xs[6] = {58, 84, 120, 150, 176, 204}, len[6] = {9, 6, 11, 7, 10, 6};
        for (int i = 0; i < 6; i++) {
            s->BeginFigure(Point2F(xs[i] - 3.5f, 53), D2D1_FIGURE_BEGIN_FILLED);
            s->AddLine(Point2F(xs[i], 53 + len[i]));
            s->AddLine(Point2F(xs[i] + 3.5f, 53));
            s->EndFigure(D2D1_FIGURE_END_CLOSED);
        }
    });
    carrot_ = Geo([](ID2D1GeometrySink* s) {
        s->BeginFigure(Point2F(181, 57), D2D1_FIGURE_BEGIN_FILLED);
        s->AddLine(Point2F(199, 61));
        s->AddLine(Point2F(181, 62));
        s->EndFigure(D2D1_FIGURE_END_CLOSED);
    });
    hatIcon_ = Geo([](ID2D1GeometrySink* s) {
        s->BeginFigure(Point2F(-7, 3), D2D1_FIGURE_BEGIN_FILLED);
        s->AddBezier(Bz(-6, -5, -1, -8, 4, -8));
        s->AddBezier(Bz(7, -8, 8, -4, 8, -1));
        s->AddLine(Point2F(7, 3));
        s->EndFigure(D2D1_FIGURE_END_CLOSED);
    });
    fTitle_ = Fmt(12.5f, DWRITE_FONT_WEIGHT_SEMI_BOLD);
    fLogo_ = Fmt(18, DWRITE_FONT_WEIGHT_BOLD);
    fLogoSub_ = Fmt(11, DWRITE_FONT_WEIGHT_NORMAL);
    fNav_ = Fmt(14, DWRITE_FONT_WEIGHT_SEMI_BOLD);
    fKicker_ = Fmt(11, DWRITE_FONT_WEIGHT_BOLD);
    fHeroTitle_ = Fmt(25, DWRITE_FONT_WEIGHT_BOLD);
    fHeroDesc_ = Fmt(13, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_TEXT_ALIGNMENT_LEADING, DWRITE_PARAGRAPH_ALIGNMENT_NEAR, true);
    fCardTitle_ = Fmt(12.5f, DWRITE_FONT_WEIGHT_BOLD);
    fLabel_ = Fmt(14, DWRITE_FONT_WEIGHT_SEMI_BOLD);
    fHelp_ = Fmt(12, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_TEXT_ALIGNMENT_LEADING, DWRITE_PARAGRAPH_ALIGNMENT_NEAR, true);
    fValue_ = Fmt(12.5f, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_TEXT_ALIGNMENT_CENTER);
    fSeg_ = Fmt(13, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_TEXT_ALIGNMENT_CENTER);
    fBtn_ = Fmt(13, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_TEXT_ALIGNMENT_CENTER);
    fChip_ = Fmt(12, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_TEXT_ALIGNMENT_CENTER);
    fKey_ = Fmt(11.5f, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_TEXT_ALIGNMENT_CENTER);
    fFoot_ = Fmt(12, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_TEXT_ALIGNMENT_CENTER);
    fNote_ = Fmt(12.5f, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_TEXT_ALIGNMENT_LEADING, DWRITE_PARAGRAPH_ALIGNMENT_CENTER, true);
    fBubble_ = Fmt(12, DWRITE_FONT_WEIGHT_BOLD, DWRITE_TEXT_ALIGNMENT_CENTER);
}

// =============================================================================================
// Drawing helpers
// =============================================================================================

void SettingsWindow::Glow(ID2D1RadialGradientBrush* g, float x, float y, float r, float opacity)
{
    if (!g || r <= 0) return;
    g->SetCenter(Point2F(x, y));
    g->SetGradientOriginOffset(Point2F(0, 0));
    g->SetRadiusX(r);
    g->SetRadiusY(r);
    g->SetOpacity(Clampf(opacity, 0, 1));
    rt_->FillEllipse(D2D1::Ellipse(Point2F(x, y), r, r), g);
}

ID2D1Brush* SettingsWindow::Lin(ID2D1LinearGradientBrush* b, float x0, float y0, float x1, float y1, D2D1_COLOR_F fallback)
{
    if (!b) return B(fallback);
    b->SetStartPoint(Point2F(x0, y0));
    b->SetEndPoint(Point2F(x1, y1));
    b->SetOpacity(1);
    return b;
}

void SettingsWindow::Text(const wchar_t* t, IDWriteTextFormat* f, D2D1_RECT_F r, D2D1_COLOR_F c)
{
    if (!f || !t) return;
    if (f == fHelp_.Get() || f == fHeroDesc_.Get() || f == fNote_.Get()) {
        // Hangul syllables are break opportunities for DirectWrite; Korean wraps at spaces (keep-all):
        // word joiners between the other characters. All texts are static literals, cached by address.
        auto it = keepAll_.find(t);
        if (it == keepAll_.end()) {
            std::wstring k;
            for (const wchar_t* p = t; *p; p++) {
                k += *p;
                if (p[1] && *p != L' ' && p[1] != L' ') k += L'\u2060';
            }
            it = keepAll_.emplace(t, std::move(k)).first;
        }
        t = it->second.c_str();
    }
    rt_->DrawText(t, (UINT32)wcslen(t), f, r, B(c), D2D1_DRAW_TEXT_OPTIONS_CLIP);   // monochrome glyphs (❄ in the text colour)
}

void SettingsWindow::DrawFlake(float cx, float cy, float r, D2D1_COLOR_F c, float w)
{
    for (int k = 0; k < 6; k++) {
        float a = k * kPi / 3 + kPi / 2;
        float ex = cx + std::cos(a) * r, ey = cy - std::sin(a) * r;
        Ln(cx, cy, ex, ey, c, w);
        float bx = cx + std::cos(a) * r * 0.58f, by = cy - std::sin(a) * r * 0.58f;
        for (int sg = -1; sg <= 1; sg += 2) {
            float b = a + sg * 0.75f;
            Ln(bx, by, bx + std::cos(b) * r * 0.32f, by - std::sin(b) * r * 0.32f, c, w);
        }
    }
}

void SettingsWindow::DrawSparkle(float cx, float cy, float r, D2D1_COLOR_F c)
{
    Ln(cx - r, cy, cx + r, cy, c, 1.4f);
    Ln(cx, cy - r, cx, cy + r, c, 1.4f);
    Ell(cx, cy, r * 0.22f, r * 0.22f, c);
}

void SettingsWindow::DrawBulb(float x, float y, float r, int color, float bright)
{
    color = std::max(0, std::min(kBulbColorCount - 1, color));
    Glow(glowBulb_[color].Get(), x, y, r * 3.6f, 0.25f + 0.5f * bright);
    D2D1_COLOR_F c = Mix(Shade(kBulb[color], 0.55f), kBulb[color], 0.35f + 0.65f * bright);
    Ell(x, y, r, r * 1.15f, c);
    Ell(x - r * 0.35f, y - r * 0.4f, r * 0.32f, r * 0.32f, D2D1::ColorF(1, 1, 1, 0.35f + 0.4f * bright));
}

void SettingsWindow::DrawToggle(D2D1_RECT_F r, float t, float alpha, bool hot)
{
    float h = r.bottom - r.top;
    D2D1_COLOR_F off = D2D1::ColorF(1, 1, 1, 0.16f), on = cRed;
    if (t > 0.5f) Glow(glowRed_.Get(), (r.left + r.right) / 2, (r.top + r.bottom) / 2, 34, 0.18f * t * alpha);
    RR(r, h / 2, Fade(Mix(off, on, t), alpha));
    if (hot) RRS(r, h / 2, D2D1::ColorF(1, 1, 1, 0.22f * alpha), 1);
    float kx = r.left + h / 2 + t * (r.right - r.left - h);
    Ell(kx, (r.top + r.bottom) / 2 + 1, h / 2 - 3, h / 2 - 3, D2D1::ColorF(0, 0, 0, 0.25f * alpha));
    Ell(kx, (r.top + r.bottom) / 2, h / 2 - 3.5f, h / 2 - 3.5f, Fade(cSnow, alpha));
}

void SettingsWindow::DrawNavIcon(int i, float cx, float cy, D2D1_COLOR_F c)
{
    switch (i) {
    case 0: DrawFlake(cx, cy, 8, c, 1.6f); break;
    case 1:
        Push(D2D1::Matrix3x2F::Translation(cx, cy));
        FillG(hatIcon_.Get(), Fade(c, 0.6f));
        Pop();
        RR(RectF(cx - 9, cy + 2, cx + 9, cy + 7), 2.5f, c);
        Ell(cx + 8.5f, cy - 1, 2.6f, 2.6f, c);
        break;
    case 2:
        Ln(cx, cy - 9, cx, cy - 6, c, 1.6f);
        RR(RectF(cx - 3.2f, cy - 6.5f, cx + 3.2f, cy - 2.5f), 1, Fade(c, 0.7f));
        Ell(cx, cy + 3, 5.5f, 6.5f, c);
        break;
    case 3:
        RRS(RectF(cx - 8, cy - 5, cx + 8, cy + 8), 2.5f, c, 1.6f);
        Ln(cx - 8, cy - 1, cx + 8, cy - 1, Fade(c, 0.6f), 1.2f);
        RR(RectF(cx - 9.5f, cy - 9, cx + 9.5f, cy - 4.5f), 2.2f, c);
        break;
    default:
        for (int k = 0; k < 8; k++) {
            float a = k * kPi / 4;
            Ln(cx + std::cos(a) * 5.5f, cy + std::sin(a) * 5.5f, cx + std::cos(a) * 8.5f, cy + std::sin(a) * 8.5f, c, 2.6f);
        }
        EllS(cx, cy, 5.5f, 5.5f, c, 2.2f);
        Ell(cx, cy, 2, 2, c);
        break;
    }
}

// =============================================================================================
// Render
// =============================================================================================

void SettingsWindow::Render()
{
    if (!hwnd_ || IsIconic(hwnd_)) return;
    EnsureGeometry();
    if (!CreateDevice()) return;
    double now = NowSec();
    float dt = (float)std::min(0.1, std::max(0.0, now - last_));
    last_ = now;
    t_ = (float)(now - t0_);
    scroll_ = Ease(scroll_, scrollTarget_, dt, 0.06f);
    if (std::fabs(scroll_ - scrollTarget_) < 0.3f) scroll_ = scrollTarget_;
    Layout();
    // eased animation targets
    Anim(-1, (float)tab_) = Ease(Anim(-1, (float)tab_), (float)tab_, dt, 0.05f);
    for (int i = 0; i < 5; i++) { float& a = Anim(-10 - i, 0); a = Ease(a, hot_ == HIT_NAV + i ? 1.f : 0.f, dt); }
    for (int ci = 0; ci < (int)cards_.size(); ci++)
        for (int ri = 0; ri < (int)cards_[ci].rows.size(); ri++) {
            Row& r = cards_[ci].rows[ri];
            int id = RowId(ci, ri);
            float& en = Anim(id + 100000, r.en && !r.en() ? 0.f : 1.f);
            en = Ease(en, r.en && !r.en() ? 0.f : 1.f, dt, 0.06f);
            if (r.kind == KToggle) { float& a = Anim(id, r.on && r.on() ? 1.f : 0.f); a = Ease(a, r.on && r.on() ? 1.f : 0.f, dt); }
            if (r.kind == KSegment && r.get) { float& a = Anim(id, (float)r.get()); a = Ease(a, (float)r.get(), dt); }
            if (r.kind == KSlider) { float& a = Anim(id, 0); a = Ease(a, dragSlider_ == id || hot_ == id ? 1.f : 0.f, dt); }
        }
    { float& a = Anim(HIT_EFFECTS, host_.settings->effectsOn ? 1.f : 0.f); a = Ease(a, host_.settings->effectsOn ? 1.f : 0.f, dt); }

    rt_->BeginDraw();
    base_ = D2D1::Matrix3x2F::Identity();
    rt_->SetTransform(base_);
    DrawBackground();
    DrawSidebar();

    rt_->PushAxisAlignedClip(RectF(kSide, kTitle, W_, H_), D2D1_ANTIALIAS_MODE_ALIASED);
    base_ = D2D1::Matrix3x2F::Translation(0, -scroll_);
    rt_->SetTransform(base_);
    DrawHero(kTitle + 6);
    for (int ci = 0; ci < (int)cards_.size(); ci++) DrawCard(ci, cards_[ci]);
    base_ = D2D1::Matrix3x2F::Identity();
    rt_->SetTransform(base_);
    rt_->PopAxisAlignedClip();
    DrawTitleBar();
    // slim scrollbar
    float view = H_ - kTitle, maxScroll = contentH_ - H_;
    if (maxScroll > 1) {
        float trackH = view - 16, barH = std::max(36.f, trackH * view / (contentH_ - kTitle));
        float y = kTitle + 8 + (trackH - barH) * (scroll_ / maxScroll);
        RR(RectF(W_ - 8, y, W_ - 4, y + barH), 2, D2D1::ColorF(1, 1, 1, mx_ > W_ - 40 ? 0.32f : 0.16f));
    }
    HRESULT hr = rt_->EndDraw();
    if (hr == D2DERR_RECREATE_TARGET) { Logf(L"settings: device lost, recreating"); DiscardDevice(); InvalidateRect(hwnd_, nullptr, FALSE); }
    else if (FAILED(hr)) Logf(L"settings: EndDraw failed (0x%08lx)", (unsigned long)hr);

    if (logLayout_) {
        logLayout_ = false;
        Logf(L"TEST settings layout tab=%d scale=%.2f client=%.0fx%.0f px (DIP %.0fx%.0f) scroll=%.0f", tab_, s_, W_ * s_, H_ * s_, W_, H_, scroll_);
        for (int i = 0; i < 5; i++) Logf(L"TEST settings ctl nav%d center=%d,%d", i, (int)((kSide / 2) * s_), (int)((104 + i * 46 + 20) * s_));
        Logf(L"TEST settings ctl effects center=%d,%d", (int)((kSide - 14 - 30) * s_), (int)((H_ - 106) * s_));
        for (int ci = 0; ci < (int)cards_.size(); ci++)
            for (int ri = 0; ri < (int)cards_[ci].rows.size(); ri++) {
                const Row& r = cards_[ci].rows[ri];
                if (!r.shown || r.kind == KNote || r.kind == KKeys || r.kind == KFooter) continue;
                Logf(L"TEST settings ctl '%s' kind=%d rect=%d,%d,%d,%d (client px)", r.label, (int)r.kind, (int)(r.ctl.left * s_),
                     (int)((r.ctl.top - scroll_) * s_), (int)(r.ctl.right * s_), (int)((r.ctl.bottom - scroll_) * s_));
            }
    }
}

void SettingsWindow::DrawBackground()
{
    rt_->FillRectangle(RectF(0, 0, W_, H_), Lin(bgLin_.Get(), 0, 0, W_ * 0.35f, H_, cBg0));
    Glow(glowGold_.Get(), W_ - 140, 30, 300, 0.07f);
    Glow(glowRed_.Get(), kSide + 60, H_ + 40, 320, 0.06f);
    for (BgFlake& f : bg_) {
        float y = std::fmod(f.y + t_ * f.speed, H_ + 20) - 10;
        float x = std::fmod(f.x + std::sin(t_ * 0.4f + f.phase) * 10 + W_ * 4, W_);
        D2D1_COLOR_F c = Fade(cSnow, f.alpha);
        if (f.star) DrawFlake(x, y, f.r, c, 1);
        else Ell(x, y, f.r, f.r, c);
    }
}

void SettingsWindow::DrawSidebar()
{
    rt_->FillRectangle(RectF(0, 0, kSide, H_), B(D2D1::ColorF(0, 0, 0, 0.16f)));
    rt_->FillRectangle(RectF(kSide - 1, 0, kSide, H_), B(D2D1::ColorF(1, 1, 1, 0.06f)));
    // logo: cranberry tile with a white flake, wordmark
    D2D1_RECT_F tile = RectF(20, 26, 58, 64);
    Glow(glowRed_.Get(), 39, 45, 34, 0.25f);
    rt_->FillRoundedRectangle(D2D1::RoundedRect(tile, 11, 11), Lin(redLin_.Get(), 20, 26, 58, 64, cRed));
    RRS(tile, 11, D2D1::ColorF(1, 1, 1, 0.18f), 1);
    DrawFlake(39, 45, 11, cSnow, 1.8f);
    Text(L"WinterDesk", fLogo_.Get(), RectF(68, 24, kSide, 48), cCream);
    Text(L"설정 · Settings", fLogoSub_.Get(), RectF(69, 46, kSide, 64), cMuted);
    // nav: an eased pill slides to the selected page
    float sel = Anim(-1, (float)tab_);
    float py = 104 + sel * 46;
    D2D1_RECT_F pill = RectF(12, py, kSide - 12, py + 40);
    for (int g = 3; g >= 1; g--) RR(RectF(pill.left - g * 2.f, pill.top - g * 2.f, pill.right + g * 2.f, pill.bottom + g * 2.f), 12 + g * 2.f, Fade(cRed, 0.03f));
    RR(pill, 12, Fade(cRed, 0.20f));
    RRS(pill, 12, Fade(cRed, 0.45f), 1);
    RR(RectF(12, py + 11, 15, py + 29), 1.5f, cRed);
    for (int i = 0; i < 5; i++) {
        float y = 104 + i * 46.f;
        float hov = Anim(-10 - i, 0), on = std::max(0.f, 1 - std::fabs(sel - i));
        if (hov > 0.01f && i != tab_) RR(RectF(12, y, kSide - 12, y + 40), 12, D2D1::ColorF(1, 1, 1, 0.05f * hov));
        D2D1_COLOR_F c = Mix(cMuted, cCream, std::max(on, hov * 0.6f));
        DrawNavIcon(i, 38, y + 20, c);
        Text(kNav[i], fNav_.Get(), RectF(60, y, kSide - 16, y + 40), c);
    }
    // bottom: master switch + reset
    D2D1_RECT_F card = RectF(14, H_ - 132, kSide - 14, H_ - 80);
    RR(card, 14, D2D1::ColorF(1, 1, 1, 0.05f));
    RRS(card, 14, D2D1::ColorF(1, 1, 1, hot_ == HIT_EFFECTS ? 0.16f : 0.07f), 1);
    Text(L"효과 켜기", fLabel_.Get(), RectF(28, card.top + 5, kSide - 70, card.top + 29), cCream);
    Text(L"Ctrl+Alt+Shift+E", fLogoSub_.Get(), RectF(28, card.top + 27, kSide - 70, card.bottom - 6), cMuted);
    DrawToggle(RectF(kSide - 14 - 14 - 44, card.top + 13, kSide - 14 - 14, card.top + 39), Anim(HIT_EFFECTS, 1), 1, hot_ == HIT_EFFECTS);
    D2D1_RECT_F rb = RectF(14, H_ - 66, kSide - 14, H_ - 28);
    bool armed = Armed(HIT_RESET);
    if (armed) { Glow(glowRed_.Get(), (rb.left + rb.right) / 2, (rb.top + rb.bottom) / 2, 80, 0.2f); RR(rb, 19, cRed); }
    else RR(rb, 19, D2D1::ColorF(1, 1, 1, hot_ == HIT_RESET ? 0.10f : 0.05f));
    RRS(rb, 19, D2D1::ColorF(1, 1, 1, armed ? 0.3f : 0.12f), 1);
    Text(armed ? L"한 번 더 누르면 초기화" : L"↺  기본값으로", fBtn_.Get(), rb, armed ? cCream : Mix(cMuted, cCream, hot_ == HIT_RESET ? 1.f : 0.5f));
}

void SettingsWindow::DrawTitleBar()
{
    // soft fade where content scrolls under the title strip
    D2D1_COLOR_F top = Mix(cBg0, cBg1, 0.08f);
    rt_->FillRectangle(RectF(kSide, 0, W_, kTitle), B(top));
    for (int i = 0; i < 10; i++) rt_->FillRectangle(RectF(kSide, kTitle + i * 1.6f, W_, kTitle + (i + 1) * 1.6f), B(WithA(top, 0.9f * (1 - i / 10.f))));
    Text(L"WinterDesk 설정", fTitle_.Get(), RectF(kSide + kPad, 0, W_ - 120, 36), Fade(cMuted, 0.9f));
    // minimize / close
    D2D1_RECT_F mn = RectF(W_ - 92, 0, W_ - 46, 36), cl = RectF(W_ - 46, 0, W_, 36);
    if (hot_ == HIT_MIN) rt_->FillRectangle(mn, B(D2D1::ColorF(1, 1, 1, pressed_ == HIT_MIN ? 0.14f : 0.08f)));
    if (hot_ == HIT_CLOSE) rt_->FillRectangle(cl, B(pressed_ == HIT_CLOSE ? cRedLo : cRed));
    D2D1_COLOR_F g = hot_ == HIT_CLOSE ? cWhite : cCream;
    Ln(W_ - 74, 18, W_ - 64, 18, Fade(cCream, 0.85f), 1.2f);
    Ln(W_ - 28, 13, W_ - 18, 23, g, 1.2f);
    Ln(W_ - 28, 23, W_ - 18, 13, g, 1.2f);
}

void SettingsWindow::DrawHero(float y)
{
    float L = kSide + kPad, R = W_ - kPad, h = 168;
    D2D1_RECT_F hr = RectF(L, y, R, y + h);
    D2D1_ROUNDED_RECT rr = D2D1::RoundedRect(hr, 18, 18);
    rt_->FillRoundedRectangle(rr, Lin(heroLin_[tab_].Get(), L, y, R, y + h, cCard));
    rt_->PushAxisAlignedClip(hr, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
    ID2D1RadialGradientBrush* glow[5] = {glowWhite_.Get(), glowRed_.Get(), glowGold_.Get(), glowBlue_.Get(), glowGold_.Get()};
    float glowA[5] = {0.10f, 0.20f, 0.20f, 0.16f, 0.14f};
    Glow(glow[tab_], R - 135, y + 90, 150, glowA[tab_]);
    // drifting flakes inside the banner (more on the snow page)
    int n = tab_ == 0 ? 26 : 12;
    for (int k = 0; k < n; k++) {
        float sp = 9 + (k % 4) * 5.f;
        float fx = L + std::fmod(k * 73.3f + std::sin(t_ * 0.5f + k) * 6, R - L);
        float fy = y + std::fmod(k * 37.f + t_ * sp, h + 10) - 5;
        float r = 1 + (k % 3) * 0.6f;
        Ell(fx, fy, r, r, D2D1::ColorF(1, 1, 1, 0.18f + (k % 3) * 0.1f));
    }
    // text column
    float tw = (R - L) - 290;
    Text(kKicker[tab_], fKicker_.Get(), RectF(L + 26, y + 26, L + 26 + tw, y + 42), cGold);
    Text(kHeroTitle[tab_], fHeroTitle_.Get(), RectF(L + 25, y + 42, L + 26 + tw, y + 78), cCream);
    Text(kHeroDesc[tab_], fHeroDesc_.Get(), RectF(L + 26, y + 84, L + 26 + tw, y + 140), Fade(cCream, 0.72f));
    // illustration (260 x 168 units, origin at its top-left)
    Push(D2D1::Matrix3x2F::Translation(R - 268, y));
    D2D1_MATRIX_3X2_F saved = base_;
    base_ = D2D1::Matrix3x2F::Translation(R - 268, y) * base_;
    switch (tab_) {
    case 0: DrawCocoa(); break;
    case 1: DrawRudolph(); break;
    case 2: DrawTree(); break;
    case 3: DrawWindowArt(); break;
    default: DrawGifts(); break;
    }
    base_ = saved;
    Pop();
    rt_->PopAxisAlignedClip();
    rt_->DrawRoundedRectangle(rr, B(D2D1::ColorF(1, 1, 1, 0.09f)), 1);
}

void SettingsWindow::DrawCocoa()
{
    Ell(127, 157, 70, 7, D2D1::ColorF(0, 0, 0, 0.28f));                 // shadow
    Ell(127, 151, 64, 10, Hex(0xCDBBA6));                                // saucer
    Ell(127, 148, 64, 10, Hex(0xF1E5D5));
    Ell(127, 147, 46, 6, Hex(0xE2D3C0));
    EllS(171, 106, 17, 19, cRedLo, 9);                                   // handle
    EllS(171, 106, 17, 19, Hex(0xD13B4A), 4);
    rt_->FillRoundedRectangle(D2D1::RoundedRect(RectF(84, 70, 170, 146), 16, 16), Lin(mugLin_.Get(), 84, 0, 170, 0, cRed));
    rt_->FillRectangle(RectF(84, 114, 170, 121), B(Fade(cCream, 0.9f)));   // band
    for (int k = 0; k < 6; k++) Ell(92 + k * 14.f, 117.5f, 1.6f, 1.6f, cRed);
    DrawFlake(104, 94, 7, Fade(cCream, 0.85f), 1.3f);
    DrawFlake(134, 134, 5, Fade(cCream, 0.7f), 1.1f);
    DrawFlake(152, 92, 4, Fade(cCream, 0.6f), 1);
    Ell(97, 98, 4, 18, D2D1::ColorF(1, 1, 1, 0.12f));                    // glaze highlight
    Ell(127, 71, 43, 9, Hex(0xC2303E));                                  // rim
    Ell(127, 72, 37, 6.5f, Hex(0x5A2E1C));                               // cocoa
    Ell(119, 71, 15, 2.2f, Hex(0x7E4932));
    // candy cane: white stroke, red dashes on top
    StrokeG(caneGeo_.Get(), cSnow, 7.5f);
    StrokeG(caneGeo_.Get(), Hex(0xE23A48), 7.5f, cane_.Get());
    // marshmallows
    const float mm[3][3] = {{109, 67, -14}, {127, 63, 7}, {145, 68, 20}};
    for (const auto& m : mm) {
        Push(D2D1::Matrix3x2F::Rotation(m[2], Point2F(m[0], m[1])));
        RR(RectF(m[0] - 8, m[1] - 6, m[0] + 8, m[1] + 6), 4, Hex(0xFFF8F0));
        RR(RectF(m[0] - 8, m[1] + 2, m[0] + 8, m[1] + 6), 3, Hex(0xF3DCD2));
        Pop();
    }
    // steam
    for (int k = 0; k < 3; k++) {
        float ph = std::fmod(t_ * 0.32f + k * 0.33f, 1.f);
        float a = std::sin(kPi * ph) * 0.55f;
        Push(D2D1::Matrix3x2F::Scale(0.8f + ph * 0.3f, 0.8f + ph * 0.3f) * D2D1::Matrix3x2F::Translation(110 + k * 17.f, 54 - ph * 16));
        StrokeG(steam_.Get(), D2D1::ColorF(1, 1, 1, a), 2.6f);
        Pop();
    }
    DrawSparkle(38, 40, 5, Fade(cGold, 0.6f + 0.4f * std::sin(t_ * 2.1f)));
    DrawSparkle(222, 56, 4, Fade(cGold, 0.6f + 0.4f * std::sin(t_ * 1.7f + 1)));
}

void SettingsWindow::DrawRudolph()
{
    // little gift on the side
    Ell(50, 162, 30, 4, D2D1::ColorF(0, 0, 0, 0.25f));
    RR(RectF(30, 126, 70, 162), 4, Hex(0x2E8B57));
    RR(RectF(27, 118, 73, 129), 3.5f, Hex(0x3AA56A));
    rt_->FillRectangle(RectF(47, 118, 53, 162), B(cGold));
    Push(D2D1::Matrix3x2F::Rotation(-25, Point2F(43, 114)));
    EllS(43, 114, 7, 4.5f, cGold, 3);
    Pop();
    Push(D2D1::Matrix3x2F::Rotation(25, Point2F(57, 114)));
    EllS(57, 114, 7, 4.5f, cGold, 3);
    Pop();
    Ell(50, 117, 3.2f, 3.2f, cGold);
    // neck + chest
    FillG(neck_.Get(), Hex(0x8E5A38));
    Ell(130, 162, 24, 18, Hex(0xC79A70));
    // collar with a bell
    RR(RectF(100, 120, 160, 131), 5.5f, Hex(0x2E7D4F));
    Ell(130, 137, 7.5f, 7.5f, cGold);
    Ell(128, 134.5f, 2.2f, 2.2f, D2D1::ColorF(1, 1, 1, 0.6f));
    Ln(126, 139, 134, 139, Hex(0x9C7420), 1.4f);
    // antlers
    StrokeG(antlerL_.Get(), Hex(0x6E452D), 6.5f);
    StrokeG(antlerR_.Get(), Hex(0x6E452D), 6.5f);
    StrokeG(antlerL_.Get(), Hex(0x94643F), 2.5f);
    StrokeG(antlerR_.Get(), Hex(0x94643F), 2.5f);
    // ears
    for (int sgn = -1; sgn <= 1; sgn += 2) {
        float ex = 130 + sgn * 37.f;
        Push(D2D1::Matrix3x2F::Rotation(sgn * 28.f, Point2F(ex, 66)));
        Ell(ex, 66, 15, 7, Hex(0xA86F48));
        Ell(ex + sgn * 2.f, 66, 9, 3.8f, Hex(0xE9B894));
        Pop();
    }
    // head
    Ell(130, 82, 33, 35, Hex(0xA86F48));
    Ell(122, 62, 15, 9, D2D1::ColorF(1, 1, 1, 0.10f));
    Ell(130, 49, 9, 5, Hex(0x8E5A38));
    Ell(130, 104, 24, 17, Hex(0xE3BC92));
    // eyes (blink every few seconds)
    float blink = std::fmod(t_, 4.2f) < 0.12f ? 0.15f : 1.f;
    for (int sgn = -1; sgn <= 1; sgn += 2) {
        float ex = 130 + sgn * 13.f;
        Ell(ex, 80, 5, 6.5f * blink, Hex(0x2A1810));
        if (blink > 0.5f) Ell(ex - 1.6f, 77.6f, 1.8f, 1.8f, cWhite);
        Ell(130 + sgn * 25.f, 95, 6, 3.5f, D2D1::ColorF(0.95f, 0.55f, 0.55f, 0.5f));
    }
    StrokeG(smile_.Get(), Hex(0x5A3220), 2);
    // the famous nose: soft pulse
    float p = 0.5f + 0.5f * std::sin(t_ * 2.6f);
    Glow(glowRed_.Get(), 130, 98, 24 + 8 * p, 0.45f + 0.35f * p);
    Ell(130, 98, 11, 8.5f, Mix(Hex(0xD81E2C), Hex(0xFF4A4A), p));
    Ell(126, 95, 3.6f, 2.2f, D2D1::ColorF(1, 1, 1, 0.85f));
    DrawSparkle(212, 36, 5, Fade(cGold, 0.55f + 0.45f * std::sin(t_ * 2.3f)));
    DrawSparkle(228, 74, 3.5f, Fade(cGold, 0.55f + 0.45f * std::sin(t_ * 1.9f + 2)));
    DrawSparkle(196, 128, 3, Fade(cSnow, 0.4f + 0.4f * std::sin(t_ * 2.7f + 1)));
}

void SettingsWindow::DrawTree()
{
    Settings* s = host_.settings;
    const auto& pal = kPal[std::max(0, std::min(4, s->lightStyle))];
    float tw = s->twinkleSpeed / 100.f;
    Glow(glowGold_.Get(), 130, 96, 110, 0.16f);
    Ell(130, 163, 112, 11, D2D1::ColorF(1, 1, 1, 0.10f));
    Ell(130, 160, 82, 7, D2D1::ColorF(1, 1, 1, 0.20f));
    RR(RectF(122, 140, 138, 158), 3, Hex(0x7A4B2E));
    // presents under the tree
    RR(RectF(78, 144, 102, 162), 3, cRed);
    rt_->FillRectangle(RectF(88, 144, 92, 162), B(cGold));
    RR(RectF(156, 148, 176, 162), 3, Hex(0x2F7FD0));
    rt_->FillRectangle(RectF(164, 148, 168, 162), B(cSnow));
    for (int i = 2; i >= 0; i--) {
        float hw = i == 0 ? 34.f : (i == 1 ? 52.f : 68.f);
        FillG(tier_[i].Get(), Lin(treeLin_.Get(), 130 - hw, 0, 130 + hw, 0, Hex(0x1F7A4D)));
        StrokeG(garland_[i].Get(), Fade(cGold, 0.85f), 2);
    }
    const float bulbs[16][2] = {{88, 134}, {110, 140}, {134, 141}, {158, 137}, {180, 130}, {104, 116}, {150, 119}, {127, 104},
                                {98, 99},  {120, 92},  {148, 96},  {164, 90},  {115, 66},  {134, 70},  {147, 60}, {126, 50}};
    for (int i = 0; i < 16; i++) {
        float b = tw <= 0 ? 0.85f : 0.5f + 0.5f * std::sin(t_ * 2.2f * tw + i * 1.7f);
        DrawBulb(bulbs[i][0], bulbs[i][1], 3.4f, pal.c[i % pal.n], b);
    }
    // star
    float p = 0.5f + 0.5f * std::sin(t_ * 1.8f);
    Glow(glowGold_.Get(), 130, 22, 30 + 6 * p, 0.55f + 0.3f * p);
    Push(D2D1::Matrix3x2F::Rotation(std::sin(t_ * 0.8f) * 4, Point2F(0, 0)) * D2D1::Matrix3x2F::Translation(130, 22));
    FillG(star_.Get(), cGold);
    Pop();
    DrawSparkle(52, 44, 4.5f, Fade(cGold, 0.5f + 0.5f * std::sin(t_ * 2.4f)));
    DrawSparkle(214, 64, 4, Fade(cSnow, 0.5f + 0.4f * std::sin(t_ * 1.6f + 1)));
}

void SettingsWindow::DrawWindowArt()
{
    Settings* s = host_.settings;
    const auto& pal = kPal[std::max(0, std::min(4, s->lightStyle))];
    float tw = s->twinkleSpeed / 100.f;
    RR(RectF(46, 54, 226, 158), 10, D2D1::ColorF(0, 0, 0, 0.28f));      // shadow
    RR(RectF(40, 46, 220, 150), 10, Hex(0xE9F1EC));
    RR(RectF(40, 46, 220, 68), 10, Hex(0xCDDCD4));
    rt_->FillRectangle(RectF(40, 60, 220, 68), B(Hex(0xCDDCD4)));
    Ln(170, 58, 177, 58, Hex(0x5F7369), 1.4f);                           // min / max / close glyphs
    rt_->DrawRectangle(RectF(186, 54, 193, 61), B(Hex(0x5F7369)), 1.3f);
    Ln(202, 54, 209, 61, Hex(0x5F7369), 1.4f);
    Ln(202, 61, 209, 54, Hex(0x5F7369), 1.4f);
    Ell(52, 58, 4, 4, cRed);
    RR(RectF(54, 80, 150, 86), 3, Hex(0xC3D2CA));
    RR(RectF(54, 93, 192, 99), 3, Hex(0xD3DFD8));
    RR(RectF(54, 106, 172, 112), 3, Hex(0xD3DFD8));
    RR(RectF(54, 120, 112, 140), 5, Hex(0xD6E4DC));
    RR(RectF(120, 120, 206, 140), 5, Hex(0xF6D9DC));
    // snow cap with icicles
    FillG(cap_.Get(), Lin(capLin_.Get(), 0, 30, 0, 56, cSnow));
    FillG(icicles_.Get(), Hex(0xDDF1FF, 0.95f));
    // garland: two swags with twinkling bulbs
    D2D1_POINT_2F a = Point2F(44, 60), c1 = Point2F(87, 84), m = Point2F(130, 62), c2 = Point2F(173, 84), b = Point2F(216, 60);
    if (s->windowGarlands) {
        for (int k = 0; k < 2; k++) {
            D2D1_POINT_2F p0 = k ? m : a, pc = k ? c2 : c1, p1 = k ? b : m;
            D2D1_POINT_2F prev = p0;
            for (int i = 1; i <= 16; i++) {
                D2D1_POINT_2F q = QPoint(p0, pc, p1, i / 16.f);
                Ln(prev.x, prev.y, q.x, q.y, Hex(0x2F7D50), 4);
                prev = q;
            }
        }
    }
    int idx = 0;
    for (int k = 0; k < 2; k++) {
        D2D1_POINT_2F p0 = k ? m : a, pc = k ? c2 : c1, p1 = k ? b : m;
        D2D1_POINT_2F prev = p0;
        for (int i = 1; i <= 16; i++) {
            D2D1_POINT_2F q = QPoint(p0, pc, p1, i / 16.f);
            Ln(prev.x, prev.y, q.x, q.y, Hex(0x23352D), 1.2f);
            prev = q;
        }
        for (int i = 1; i <= 4; i++) {
            D2D1_POINT_2F q = QPoint(p0, pc, p1, i / 5.f);
            float br = tw <= 0 ? 0.85f : 0.5f + 0.5f * std::sin(t_ * 2.2f * tw + idx * 1.9f);
            DrawBulb(q.x, q.y + 4, 3.2f, pal.c[idx % pal.n], br);
            idx++;
        }
    }
    // a tiny snowman riding the window
    Ell(192, 31, 9.5f, 9.5f, cSnow);
    Ell(192, 18, 7, 7, cSnow);
    RR(RectF(186, 22, 199, 25.5f), 1.5f, cRed);
    Ell(189.5f, 17, 1, 1, Hex(0x1E2428));
    Ell(194.5f, 17, 1, 1, Hex(0x1E2428));
    Ln(192, 19, 197, 20, Hex(0xF28C28), 1.6f);
    RR(RectF(186, 6, 198, 13), 1.5f, Hex(0x262D31));
    RR(RectF(184, 12, 200, 14), 1, Hex(0x262D31));
    DrawSparkle(30, 30, 4, Fade(cGold, 0.5f + 0.5f * std::sin(t_ * 2.0f)));
    DrawSparkle(236, 108, 3.5f, Fade(cSnow, 0.5f + 0.4f * std::sin(t_ * 2.4f + 1)));
}

void SettingsWindow::DrawGifts()
{
    Ell(130, 163, 124, 12, D2D1::ColorF(1, 1, 1, 0.85f));               // snow ground
    Ell(130, 160, 110, 6, cSnow);
    // gifts
    RR(RectF(30, 112, 92, 158), 5, cRed);
    RR(RectF(26, 104, 96, 117), 4, Hex(0xF0505E));
    rt_->FillRectangle(RectF(56, 104, 66, 158), B(cGold));
    rt_->FillRectangle(RectF(30, 130, 92, 136), B(Fade(cGold, 0.9f)));
    Push(D2D1::Matrix3x2F::Rotation(-25, Point2F(53, 99)));
    EllS(53, 99, 9, 5.5f, cGold, 3.5f);
    Pop();
    Push(D2D1::Matrix3x2F::Rotation(25, Point2F(69, 99)));
    EllS(69, 99, 9, 5.5f, cGold, 3.5f);
    Pop();
    Ell(61, 103, 3.6f, 3.6f, cGold);
    RR(RectF(88, 128, 128, 158), 4, Hex(0x2E8B57));
    RR(RectF(85, 122, 131, 131), 3.5f, Hex(0x3AA56A));
    rt_->FillRectangle(RectF(104, 122, 112, 158), B(cCream));
    Ell(104, 119, 5, 3, cCream);
    Ell(112, 119, 5, 3, cCream);
    RR(RectF(214, 140, 240, 160), 3, cGold);
    rt_->FillRectangle(RectF(225, 140, 229, 160), B(cRed));
    // snowman
    auto ball = [this](float x, float y, float r) {
        if (snowBall_) {
            snowBall_->SetCenter(Point2F(x - r * 0.35f, y - r * 0.4f));
            snowBall_->SetGradientOriginOffset(Point2F(0, 0));
            snowBall_->SetRadiusX(r * 1.5f);
            snowBall_->SetRadiusY(r * 1.5f);
            rt_->FillEllipse(D2D1::Ellipse(Point2F(x, y), r, r), snowBall_.Get());
        } else {
            Ell(x, y, r, r, cSnow);
        }
    };
    D2D1_COLOR_F twig = Hex(0x6B4429), coal = Hex(0x1E2428);
    Ln(165, 88, 140, 70, twig, 2.6f);
    Ln(149, 76, 145, 66, twig, 2.2f);
    Ln(199, 88, 226, 72, twig, 2.6f);
    Ln(217, 77, 222, 66, twig, 2.2f);
    ball(182, 128, 30);
    ball(182, 88, 21);
    ball(182, 56, 15);
    RR(RectF(166, 67, 198, 75), 4, cRed);                                 // scarf
    RR(RectF(189, 71, 197, 94), 3, cRedLo);
    Ln(190, 90, 196, 90, Fade(cGold, 0.8f), 1.4f);
    Ell(182, 84, 2.3f, 2.3f, coal);
    Ell(182, 95, 2.3f, 2.3f, coal);
    Ell(182, 120, 2.6f, 2.6f, coal);
    Ell(177, 52, 2, 2.2f, coal);
    Ell(188, 52, 2, 2.2f, coal);
    FillG(carrot_.Get(), Hex(0xF28C28));
    const float mouth[4][2] = {{175, 63}, {179, 65.5f}, {184, 66}, {189, 64.5f}};
    for (const auto& q : mouth) Ell(q[0], q[1], 1.2f, 1.2f, coal);
    RR(RectF(170, 20, 194, 42), 3, Hex(0x262D31));                        // top hat
    rt_->FillRectangle(RectF(170, 34, 194, 38), B(cRed));
    RR(RectF(163, 40, 201, 45), 2.5f, Hex(0x1E2428));
    DrawSparkle(140, 30, 4.5f, Fade(cGold, 0.5f + 0.5f * std::sin(t_ * 2.2f)));
    DrawSparkle(30, 60, 3.5f, Fade(cSnow, 0.5f + 0.4f * std::sin(t_ * 1.8f + 2)));
}

void SettingsWindow::DrawCard(int ci, Card& c)
{
    float L = kSide + kPad, R = W_ - kPad;
    if (c.y - scroll_ > H_ || c.y + c.h - scroll_ < kTitle) return;
    if (!c.bare) {
        D2D1_ROUNDED_RECT rr = D2D1::RoundedRect(RectF(L, c.y, R, c.y + c.h), 16, 16);
        rt_->FillRoundedRectangle(rr, B(WithA(cCard, 0.78f)));
        rt_->FillRoundedRectangle(rr, Lin(cardLin_.Get(), 0, c.y, 0, c.y + c.h, D2D1::ColorF(1, 1, 1, 0.04f)));
        rt_->DrawRoundedRectangle(rr, B(D2D1::ColorF(1, 1, 1, 0.075f)), 1);
    }
    if (c.title) {
        Ell(L + 24, c.y + 23, 3, 3, cGold);
        Text(c.title, fCardTitle_.Get(), RectF(L + 34, c.y + 12, R - 20, c.y + 34), Fade(cMuted, 0.95f));
    }
    bool first = true;
    for (int ri = 0; ri < (int)c.rows.size(); ri++) {
        Row& r = c.rows[ri];
        if (!r.shown) continue;
        if (!first && r.kind != KNote) rt_->FillRectangle(RectF(L + 20, r.y, R - 20, r.y + 1), B(D2D1::ColorF(1, 1, 1, 0.06f)));
        first = false;
        DrawRow(ci, ri, r, L, R);
    }
}

void SettingsWindow::DrawRow(int ci, int ri, Row& r, float L, float R)
{
    Settings* s = host_.settings;
    int id = RowId(ci, ri);
    float a = 0.35f + 0.65f * Anim(id + 100000, 1);
    auto labels = [&](float right) {
        bool hasHelp = r.help && *r.help;
        float ty = r.kind == KPalette ? r.y + 12 : r.cy - (hasHelp ? 21.f : 11.f);
        Text(r.label, fLabel_.Get(), RectF(L + 20, ty, right, ty + 22), Fade(cCream, a));
        if (hasHelp) Text(r.help, fHelp_.Get(), RectF(L + 20, ty + 23, right, ty + 42), Fade(cMuted, a));
    };
    switch (r.kind) {
    case KToggle:
        labels(r.ctl.left - 16);
        DrawToggle(r.ctl, Anim(id, 0), a, hot_ == id);
        break;
    case KSlider: {
        labels(r.ctl.left - 86);
        float x0 = r.ctl.left, x1 = r.ctl.right, cy = r.cy;
        int v = r.field ? *r.field : r.lo;
        float f = (float)(v - r.lo) / std::max(1, r.hi - r.lo);
        float tx = x0 + f * (x1 - x0);
        float act = Anim(id, 0);
        wchar_t buf[32];
        if (r.zero && v == r.lo) wcscpy_s(buf, r.zero);
        else if (r.perMille) swprintf_s(buf, L"%.1f%%", v / 10.0);
        else swprintf_s(buf, L"%d%%", v);
        D2D1_RECT_F chip = RectF(x0 - 80, cy - 13, x0 - 14, cy + 13);
        RR(chip, 8, D2D1::ColorF(1, 1, 1, 0.07f * a));
        Text(buf, fValue_.Get(), chip, Fade(Mix(cCream, cGold, act), a));
        RR(RectF(x0, cy - 3, x1, cy + 3), 3, D2D1::ColorF(1, 1, 1, 0.13f * a));
        // marker at 100% (the original behaviour)
        if (!r.perMille && r.lo < 100 && r.hi > 100) {
            float mx = x0 + (100.f - r.lo) / (r.hi - r.lo) * (x1 - x0);
            Ell(mx, cy + 10, 1.6f, 1.6f, D2D1::ColorF(1, 1, 1, 0.3f * a));
        }
        if (tx > x0 + 0.5f) {
            ID2D1Brush* fill = Lin(redLin_.Get(), x0, 0, tx, 0, cRed);
            fill->SetOpacity(a);
            rt_->FillRoundedRectangle(D2D1::RoundedRect(RectF(x0, cy - 3, tx, cy + 3), 3, 3), fill);
            fill->SetOpacity(1);
        }
        float kr = 9 + 2 * act;
        if (act > 0.02f) Glow(glowRed_.Get(), tx, cy, 26, 0.3f * act * a);
        Ell(tx, cy + 1, kr, kr, D2D1::ColorF(0, 0, 0, 0.25f * a));
        Ell(tx, cy, kr, kr, Fade(cSnow, a));
        EllS(tx, cy, kr - 1, kr - 1, Fade(cRed, a), 2);
        if (act > 0.02f) {                                                   // value bubble over the thumb
            float bw = 62, by = cy - 22 - 22 * act;
            D2D1_RECT_F bb = RectF(tx - bw / 2, by - 13, tx + bw / 2, by + 13);
            RR(bb, 9, Fade(cGold, act));
            Text(buf, fBubble_.Get(), bb, Fade(Hex(0x2A1E08), act));
        }
        break;
    }
    case KSegment: {
        labels(r.ctl.left - 16);
        RR(r.ctl, 18, D2D1::ColorF(1, 1, 1, 0.06f * a));
        RRS(r.ctl, 18, D2D1::ColorF(1, 1, 1, 0.07f * a), 1);
        float pos = Anim(id, 0);
        D2D1_RECT_F pill = RectF(r.ctl.left + 3 + pos * 84, r.ctl.top + 3, r.ctl.left + 3 + pos * 84 + 84, r.ctl.bottom - 3);
        int hs = hot_ > id && hot_ <= id + 9 ? hot_ - id - 1 : -1;
        for (int k = 0; k < (int)r.opts.size(); k++) {
            D2D1_RECT_F sr = RectF(r.ctl.left + 3 + k * 84.f, r.ctl.top + 3, r.ctl.left + 3 + k * 84.f + 84, r.ctl.bottom - 3);
            if (k == hs && r.get && r.get() != k) RR(sr, 15, D2D1::ColorF(1, 1, 1, 0.06f));
        }
        Glow(glowRed_.Get(), (pill.left + pill.right) / 2, (pill.top + pill.bottom) / 2, 50, 0.12f * a);
        ID2D1Brush* fill = Lin(redLin_.Get(), 0, pill.top, 0, pill.bottom, cRed);
        fill->SetOpacity(a);
        rt_->FillRoundedRectangle(D2D1::RoundedRect(pill, 15, 15), fill);
        fill->SetOpacity(1);
        for (int k = 0; k < (int)r.opts.size(); k++) {
            D2D1_RECT_F sr = RectF(r.ctl.left + 3 + k * 84.f, r.ctl.top + 3, r.ctl.left + 3 + k * 84.f + 84, r.ctl.bottom - 3);
            float on = std::max(0.f, 1 - std::fabs(pos - k));
            Text(r.opts[k], fSeg_.Get(), sr, Fade(Mix(Mix(cMuted, cCream, k == hs ? 0.6f : 0.f), cCream, on), a));
        }
        break;
    }
    case KPalette: {
        labels(R - 20);
        float cw = (r.ctl.right - r.ctl.left - 4 * 10) / 5;
        float tw = s->twinkleSpeed / 100.f;
        for (int k = 0; k < 5; k++) {
            D2D1_RECT_F cr = RectF(r.ctl.left + k * (cw + 10), r.ctl.top, r.ctl.left + k * (cw + 10) + cw, r.ctl.bottom);
            bool sel = s->lightStyle == k, hov = hot_ == id + 1 + k;
            float& sa = Anim(id + 1 + k, sel ? 1.f : 0.f);
            sa = Ease(sa, sel ? 1.f : 0.f, 0.033f);
            if (sa > 0.02f) Glow(glowGold_.Get(), (cr.left + cr.right) / 2, (cr.top + cr.bottom) / 2, cw * 0.75f, 0.12f * sa);
            RR(cr, 12, D2D1::ColorF(1, 1, 1, 0.045f + 0.04f * sa + (hov ? 0.03f : 0.f)));
            RRS(cr, 12, sa > 0.02f ? Fade(cGold, 0.25f + 0.7f * sa) : D2D1::ColorF(1, 1, 1, hov ? 0.18f : 0.08f), sa > 0.02f ? 1.5f : 1.f);
            // a little strand of the palette's bulbs
            const auto& pal = kPal[k];
            float x0 = cr.left + 12, x1 = cr.right - 12, wy = cr.top + 16;
            D2D1_POINT_2F pa = Point2F(x0, wy), pc = Point2F((x0 + x1) / 2, wy + 18), pb = Point2F(x1, wy);
            D2D1_POINT_2F prev = pa;
            for (int i = 1; i <= 10; i++) { D2D1_POINT_2F q = QPoint(pa, pc, pb, i / 10.f); Ln(prev.x, prev.y, q.x, q.y, D2D1::ColorF(0.75f, 0.85f, 0.8f, 0.5f), 1); prev = q; }
            for (int i = 0; i < 5; i++) {
                D2D1_POINT_2F q = QPoint(pa, pc, pb, (i + 0.5f) / 5);
                float br = tw <= 0 ? 0.85f : 0.55f + 0.45f * std::sin(t_ * 2.2f * tw + i * 1.7f + k);
                DrawBulb(q.x, q.y + 4.5f, 3.6f, pal.c[i % pal.n], sel ? br : 0.6f);
            }
            Text(kPalName[k], fChip_.Get(), RectF(cr.left, cr.bottom - 26, cr.right, cr.bottom - 6), sel ? cCream : cMuted);
        }
        break;
    }
    case KButtons: {
        labels(r.ctl.left - 16);
        for (int k = 0; k < (int)r.btns.size(); k++) {
            Btn& b = r.btns[k];
            int bid = id + 1 + k;
            bool en = !b.en || b.en(), hov = hot_ == bid && en, armed = Armed(bid);
            float ba = en ? 1.f : 0.38f;
            float rad = (b.r.bottom - b.r.top) / 2;
            if (armed) {
                Glow(glowRed_.Get(), (b.r.left + b.r.right) / 2, (b.r.top + b.r.bottom) / 2, b.w * 0.6f, 0.25f);
                RR(b.r, rad, cRed);
            } else if (b.primary) {
                if (hov) Glow(glowRed_.Get(), (b.r.left + b.r.right) / 2, (b.r.top + b.r.bottom) / 2, b.w * 0.55f, 0.18f);
                ID2D1Brush* fill = Lin(redLin_.Get(), 0, b.r.top, 0, b.r.bottom, cRed);
                fill->SetOpacity(ba * (hov ? 1.f : 0.92f));
                rt_->FillRoundedRectangle(D2D1::RoundedRect(b.r, rad, rad), fill);
                fill->SetOpacity(1);
            } else {
                RR(b.r, rad, D2D1::ColorF(1, 1, 1, (hov ? 0.12f : 0.07f) * ba));
                RRS(b.r, rad, D2D1::ColorF(1, 1, 1, 0.12f * ba), 1);
            }
            if (pressed_ == bid && en) RR(b.r, rad, D2D1::ColorF(0, 0, 0, 0.15f));
            Text(armed ? b.confirm : b.text, fBtn_.Get(), b.r, Fade(cCream, ba));
        }
        break;
    }
    case KNote: {
        const wchar_t* t = r.note ? r.note() : nullptr;
        if (!t) break;
        D2D1_RECT_F nr = RectF(L + 16, r.y + 6, R - 16, r.y + r.h - 6);
        RR(nr, 10, Fade(cGold, 0.10f));
        RRS(nr, 10, Fade(cGold, 0.28f), 1);
        Ell(nr.left + 18, (nr.top + nr.bottom) / 2, 8, 8, Fade(cGold, 0.9f));
        Text(L"i", fBubble_.Get(), RectF(nr.left + 10, nr.top, nr.left + 26, nr.bottom), Hex(0x2A1E08));
        Text(t, fNote_.Get(), RectF(nr.left + 34, nr.top, nr.right - 12, nr.bottom), Fade(cCream, 0.92f));
        break;
    }
    case KKeys: {
        static const wchar_t* const keys[8][2] = {{L"Ctrl+Alt+Shift+E", L"효과 켜기/끄기"}, {L"Ctrl+Alt+Shift+S", L"눈 내리기"},
                                                  {L"Ctrl+Alt+Shift+D", L"산타"},          {L"Ctrl+Alt+Shift+P", L"제설차"},
                                                  {L"Ctrl+Alt+Shift+L", L"전구 연결하기"},  {L"Ctrl+Alt+Shift+O", L"설정 열기"},
                                                  {L"Ctrl+Alt+Shift+G", L"글리치 기록"},    {L"Ctrl+Alt+Shift+Q", L"비상 종료"}};
        float colW = (R - L - 40 - 16) / 2;
        for (int k = 0; k < 8; k++) {
            float x = L + 20 + (k % 2) * (colW + 16), y = r.y + 4 + (k / 2) * 36.f;
            D2D1_RECT_F kr = RectF(x, y + 5, x + 126, y + 31);
            RR(kr, 7, D2D1::ColorF(1, 1, 1, 0.07f));
            RRS(kr, 7, D2D1::ColorF(1, 1, 1, 0.12f), 1);
            rt_->FillRectangle(RectF(kr.left + 6, kr.bottom - 1.5f, kr.right - 6, kr.bottom), B(D2D1::ColorF(0, 0, 0, 0.25f)));
            Text(keys[k][0], fKey_.Get(), kr, cCream);
            Text(keys[k][1], fLabel_.Get(), RectF(kr.right + 12, y + 5, x + colW, y + 31), k == 7 ? Fade(cRedHi, 0.95f) : Fade(cCream, 0.85f));
        }
        break;
    }
    case KFooter:
        Text(L"WinterDesk for Windows  ·  Made with ❄ — 100% code-drawn", fFoot_.Get(), RectF(L, r.y + 8, R, r.y + 36), Fade(cMuted, 0.85f));
        break;
    }
}

// =============================================================================================
// Window procedure
// =============================================================================================

LRESULT SettingsWindow::Proc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    switch (m) {
    case WM_NCCALCSIZE:
        if (w) return 0;                        // the whole window is client area (custom title bar)
        break;
    case WM_NCACTIVATE:
        StartTimer();
        return DefWindowProcW(h, m, w, -1);     // no non-client repaint
    case WM_NCHITTEST: {
        POINT pt = {GET_X_LPARAM(l), GET_Y_LPARAM(l)};
        ScreenToClient(h, &pt);
        float x = pt.x / s_, y = pt.y / s_;
        if (x < 0 || y < 0 || x > W_ || y > H_) break;
        int id = Hit(x, y);
        if (id == HIT_NONE && (y < kTitle || (x < kSide && y < 80))) return HTCAPTION;
        return HTCLIENT;
    }
    case WM_ACTIVATE:
        StartTimer();
        break;
    case WM_ENTERSIZEMOVE: inMove_ = true; StartTimer(); return 0;
    case WM_EXITSIZEMOVE: inMove_ = false; StartTimer(); return 0;
    // the system menu (Alt+Space, taskbar right-click) runs a modal loop: keep pumping the overlay
    case WM_ENTERMENULOOP: inMenuLoop_ = true; StartTimer(); return 0;
    case WM_EXITMENULOOP: inMenuLoop_ = false; StartTimer(); return 0;
    case WM_SIZE:
        if (w == SIZE_MINIMIZED) { StartTimer(); return 0; }
        if (rt_) {
            HRESULT hr = rt_->Resize(D2D1::SizeU(LOWORD(l), HIWORD(l)));
            if (FAILED(hr)) DiscardDevice();
        }
        W_ = LOWORD(l) / s_;
        H_ = HIWORD(l) / s_;
        StartTimer();
        InvalidateRect(h, nullptr, FALSE);
        return 0;
    case WM_DPICHANGED: {
        s_ = HIWORD(w) / 96.f;
        const RECT* r = reinterpret_cast<const RECT*>(l);
        if (rt_) rt_->SetDpi(96.f * s_, 96.f * s_);
        SetWindowPos(h, nullptr, r->left, r->top, r->right - r->left, r->bottom - r->top, SWP_NOZORDER | SWP_NOACTIVATE);
        Logf(L"TEST settings window DPI -> %.2f", s_);
        return 0;
    }
    case WM_TIMER:
        if (w == TIMER_ANIM) {
            if ((inMove_ || inMenuLoop_) && host_.pump) host_.pump();
            FlushKnobs(false);
            if (armedId_ != HIT_NONE && !Armed(armedId_)) armedId_ = HIT_NONE;
            InvalidateRect(h, nullptr, FALSE);
            StartTimer();                       // stops once unfocused / cloaked / locked and settled
        }
        return 0;
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        BeginPaint(h, &ps);
        Render();
        EndPaint(h, &ps);
        return 0;
    }
    case WM_SETCURSOR:
        if (LOWORD(l) == HTCLIENT) {
            SetCursor(LoadCursorW(nullptr, hot_ != HIT_NONE && hot_ != HIT_CLOSE && hot_ != HIT_MIN ? IDC_HAND : IDC_ARROW));
            return TRUE;
        }
        break;
    case WM_MOUSEMOVE:
        if (!tracking_) {
            TRACKMOUSEEVENT tme = {sizeof(tme), TME_LEAVE, h, 0};
            tracking_ = TrackMouseEvent(&tme) != FALSE;
        }
        {
            int wasHot = hot_;
            MouseMove(GET_X_LPARAM(l) / s_, GET_Y_LPARAM(l) / s_);
            if (hot_ != wasHot || dragSlider_ != HIT_NONE) Settle();   // hover eases (unfocused: briefly)
        }
        return 0;
    case WM_MOUSELEAVE:
        tracking_ = false;
        if (dragSlider_ == HIT_NONE) { hot_ = HIT_NONE; mx_ = my_ = -1; Settle(); }
        return 0;
    case WM_LBUTTONDOWN:
    case WM_LBUTTONDBLCLK:
        MouseDown(GET_X_LPARAM(l) / s_, GET_Y_LPARAM(l) / s_);
        Settle();
        return 0;
    case WM_LBUTTONUP:
        MouseUp(GET_X_LPARAM(l) / s_, GET_Y_LPARAM(l) / s_);
        if (hwnd_) Settle();
        return 0;
    case WM_CAPTURECHANGED:
        if (dragSlider_ != HIT_NONE && reinterpret_cast<HWND>(l) != h) { dragSlider_ = HIT_NONE; FlushKnobs(true); }
        pressed_ = HIT_NONE;
        return 0;
    case WM_MOUSEWHEEL: {
        POINT pt = {GET_X_LPARAM(l), GET_Y_LPARAM(l)};
        ScreenToClient(h, &pt);
        if (pt.x / s_ >= kSide) {
            scrollTarget_ -= GET_WHEEL_DELTA_WPARAM(w) / 120.f * 72;
            scrollTarget_ = Clampf(scrollTarget_, 0, std::max(0.f, contentH_ - H_));
            InvalidateRect(h, nullptr, FALSE);
            Settle();                           // the scroll ease needs frames even when unfocused
        }
        return 0;
    }
    case WM_KEYDOWN:
        switch (w) {
        case VK_ESCAPE: Close(); return 0;
        case VK_UP: SetTab((tab_ + 4) % 5); break;
        case VK_DOWN: SetTab((tab_ + 1) % 5); break;
        case VK_PRIOR: scrollTarget_ -= 300; break;
        case VK_NEXT: scrollTarget_ += 300; break;
        case VK_HOME: scrollTarget_ = 0; break;
        case VK_END: scrollTarget_ = 1e6f; break;
        case VK_TAB: SetTab((tab_ + ((GetKeyState(VK_SHIFT) & 0x8000) ? 4 : 1)) % 5); break;
        default: break;
        }
        scrollTarget_ = Clampf(scrollTarget_, 0, std::max(0.f, contentH_ - H_));
        InvalidateRect(h, nullptr, FALSE);
        Settle();
        return 0;
    case WM_CLOSE:
        Close();
        return 0;
    case WM_DESTROY:
        KillTimer(h, TIMER_ANIM);
        timerMs_ = 0;
        DiscardDevice();
        hwnd_ = nullptr;
        cards_.clear();
        return 0;
    default:
        break;
    }
    return DefWindowProcW(h, m, w, l);
}

}  // namespace

void ShowSettingsUi(const SettingsUiHost& h, int tab)
{
    if (!g_win) g_win.reset(new SettingsWindow());
    g_win->Open(h, tab);
}

void CloseSettingsUi()
{
    if (g_win) g_win->Close();
    g_win.reset();
}

void SettingsUiRefresh() { if (g_win) g_win->Refresh(); }
HWND SettingsUiHwnd() { return g_win ? g_win->Hwnd() : nullptr; }
