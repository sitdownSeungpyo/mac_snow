// WinterDesk for Windows - shared declarations.
// Everything is in monitor-local physical pixels (y down). Sizes taken from the mac app are in
// "points" and multiplied by S (monitor DPI / 96).
#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_3.h>
#include <dcomp.h>
#include <d2d1_3.h>
#include <d2d1_3helper.h>
#include <dwrite.h>
#include <wrl/client.h>
#include <string>
#include <vector>
#include <memory>
#include <unordered_map>
#include <map>
#include <functional>
#include <cmath>
#include <cstdint>
#include <algorithm>

using Microsoft::WRL::ComPtr;

constexpr float kPi = 3.14159265f;

/// Santa's automatic gift drop chance per pass (user request: one third of the mac's 20%).
constexpr double kSantaGiftDropChance = 0.2 / 3.0;

// ---------------------------------------------------------------------------------------------
// util.cpp: log, random, settings, persistence, launch-at-login, diag CSV, glitch ring, sentinel
// ---------------------------------------------------------------------------------------------
void LogOpen();                       // %TEMP%\WinterDesk.log (truncated)
void Logf(const wchar_t* fmt, ...);   // no-op unless LogOpen() succeeded
double NowSec();
float Rand(float lo, float hi);
int RandInt(int n);                   // [0, n)
double Rand01();
/// NaN-safe clamp: a non-finite input yields `lo` (never propagates NaN into indices).
inline float Clampf(float v, float lo, float hi) { return !(v >= lo) ? lo : (v > hi ? hi : v); }
inline float Smooth(float x) { float t = Clampf(x, 0, 1); return t * t * (3 - 2 * t); }
std::string Utf8(const std::wstring& w);
std::wstring Wide(const std::string& s);

enum OverlayMode { ModeDesktop = 0, ModeOnTop = 1 };

struct Settings {
    bool effectsOn = true;
    bool snowFalling = true;
    int intensity = 1;                // 0 Light, 1 Normal, 2 Heavy
    int mode = ModeOnTop;             // Desktop (behind windows) / On Top
    bool santa = true;
    bool snowplow = false;
    bool windowSnow = true;
    bool windowLights = true;
    bool lightLinksAuto = true;       // automatic strands between nearby windows
    bool windowGarlands = true;
    int lightStyle = 0;               // 0 Multicolor, 1 Warm White
    bool dragSnowSlides = true;       // "창 끌 때 눈": slides off (true) / stays (false)
    bool liveTracking = true;         // caps / riders / lights follow a window while it is dragged
    bool manualAfterFirstLinkDone = false;
    bool safeMode = false;            // not persisted: nothing is saved this session
    std::wstring safeReason;
    /// Safe mode is a runtime mask (Desktop mode, no window snow / lights); the saved values stay the user's.
    bool WindowFeatures() const { return !safeMode && mode == ModeOnTop; }
    int EffMode() const { return safeMode ? ModeDesktop : mode; }
    void Load();
    void Save() const;
};

struct SavedGift {
    float x, y;                       // monitor-local px (bottom-up restore keeps piles)
    int variant;
    bool isDefault;
};

struct Outfit {
    int hat = 0, face = 0, body = 0, clothes = 0;
    bool operator==(const Outfit& o) const { return hat == o.hat && face == o.face && body == o.body && clothes == o.clothes; }
    std::string Key() const { char b[32]; sprintf_s(b, "%d.%d.%d.%d", hat, face, body, clothes); return b; }
};

/// A snowman / snowball resting on a window top, persisted by owner exe + rank among its windows.
struct SavedRider {
    std::wstring owner;
    int index = 0;
    float fx = 0.5f;
    std::vector<float> radiiPt;
    Outfit outfit;
};

/// A user light link, persisted the same way.
struct SavedLink {
    std::wstring aOwner, bOwner;
    int aIndex = 0, bIndex = 0, aKind = 0, bKind = 0;
    bool operator==(const SavedLink& o) const {
        return aOwner == o.aOwner && bOwner == o.bOwner && aIndex == o.aIndex && bIndex == o.bIndex && aKind == o.aKind && bKind == o.bKind;
    }
};

std::wstring AppDataDir();                          // %APPDATA%\WinterDesk (created)
bool LoadGifts(std::vector<SavedGift>& out);         // false when nothing was saved yet
void SaveGifts(const std::vector<SavedGift>& gifts);
std::vector<SavedRider> LoadRiders();
void SaveRiders(const std::vector<SavedRider>& r);
std::vector<SavedLink> LoadLinks();
void SaveLinks(const std::vector<SavedLink>& l);
bool GetLaunchAtLogin();
void SetLaunchAtLogin(bool on);
void RefreshLaunchAtLogin();                        // rewrites a stale Run value (exe moved)

/// Crash/hang sentinel: armed at launch, cleared after 10 s healthy or a clean exit. Returns true
/// (and the reason) when the previous run did not finish cleanly.
bool ArmSentinel(std::wstring& lastReason);
void ClearSentinel();
void RecordSafetyStop(const wchar_t* reason);       // watchdog / emergency path (thread-safe)

/// --diag CSV (%LOCALAPPDATA%\WinterDesk\Logs\diag-<time>.csv, flushed ~1 s) + always-on ring
/// dumped by "Report a Glitch" (Ctrl+Alt+Shift+G).
void DiagOpen();
bool DiagEnabled();
void Diag(const char* event, HWND id = nullptr, const RECT* r = nullptr, const std::wstring& note = L"");
void DiagFlush();
std::wstring DumpGlitchRing(const std::wstring& state);   // returns the file path ("" on failure)

// ---------------------------------------------------------------------------------------------
// display.cpp: internal panel detection, taskbar ground line, window helpers, desktop host
// ---------------------------------------------------------------------------------------------
struct DisplayInfo {
    std::wstring name;                // \\.\DISPLAYn
    std::wstring friendly;            // monitor friendly name (log only)
    RECT bounds{};
    RECT work{};
    HMONITOR hmon = nullptr;
    float scale = 1.f;                // DPI / 96
    int refreshHz = 60;
    bool isInternal = false;
    std::wstring how;
};

DisplayInfo FindInternalDisplay();
int GroundLine(const DisplayInfo& d, std::wstring& how);   // screen y of the taskbar top (or monitor bottom)
bool FrameBounds(HWND h, RECT* r);
bool IsCloaked(HWND h);
bool ClassIs(HWND h, const wchar_t* cls);
void ClassOf(HWND h, wchar_t* buf, int n);
std::wstring ExeNameOf(HWND h);                       // lower-case exe file name (cached by pid)
/// The top-level window that hosts the desktop icons (Progman, or the WorkerW holding
/// SHELLDLL_DefView on older layouts). `layout` describes what was found (log / evidence).
HWND DesktopIconHost(std::wstring* layout);

// ---------------------------------------------------------------------------------------------
// render.cpp: D3D11 + DXGI flip-model composition swap chain + DirectComposition + Direct2D
// ---------------------------------------------------------------------------------------------
inline D2D1_COLOR_F Rgb(float r, float g, float b, float a = 1.f) { return D2D1::ColorF(r, g, b, a); }
inline D2D1_COLOR_F WithA(D2D1_COLOR_F c, float a) { c.a = a; return c; }
D2D1_COLOR_F Shade(D2D1_COLOR_F c, float f);
ID2D1Factory1* D2DFactory();          // one factory for the overlay and the panels (same thread)
IDWriteFactory* DWFactory();

/// A standalone pre-rendered bitmap with an anchor (art origin / pivot) in pixels.
struct Sprite {
    ComPtr<ID2D1Bitmap1> bmp;
    float ox = 0, oy = 0, w = 0, h = 0;
};

/// A sprite living inside the shared atlas (drawn through ID2D1SpriteBatch).
struct AtlasSprite {
    D2D1_RECT_U src{};
    float ox = 0, oy = 0, w = 0, h = 0;
};

class Renderer;

/// Collects atlas sprites for one layer and draws them in a single sprite-batch call.
class SpriteList {
public:
    void Clear() { dst_.clear(); src_.clear(); }
    void Add(const AtlasSprite& s, float x, float y, float scale = 1.f);
    void Draw(Renderer& r);
    size_t Count() const { return dst_.size(); }
    void ReleaseDevice() { batch_.Reset(); }
private:
    std::vector<D2D1_RECT_F> dst_;
    std::vector<D2D1_RECT_U> src_;
    ComPtr<ID2D1SpriteBatch> batch_;
};

class Renderer {
public:
    ~Renderer();
    bool Init(HWND hwnd, int w, int h, float scale);
    bool BeginFrame();
    /// Ends the D2D frame and presents. Returns false when the device was lost.
    bool EndFrame(UINT syncInterval);
    void DrawSprite(const Sprite& sp, float x, float y, float opacity = 1.f);
    ID2D1SolidColorBrush* Solid(D2D1_COLOR_F c) { solid->SetColor(c); return solid.Get(); }
    ComPtr<ID2D1PathGeometry> NewPath();

    int W = 0, H = 0;
    float S = 1.f;
    bool warp = false;
    std::wstring adapter;
    HANDLE waitable = nullptr;
    double endDrawSec = 0, presentSec = 0;   // accumulated timings (stats log)

    ComPtr<ID3D11Device> d3d;
    ComPtr<IDXGISwapChain1> swap;
    ComPtr<IDCompositionDevice> dcomp;
    ComPtr<IDCompositionTarget> dtarget;
    ComPtr<IDCompositionVisual> visual;
    ComPtr<ID2D1Device> d2dDevice;
    ComPtr<ID2D1DeviceContext1> dc;
    ComPtr<ID2D1DeviceContext3> dc3;       // sprite batches (null on very old systems)
    ComPtr<ID2D1Bitmap1> target;
    ComPtr<IDWriteTextFormat> fxText, toastText, bubbleText;
    ComPtr<ID2D1SolidColorBrush> solid;
    ComPtr<ID2D1StrokeStyle> roundStroke, bevelStroke, dashStroke;
    ComPtr<ID2D1LinearGradientBrush> groundBrush, capBrush, capShadowBrush, driftBrush;
    ComPtr<ID2D1RadialGradientBrush> ballBrush;

    // art
    ComPtr<ID2D1Bitmap1> atlas;
    AtlasSprite flakes[12];                // 4 sizes x 3 alphas
    int flakeSizes[4] = {};
    AtlasSprite bulbs[6][2][3];            // colour (5 = warm white) x shape (teardrop, round) x brightness
    AtlasSprite lanterns[3];               // amber paper lantern x brightness
    AtlasSprite sparkles[2][4];            // 2 tints x 4 alphas
    AtlasSprite goldDot, goldDotBig, redDot, goldGlow;   // light-edit anchors
    AtlasSprite grain, puff;               // sand-like snow grains, poof flakes
    Sprite gifts[4], plow, plowGlow, santaBody, santaHead, santaEyes, santaArm;
    Sprite legNear, legFar, deerBody, headLead, headPlain, noseGlow, reins;

private:
    bool CreateArt();
};

// ---------------------------------------------------------------------------------------------
// outfit.cpp: snowman outfits (hats / faces / arms + held items / clothes), drawn in ball units
// (radius 50, y up) on any Direct2D render target.
// ---------------------------------------------------------------------------------------------
extern const wchar_t* const kHatTitles[8];
extern const wchar_t* const kFaceTitles[8];
extern const wchar_t* const kBodyTitles[8];
extern const wchar_t* const kClothesTitles[8];
/// Draws the decor of one ball of a stack: `behind` = parts with z < 0 (drawn before the ball).
/// `m` maps ball units to the target (scale r/50, y flipped, translated to the ball centre).
void DrawBallDecor(ID2D1RenderTarget* rt, const Outfit& o, int tiers, int tierIndex, bool behind, const D2D1_MATRIX_3X2_F& m);
/// Preview tile for the customize panel: tab 0 hat, 1 face, 2 body, 3 clothes; option index.
void DrawOutfitPreview(ID2D1RenderTarget* rt, int tab, int option, const D2D1_RECT_F& box);
/// A colour emoji / text label centred at (x, y) px, height `size` px.
void DrawLabel(ID2D1RenderTarget* rt, const wchar_t* text, float x, float y, float size, D2D1_COLOR_F color, float opacity = 1.f);

// ---------------------------------------------------------------------------------------------
// panels.cpp: small layered popups (toast, hint, coach mark, customize panel)
// ---------------------------------------------------------------------------------------------
struct PanelHost {
    RECT monitor{};                    // internal display (screen px)
    RECT work{};
    float scale = 1.f;
};
void PanelsInit(HINSTANCE inst);
void PanelsShutdown();
void ShowToast(const PanelHost& h, const std::wstring& text);          // click-through, fades after 1.2 s
void ShowHint(const PanelHost& h, const std::wstring& text);           // until HideHint
void HideHint();
void ShowCoach(const PanelHost& h, const std::function<void()>& onDismiss);
void HideCoach();
bool CoachVisible();
/// Cursor poll: the coach mark takes the mouse only over its button.
void CoachCursor(POINT screen);
struct CustomizeTarget {
    std::function<Outfit()> get;
    std::function<void(const Outfit&)> set;
    std::function<bool()> valid;       // the snowman still exists as a 2+ stack
};
void ShowCustomize(const PanelHost& h, const RECT& anchorScreen, const CustomizeTarget& target);
void HideCustomize();
bool CustomizeVisible();
void ValidateCustomize();
HWND CustomizeHwnd();
HWND ToastHwnd();

// ---------------------------------------------------------------------------------------------
// scene.cpp / lights.cpp: ground snow, window caps, grains, actors, lights, input
// ---------------------------------------------------------------------------------------------
class GroundSnow {
public:
    GroundSnow(int width, float baseY, float scale);
    void Reset();
    void Clear();
    float HeightAt(float x) const;
    float SurfaceY(float x) const { return baseY - HeightAt(x); }
    void AddFlake(float x, float amount);
    float Take(float x, float halfW, float depth);
    float Scrape(float x, float halfW, float level);
    void Deposit(float x, float area);
    void Relax();
    void Draw(Renderer& r, double now);
    void ReleaseDevice() { fill_.Reset(); rim_.Reset(); }
    bool Urgent() const { return urgent_; }
    bool RebuildDue(double now) const { return !fill_ || (urgent_ && now - lastBuild_ >= 0.066) || (dirty_ && now - lastBuild_ >= 1.0); }

    float colW;
    int n;
    float baseY;
private:
    int Col(float x) const;
    float Max(int i) const { return (maxPt + jit_[i]) * scale_; }
    std::vector<float> h_, jit_;
    float scale_;
    int width_;
    bool dirty_ = true;                // slow change (flakes landing): re-tessellate at most every 1 s
    bool urgent_ = true;               // visible change (snowball, plow, grains, reset): ~15 Hz
    double lastBuild_ = -1;
    float maxH_ = 0;
    ComPtr<ID2D1GeometryRealization> fill_, rim_;
    const float startPt = 6, maxPt = 26, pilePt = 42;
};

struct Spill { float x, area; };

/// Granular snow strip on a window's top edge, ported from the mac WindowCap: 2 pt columns
/// anchored to the window's top-left (never stretched), growth up to 5 pt (+-0.5 jitter), angle of
/// repose 1.1 pt per column, piles, pours off unsupported ends (spills -> sand grains), drag bias.
struct WinCap {
    HWND hwnd = nullptr;
    DWORD pid = 0;
    std::wstring owner;                // exe name (persistence of riders / links)
    int ownerIndex = 0;                // rank among that exe's windows
    RECT rect{};                       // local px (DWM frame bounds)
    int zAll = 0;                      // index in WindowSnow::allRects (0 = front-most)
    float S = 1, colW = 2;
    std::vector<float> h, jit;         // px
    bool unsettled = false;            // moved by a non-live move: no snow until it rests 0.4 s
    double stillFor = 0, restedFor = 0, lastLiveEvent = -10;
    bool live = false;                 // following a live drag right now
    float lateral = 0, edgeBias = 0;   // pt of repose threshold (+ = toward +x)
    bool awake = true, flowing = false;
    unsigned sweep = 0;
    float budget = 0, grown = 0;
    std::vector<float> regrowTarget;
    float regrowLeft = 0;
    std::vector<float> vis;            // visible x intervals [a0,b0,a1,b1,...]
    std::vector<Spill> spills;         // snow that left an end (scene x, area px^2)
    // render cache (cap-local geometry: origin = window top-left)
    bool dirty = true, urgent = true;
    double cooldown = 0;
    ComPtr<ID2D1GeometryRealization> fill, ridge;
    float builtAvg = 0;

    void Init(float scale, float regrowPt, float regrowDuration);
    void Resize(const RECT& newRect);
    bool VisibleAt(float x) const;
    float HeightAt(float x) const;
    float SurfaceAt(float x) const;     // NAN when outside / not visible / unsettled
    float SurfaceAtRiding(float x) const;   // ignores occlusion (an object already riding it)
    void Accumulate(float ratePt, double dt);
    void Deposit(float x, float area);
    float Take(float x, float halfW, float depth);
    std::vector<Spill> Launch(int pieces, float keepPt);
    bool Step(double dt);              // granular flow; true if anything moved
    void Regrow(double dt);
    float AverageH() const;
    bool Empty() const;
    bool RebuildDue() const { return !fill || (urgent && cooldown <= (flowing ? 1.967 : 1.9)) || (dirty && cooldown <= 0); }
};

class WindowSnow {
public:
    static const int kMaxWindows = 40;
    WinCap* Find(HWND h);
    const WinCap* Find(HWND h) const;
    bool PointOverWindow(float x, float y) const;
    bool Covered(const WinCap& c, float x, float y) const;   // a window in front of c contains (x, y)
    /// Re-reads the window list. Returns true when anything visible changed.
    bool Poll(const DisplayInfo& d, float scale, double now, bool trackCaps,
              const std::function<void(WinCap&)>& onSlide, const std::function<void(WinCap&)>& onGone,
              const std::function<void(WinCap&)>& onNew);
    void Vanish(HWND h, const std::function<void(WinCap&)>& onGone);
    void Recompute(int monWidth);       // occlusion after a live move
    bool AnyMoving() const;
    std::vector<DWORD> Pids() const;
    void ReleaseDevice();

    std::vector<WinCap*> caps;          // front-most first (decorated windows)
    std::vector<RECT> allRects;         // local px, front-most first
    std::vector<HWND> allHwnds;
    int layoutVersion = 0;
private:
    void ComputeVisibility(WinCap& c, int monWidth);
    std::unordered_map<HWND, std::unique_ptr<WinCap>> map_;
    std::unordered_map<HWND, double> stableSince_;     // decorated after 1 s at rest
    std::unordered_map<HWND, RECT> lastSeen_;
    std::unordered_map<HWND, float> remembered_;        // average height before a slide-off (px)
};

struct Ball {
    float x, y, r, vx = 0, vy = 0, spin = 0, tilt = 0, tiltVel = 0;
    Ball* below = nullptr;
    Ball* above = nullptr;
    HWND restOn = nullptr;
    bool hidden = false, held = false;
    Outfit outfit;                     // meaningful on the root ball
    float spA[10], spD[10], spR[10];
    ComPtr<ID2D1Bitmap1> cache;        // body + speckles + outfit, re-rendered only when its key changes
    std::string cacheKey;
    float cacheOx = 0, cacheOy = 0, cacheW = 0, cacheH = 0;
    Ball(float x_, float y_, float r_);
    Ball* Root() { Ball* b = this; while (b->below) b = b->below; return b; }
    Ball* Top() { Ball* b = this; while (b->above) b = b->above; return b; }
    int StackCount() { int n = 0; for (Ball* b = Root(); b; b = b->above) n++; return n; }
};

struct GiftObj {
    float x = 0, y = 0, vx = 0, vy = 0, rot = 0, angVel = 0;
    int variant = 0, stackLevel = 0;
    bool isDefault = false, held = false, hidden = false;
    HWND restOn = nullptr;
};

struct FloatText {
    std::wstring text;
    float x, y, vy, life, maxLife;
    D2D1_COLOR_F color;
    bool emoji = false;
    float size = 0, growTo = 0;
};

/// Short-lived particles: gift poofs, confetti, burst flakes (drawn as atlas sprites / rects).
struct Particle {
    float x, y, vx, vy, life, maxLife, size, rot, spin;
    D2D1_COLOR_F color;
    int kind;                          // 0 puff (flake sprite), 1 confetti rect, 2 soft clump (ball)
    float gravity;
};

/// Sand-like snow: a falling grain carrying a little snow area to the surface it lands on.
struct Grain { float x, y, vx, vy, area, age; HWND source; float size; };
/// A soft round clump shed by a shaken window (lands and becomes snow).
struct Clump { float x, y, vx, vy, r, area, age; HWND source; };

struct SantaObj {
    enum { Waiting = 0, Flying, Descending, Sliding, Ascending, Held };
    int phase = Waiting, savedPhase = Flying;
    float x = 0, y = 0, dir = 1, cruiseY = 0, velocity = 150, startX = 0, startY = 0, descendStartX = 0;
    float tilt = 0, hopY = 0, alpha = 1;
    double timer = 4, clock = 0, gallop = 0, slideTimer = 0;
    bool willLand = false, fadingOut = false;
    double hopT = -1, waveT = -1, blinkT = -1, nextBlink = 3, nextWave = 9, bubbleT = -1;
    bool dropPlanned = false;
    float dropX = 0;
    float spX[16] = {}, spY[16] = {}, spLife[16] = {};
    int spTint[16] = {};
    int spNext = 0;
    double spTimer = 0;
    bool Hit(float px, float py, float s) const;
    float VisualY(float s) const;
};

struct PlowObj {
    float x = 0, y = 0, dir = 1, vy = 0;
    bool airborne = true, beacon = true, held = false;
    float drift = 0;                    // pushed snow area (px^2)
    double honkT = -1;
    float DriftHeight(float s) const { return std::min(38 * s, std::sqrt(std::max(0.f, drift) / 0.88f)); }
    bool DriftFull(float s) const { return DriftHeight(s) >= 38 * s - 0.5f; }
    float BladeX(float s) const { return x + dir * 20 * s; }
    bool Hit(float px, float py, float s) const { return std::fabs(px - x) <= 22 * s && py >= y - 31 * s && py <= y + 2 * s; }
};

struct Flake { float x, y, vy, phase, sway; int size, sprite; };

// Light strands ------------------------------------------------------------------------------
enum AnchorKind { AnchorLeft = 0, AnchorCenter = 1, AnchorRight = 2 };
inline float AnchorFx(int k) { return k == AnchorLeft ? 0.f : (k == AnchorCenter ? 0.5f : 1.f); }
struct LightAnchor {
    HWND window;
    int kind;
    bool operator==(const LightAnchor& o) const { return window == o.window && kind == o.kind; }
    bool operator!=(const LightAnchor& o) const { return !(*this == o); }
};
struct UserLink {
    LightAnchor a, b;
    bool Same(const UserLink& o) const { return (a == o.a && b == o.b) || (a == o.b && b == o.a); }
    bool Involves(HWND w) const { return a.window == w || b.window == w; }
};
enum LinkResult { LinkNone = 0, LinkAdded, LinkSameWindow, LinkDuplicate, LinkCovered, LinkFull, LinkInvalid };
struct Strand {
    HWND wa, wb;
    float fa, fb;                       // 0..1 along each window's top edge
    float sagPt;
    int depth;                          // windows with zAll < depth (other than anchors) occlude it
    int count;                          // bulbs
    int index;                          // strand index (colour offset, round bulbs every 3rd)
    bool user;
    UserLink link{};
    float fade = 1;
    // cached geometry (screen px) for the anchor positions it was built at
    D2D1_POINT_2F p0{}, p1{};
    std::vector<D2D1_POINT_2F> bulbPts;
    std::vector<bool> bulbHidden;
    std::vector<std::pair<D2D1_POINT_2F, D2D1_POINT_2F>> wire;   // visible wire pieces
};

/// Frame-rate demand of the scene.
enum Activity { ActIdle = 0, ActLow = 1, ActNormal = 2, ActHigh = 3 };

class Scene {
public:
    static const int kMaxGifts = 30;
    static const int kMaxLinks = 20;
    Scene(const DisplayInfo& d, int groundLocalY, Settings& s, const std::vector<SavedGift>* saved, bool allowDefaultGift,
          bool wantDefaultSnowman);

    // callbacks into the app
    std::function<void(const std::wstring&)> onToast;
    std::function<void(Ball* root, RECT anchorLocal)> onOpenCustomizer;
    std::function<void()> onLinksChanged;
    std::function<void(const SavedRider&)> onRiderParked;
    std::function<void()> onDefaultGiftGone;

    // commands
    void SetGroundLine(int localY);
    void ResetSnow();
    void ClearBalls();
    void ClearSnowmenAndGifts();
    bool AddGift();
    bool CanAddGift() const { return (int)gifts_.size() < kMaxGifts; }
    void Toast(const std::wstring& text) { if (onToast) onToast(text); }
    void SettingsChanged();
    std::vector<SavedGift> SnapshotGifts() const;
    std::vector<SavedRider> SnapshotRiders() const;
    /// Places saved riders on matching windows; returns those that found no window.
    std::vector<SavedRider> RestoreRiders(const std::vector<SavedRider>& saved);
    void ForceSantaPass(int land = -1, int dir = 0, float cruiseY = 0);   // test hook: land -1 random, 0 fly over, 1 land; dir/cruiseY 0 random
    void TestSnowman(float x, int preset);   // test hook: decorated 3-tier snowman on the ground at x
    bool TestOpenCustomizer(float x);        // test hook: opens the panel for the snowman nearest x
    std::wstring StateLine() const;    // test hook: object positions for the log
    Ball* SpawnTestBall(float x, float rPt);   // test hook

    // windows
    void PollWindows(double dt);
    void OnMoveSizeStart(HWND h);
    void OnMoveSizeEnd(HWND h);
    void OnWindowLive(HWND h, const RECT& screen);   // live drag position (EVENT_OBJECT_LOCATIONCHANGE)
    void OnWindowVanished(HWND h, const wchar_t* why);
    bool WindowsBusy() const { return windows_.AnyMoving() || liveDragging_; }
    const WindowSnow& Windows() const { return windows_; }
    int TrackedWindowCount() const { return (int)windows_.caps.size(); }

    // lights / light edit
    void SetLightEdit(bool on);
    bool LightEdit() const { return lightEdit_; }
    double EditIdleSeconds() const { return time_ - lastEditTouch_; }
    int EligibleAnchorWindows() const;
    std::vector<SavedLink> SnapshotLinks() const;
    /// Restores saved links whose two windows each match exactly one window; returns the rest.
    std::vector<SavedLink> RestoreLinks(const std::vector<SavedLink>& saved);
    int UserLinkCount() const { return (int)userLinks_.size(); }

    // simulation / drawing
    void Update(double dt);
    void PrepareCaches(Renderer& r);   // outside BeginDraw: re-render changed snowball bitmaps
    void Render(Renderer& r);
    void ReleaseDevice();
    Activity GetActivity() const;
    bool RedrawDue() const;
    bool needsRedraw = true;
    int powerSaving = 0;

    // input
    bool UpdateCursor(float x, float y, bool inside, bool desktopMode);
    void MouseDown(float x, float y, bool right, int clicks);
    void MouseMove(float x, float y);
    void MouseUp(float x, float y);
    void CancelCapture();
    bool IsHolding() const { return held_.kind != 0 || linkDrag_ || pendingBall_ != nullptr; }
    bool HoveringObject() const { return hover_.kind != 0 || hoverGift_ != nullptr; }
    std::wstring MouseTargetName(float x, float y);
    std::wstring SupportInfo(float x, float y);   // test hook
    void DeleteBallFromMenu();         // right-click menu "delete"
    Ball* ContextBall() const { return contextBall_; }
    bool IsSnowmanRoot(Ball* b) const;   // b still exists as the bottom of a 2+ ball stack
    void SetOutfit(Ball* root, const Outfit& o);

    bool defaultGiftRemoved = false;
    bool giftsDirty = false;
    float S;
    int W, H;

private:
    struct Ref {
        int kind = 0;                  // 0 none, 1 ball, 2 gift, 3 santa, 4 plow
        void* p = nullptr;
        bool operator==(const Ref& o) const { return kind == o.kind && p == o.p; }
        bool operator!=(const Ref& o) const { return !(*this == o); }
    };
    enum { KNone = 0, KBall = 1, KGift = 2, KSanta = 3, KPlow = 4 };
    struct SupportHit { float y; WinCap* cap; };

    bool CapsActive() const { return settings_.WindowFeatures() && settings_.windowSnow; }
    bool LightsActive() const { return settings_.WindowFeatures() && settings_.windowLights; }
    bool TrackWindows() const { return settings_.WindowFeatures() && (settings_.windowSnow || settings_.windowLights); }
    int TargetFlakes() const;
    Flake NewFlake(float y);
    SupportHit Support(float x, float belowY, HWND riding = nullptr);
    void SlideOff(WinCap& c);
    void WindowGone(WinCap& c);
    void WindowNew(WinCap& c);
    void ParkRiders(WinCap& c);
    void UpdateFlakes(float dt);
    void SpawnGrains(float area, float x, float y, float spreadX, float vx, float vy, float jx, float jy, HWND source);
    void UpdateGrains(float dt);
    void UpdateClumps(float dt);
    void UpdateParticles(float dt);
    void UpdateBalls(float dt);
    void LandOnStacks(Ball* b);
    void DragBall(Ball* b, float tx, float ty);
    GiftObj* SpawnGift(float x, float y, int variant, bool isDefault, float vx, float vy, bool spin);
    void StepGifts(float dt);
    void UpdateSanta(double dt);
    void StartSantaPass();
    void Celebrate();
    void EnsurePlow(bool on);
    void UpdatePlow(float dt);
    void AddText(const std::wstring& t, float x, float y, D2D1_COLOR_F c);
    void Poof(float x, float y, int n);
    void Confetti(float x, float y);
    std::vector<Ball*> PlaceSnowman(float x, const std::vector<float>& radiiPt, const Outfit& o, WinCap* on, float fx);
    void PlaceDefaultSnowman();
    void ShedClumps(WinCap& c, float ax, float ay);

    void DrawCaps(Renderer& r);
    void DrawGrains(Renderer& r);
    void DrawBall(Renderer& r, Ball& b, int tiers, int tierIndex);
    void DrawGift(Renderer& r, const GiftObj& g);
    void DrawSanta(Renderer& r);
    void DrawPlow(Renderer& r);
    void DrawOutlinedText(Renderer& r, const FloatText& t);
    void DrawDeleteButtons(Renderer& r);
    void DrawParticles(Renderer& r);

    // lights.cpp
    void SyncStrands();
    void BuildStrandGeometry(Strand& s);
    void DrawLights(Renderer& r);
    void DrawLightEdit(Renderer& r);
    D2D1_POINT_2F AnchorPoint(const WinCap& c, float fx) const;
    bool AnchorVisible(const LightAnchor& a) const;
    std::vector<std::pair<LightAnchor, D2D1_POINT_2F>> VisibleAnchors() const;
    bool AnchorHit(float x, float y, LightAnchor* out, D2D1_POINT_2F* pt) const;
    const Strand* UserStrandNear(float x, float y, float tol) const;
    LinkResult ValidateLink(const UserLink& l, bool requireVisible) const;
    LinkResult AddUserLink(const UserLink& l, bool requireVisible);
    void RemoveUserLink(const UserLink& l);
    bool EditMouseDown(float x, float y);
    void EditMouseMove(float x, float y);
    void EditMouseUp(float x, float y);

    bool BallDeleteVisible() const;
    D2D1_POINT_2F BallDeletePos() const;
    bool BallDeleteHit(float x, float y) const;
    bool GiftDeleteHit(float x, float y) const;
    D2D1_POINT_2F GiftDeletePos(const GiftObj& g) const;
    Ball* BallAt(float x, float y);
    GiftObj* GiftAt(float x, float y, bool includeDelete);
    bool RiderCovered(float x, float y, HWND on) const;
    bool InGroundZone(float x, float y) const;
    D2D1_POINT_2F ThrowVelocity() const;
    void DeleteBalls(Ball* b);
    void RemoveBallPtr(Ball* b);
    void DeleteGift(GiftObj* g);
    void OpenGift(GiftObj* g);
    void RemoveGiftPtr(GiftObj* g);
    void OpenCustomizer(Ball* root);

    DisplayInfo disp_;
    Settings& settings_;
    std::unique_ptr<GroundSnow> ground_;
    WindowSnow windows_;
    std::vector<Flake> flakes_;
    std::vector<Grain> grains_;
    std::vector<Clump> clumps_;
    std::vector<Particle> particles_;
    std::vector<std::unique_ptr<Ball>> balls_;
    std::vector<std::unique_ptr<GiftObj>> gifts_;
    GiftObj* defaultGift_ = nullptr;
    SantaObj santa_;
    std::unique_ptr<PlowObj> plow_;
    std::vector<FloatText> texts_;
    double time_ = 0, relaxTimer_ = 0;
    float wind_ = 0;
    bool anyMoving_ = false;
    bool capsChanged_ = false;
    bool wantDefaultSnowman_ = false;
    int forceSantaLand_ = -1, forceSantaDir_ = 0;   // test hook
    float forceSantaY_ = 0;                         // test hook
    bool liveDragging_ = false;
    int flakeSizePx_[4] = {2, 3, 4, 6};

    // live drag tracking (one window at a time: the one being moved)
    HWND liveHwnd_ = nullptr;
    double liveT_ = 0;
    float liveVx_ = 0, liveVy_ = 0, livePrevVx_ = 0, livePrevVy_ = 0;
    double lastShed_ = -10, lastReversal_ = -10;

    Ref hover_, held_;
    double hoverSince_ = 0;
    GiftObj* hoverGift_ = nullptr;
    Ball* pendingBall_ = nullptr;
    Ball* contextBall_ = nullptr;
    float heldDx_ = 0, heldDy_ = 0, lastMx_ = 0, lastMy_ = 0, dragDistance_ = 0;
    struct Sample { double t; float x, y; };
    std::vector<Sample> history_;

    // lights
    std::vector<Strand> strands_;
    std::string strandSig_;
    std::vector<UserLink> userLinks_;
    bool lightEdit_ = false;
    double lastEditTouch_ = 0;
    bool linkDrag_ = false;
    LightAnchor linkSrc_{};
    D2D1_POINT_2F previewEnd_{};
    bool snapValid_ = false, snapping_ = false;
    D2D1_POINT_2F snapPt_{};
    ComPtr<ID2D1GeometryRealization> wires_;
    int wiresVersion_ = -1;
    std::string wiresKey_;

    SpriteList bulbList_, sparkleList_, flakeList_, grainList_, dotList_, particleList_;
};
