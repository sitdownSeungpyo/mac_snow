// GPU renderer: D3D11 device -> DXGI flip-model swap chain for composition -> DirectComposition
// visual on the overlay HWND -> Direct2D device context drawing into the back buffer.
// All art (ported from the mac app's Core Graphics drawing) is rendered once into bitmaps here.
#include "winterdesk.h"

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "dcomp.lib")
#pragma comment(lib, "d2d1.lib")
#pragma comment(lib, "dwrite.lib")

using D2D1::Matrix3x2F;
using D2D1::Point2F;

D2D1_COLOR_F Shade(D2D1_COLOR_F c, float f)
{
    return Rgb(std::max(0.f, c.r * (1 - f)), std::max(0.f, c.g * (1 - f * 1.15f)), std::max(0.f, c.b * (1 - f * 0.75f)), c.a);
}

ID2D1Factory1* D2DFactory()
{
    static ComPtr<ID2D1Factory1> f = [] {
        ComPtr<ID2D1Factory1> x;
        D2D1_FACTORY_OPTIONS fo{};
        D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1), &fo, reinterpret_cast<void**>(x.GetAddressOf()));
        return x;
    }();
    return f.Get();
}

IDWriteFactory* DWFactory()
{
    static ComPtr<IDWriteFactory> f = [] {
        ComPtr<IDWriteFactory> x;
        DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown**>(x.GetAddressOf()));
        return x;
    }();
    return f.Get();
}

namespace {

typedef ComPtr<ID2D1Geometry> Geo;

const D2D1_COLOR_F kRed = Rgb(0.92f, 0.2f, 0.25f);
const D2D1_COLOR_F kFur = Rgb(1, 0.98f, 0.96f);
const D2D1_COLOR_F kSkin = Rgb(1, 0.86f, 0.76f);
const D2D1_COLOR_F kBlush = Rgb(1, 0.45f, 0.5f, 0.55f);
const D2D1_COLOR_F kGold = Rgb(1, 0.8f, 0.3f);
const D2D1_COLOR_F kMitten = Rgb(0.25f, 0.68f, 0.45f);
const D2D1_COLOR_F kEyeInk = Rgb(0.22f, 0.12f, 0.14f);
const D2D1_COLOR_F kCoat = Rgb(0.76f, 0.52f, 0.33f);
const D2D1_COLOR_F kCream = Rgb(1, 0.92f, 0.78f);
const D2D1_COLOR_F kHoof = Rgb(0.42f, 0.26f, 0.2f);

const D2D1_POINT_2F kArmPivot = {-6, 31};
const D2D1_POINT_2F kHeadPivot = {-15, 34};
const D2D1_POINT_2F kNeck = {9, 23};
const D2D1_POINT_2F kNose = {27.5f, 29.5f};
const float kDeerX[3] = {72, 124, 176};

/// Path builder (quadratic and cubic curves, winding fill).
class PB {
public:
    explicit PB(ID2D1Factory1* f)
    {
        f->CreatePathGeometry(&geo_);
        geo_->Open(&sink_);
        sink_->SetFillMode(D2D1_FILL_MODE_WINDING);
    }
    PB& M(float x, float y)
    {
        if (open_) sink_->EndFigure(D2D1_FIGURE_END_OPEN);
        sink_->BeginFigure(Point2F(x, y), D2D1_FIGURE_BEGIN_FILLED);
        open_ = true;
        return *this;
    }
    PB& L(float x, float y) { sink_->AddLine(Point2F(x, y)); return *this; }
    PB& Q(float cx, float cy, float x, float y)
    {
        sink_->AddQuadraticBezier(D2D1::QuadraticBezierSegment(Point2F(cx, cy), Point2F(x, y)));
        return *this;
    }
    PB& C(float ax, float ay, float bx, float by, float x, float y)
    {
        sink_->AddBezier(D2D1::BezierSegment(Point2F(ax, ay), Point2F(bx, by), Point2F(x, y)));
        return *this;
    }
    PB& Z()
    {
        if (open_) sink_->EndFigure(D2D1_FIGURE_END_CLOSED);
        open_ = false;
        return *this;
    }
    Geo Done()
    {
        if (open_) sink_->EndFigure(D2D1_FIGURE_END_OPEN);
        open_ = false;
        sink_->Close();
        Geo g;
        geo_.As(&g);
        return g;
    }
private:
    ComPtr<ID2D1PathGeometry> geo_;
    ComPtr<ID2D1GeometrySink> sink_;
    bool open_ = false;
};

/// Drawing helpers in the current transform's coordinates (mac-style y-up "points" for most art).
struct Painter {
    Renderer& r;
    ID2D1Factory1* f;
    ID2D1DeviceContext1* dc;
    std::vector<D2D1_MATRIX_3X2_F> stack;
    ComPtr<ID2D1StrokeStyle> dash;

    explicit Painter(Renderer& rr) : r(rr), f(D2DFactory()), dc(rr.dc.Get())
    {
        float dashes[] = {0.65f, 0.65f};
        D2D1_STROKE_STYLE_PROPERTIES p = D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT,
                                                                     D2D1_LINE_JOIN_MITER, 10.f, D2D1_DASH_STYLE_CUSTOM, 0.f);
        f->CreateStrokeStyle(p, dashes, 2, &dash);
    }
    void Push(const Matrix3x2F& local)
    {
        D2D1_MATRIX_3X2_F cur;
        dc->GetTransform(&cur);
        stack.push_back(cur);
        dc->SetTransform(local * *Matrix3x2F::ReinterpretBaseType(&cur));
    }
    void Pop()
    {
        dc->SetTransform(stack.back());
        stack.pop_back();
    }
    PB Path() { return PB(f); }
    Geo Circle(float x, float y, float rr)
    {
        ComPtr<ID2D1EllipseGeometry> e;
        f->CreateEllipseGeometry(D2D1::Ellipse(Point2F(x, y), rr, rr), &e);
        Geo g; e.As(&g); return g;
    }
    Geo Ellipse(float cx, float cy, float w, float h)
    {
        ComPtr<ID2D1EllipseGeometry> e;
        f->CreateEllipseGeometry(D2D1::Ellipse(Point2F(cx, cy), w / 2, h / 2), &e);
        Geo g; e.As(&g); return g;
    }
    Geo RRect(float x, float y, float w, float h, float rad)
    {
        float rr = std::min(rad, std::min(w / 2 - 0.01f, h / 2 - 0.01f));
        ComPtr<ID2D1RoundedRectangleGeometry> e;
        f->CreateRoundedRectangleGeometry(D2D1::RoundedRect(D2D1::RectF(x, y, x + w, y + h), std::max(0.f, rr), std::max(0.f, rr)), &e);
        Geo g; e.As(&g); return g;
    }
    Geo Poly(bool closed, std::initializer_list<float> xy)
    {
        PB p(f);
        const float* v = xy.begin();
        size_t n = xy.size() / 2;
        p.M(v[0], v[1]);
        for (size_t i = 1; i < n; i++) p.L(v[2 * i], v[2 * i + 1]);
        if (closed) p.Z();
        return p.Done();
    }
    Geo Group(std::vector<Geo>& parts)
    {
        std::vector<ID2D1Geometry*> raw;
        for (Geo& g : parts) raw.push_back(g.Get());
        ComPtr<ID2D1GeometryGroup> grp;
        f->CreateGeometryGroup(D2D1_FILL_MODE_WINDING, raw.data(), (UINT32)raw.size(), &grp);
        Geo g; grp.As(&g); return g;
    }
    /// Union of circles given as (x, y, r) triples, offset by (dx, dy).
    Geo Union(float dx, float dy, std::initializer_list<float> xyr, std::vector<Geo> extra = {})
    {
        std::vector<Geo> parts;
        const float* v = xyr.begin();
        for (size_t i = 0; i + 2 < xyr.size(); i += 3) parts.push_back(Circle(v[i] + dx, v[i + 1] + dy, v[i + 2]));
        for (Geo& e : extra) parts.push_back(e);
        return Group(parts);
    }
    void Fill(ID2D1Geometry* g, D2D1_COLOR_F c) { dc->FillGeometry(g, r.Solid(c)); }
    void Stroke(ID2D1Geometry* g, D2D1_COLOR_F c, float w) { dc->DrawGeometry(g, r.Solid(c), w, r.roundStroke.Get()); }
    void Dot(float x, float y, float rr, D2D1_COLOR_F c) { dc->FillEllipse(D2D1::Ellipse(Point2F(x, y), rr, rr), r.Solid(c)); }
    void FillRect(float x, float y, float w, float h, D2D1_COLOR_F c) { dc->FillRectangle(D2D1::RectF(x, y, x + w, y + h), r.Solid(c)); }

    ComPtr<ID2D1GradientStopCollection> Stops(std::initializer_list<D2D1_COLOR_F> cols, std::initializer_list<float> pos)
    {
        std::vector<D2D1_GRADIENT_STOP> st;
        auto c = cols.begin();
        for (float p : pos) st.push_back({p, *c++});
        ComPtr<ID2D1GradientStopCollection> coll;
        dc->CreateGradientStopCollection(st.data(), (UINT32)st.size(), &coll);
        return coll;
    }
    /// Vertical linear gradient over geometry g; stop 0 at y0, stop 1 at y1, clamped beyond.
    void VGrad(ID2D1Geometry* g, float y0, float y1, std::initializer_list<D2D1_COLOR_F> cols, std::initializer_list<float> pos)
    {
        ComPtr<ID2D1LinearGradientBrush> b;
        dc->CreateLinearGradientBrush(D2D1::LinearGradientBrushProperties(Point2F(0, y0), Point2F(0, y1)), Stops(cols, pos).Get(), &b);
        dc->FillGeometry(g, b.Get());
    }
    /// Radial gradient filling the circle (cx, cy, rr); stops run from the focus (0) to the edge (1).
    void Radial(float cx, float cy, float rr, float fx, float fy, std::initializer_list<D2D1_COLOR_F> cols, std::initializer_list<float> pos)
    {
        if (rr <= 0) return;
        ComPtr<ID2D1RadialGradientBrush> b;
        dc->CreateRadialGradientBrush(D2D1::RadialGradientBrushProperties(Point2F(cx, cy), Point2F(fx - cx, fy - cy), rr, rr),
                                      Stops(cols, pos).Get(), &b);
        dc->FillEllipse(D2D1::Ellipse(Point2F(cx, cy), rr, rr), b.Get());
    }
    /// Sticker blob: darker outline, flat fill, soft bottom shading, optional gloss.
    void Blob(ID2D1Geometry* g, D2D1_COLOR_F fill, float line = 1.1f, float shading = 0.16f, float gloss = 0)
    {
        if (line > 0) Stroke(g, Shade(fill, 0.42f), line * 2);
        Fill(g, fill);
        if (shading <= 0 && gloss <= 0) return;
        D2D1_RECT_F bb;
        g->GetBounds(nullptr, &bb);
        float bw = bb.right - bb.left, bh = bb.bottom - bb.top;
        if (shading > 0) {
            D2D1_COLOR_F s = Shade(fill, shading);
            VGrad(g, bb.top + bh * 0.55f, bb.top + bh * 0.05f, {WithA(s, 0), s}, {0, 1});
        }
        if (gloss > 0) {
            dc->PushLayer(D2D1::LayerParameters1(D2D1::InfiniteRect(), g), nullptr);
            dc->FillEllipse(D2D1::Ellipse(Point2F(bb.left + bw * 0.35f, bb.top + bh * 0.7f), bw * 0.15f, bh * 0.1f), r.Solid(Rgb(1, 1, 1, gloss)));
            dc->PopLayer();
        }
    }
    void ShinyEye(float x, float y, float w, float h)
    {
        Fill(Ellipse(x, y, w, h).Get(), kEyeInk);
        Dot(x - w * 0.17f, y + h * 0.2f, w * 0.27f, Rgb(1, 1, 1));
        Dot(x + w * 0.2f, y - h * 0.22f, w * 0.12f, Rgb(1, 1, 1, 0.9f));
    }
    void GiftBox(float x, float y, float w, float h, float angle, D2D1_COLOR_F color)
    {
        Push(Matrix3x2F::Rotation(angle * 180.f / kPi) * Matrix3x2F::Translation(x, y));
        Blob(RRect(-w / 2, -h / 2, w, h, 1.5f).Get(), color, 0.9f, 0.16f, 0);
        FillRect(-1, -h / 2, 2, h, kGold);
        FillRect(-w / 2, -1, w, 2, kGold);
        Blob(Union(0, 0, {-2, h / 2 + 1.3f, 1.8f, 2, h / 2 + 1.3f, 1.8f}).Get(), kGold, 0.6f, 0, 0);
        Pop();
    }
};

/// One sprite to render: size in px, anchor, art-space -> bitmap transform, and the drawing.
struct Def {
    int w = 1, h = 1;
    float ox = 0, oy = 0;
    Matrix3x2F local = Matrix3x2F::Identity();
    std::function<void(Painter&)> draw;
};

/// Art drawn in y-up point coordinates inside (rx, ry, rw, rh) at `s` px/pt, anchored at (px, py).
Def ArtDef(float rx, float ry, float rw, float rh, float px, float py, float s, std::function<void(Painter&)> draw)
{
    Def d;
    d.w = (int)std::ceil(rw * s) + 2;
    d.h = (int)std::ceil(rh * s) + 2;
    d.local = Matrix3x2F::Translation(-rx, -ry) * Matrix3x2F::Scale(s, -s) * Matrix3x2F::Translation(1.f, (float)(d.h - 1));
    d.ox = 1 + (px - rx) * s;
    d.oy = (d.h - 1) - (py - ry) * s;
    d.draw = std::move(draw);
    return d;
}

/// Art drawn directly in y-down pixels with the anchor at (ox, oy).
Def PxDef(int w, int h, float ox, float oy, std::function<void(Painter&)> draw)
{
    Def d;
    d.w = std::max(1, w);
    d.h = std::max(1, h);
    d.ox = ox;
    d.oy = oy;
    d.local = Matrix3x2F::Translation(ox, oy);
    d.draw = std::move(draw);
    return d;
}

Def FlakeDef(int d, float a)
{
    float c = (d + 2) / 2.f;
    return PxDef(d + 2, d + 2, c, c, [d, a](Painter& p) {
        p.Radial(0, 0, d / 2.f, 0, 0, {Rgb(1, 1, 1, a), Rgb(1, 1, 1, 0.55f * a), Rgb(1, 1, 1, 0)}, {0, 0.45f, 1});
    });
}

Def GlowDef(D2D1_COLOR_F c, int d, float strength)
{
    float r = d / 2.f;
    return PxDef(d, d, r, r, [c, r, strength](Painter& p) {
        p.Radial(0, 0, r - 0.5f, 0, 0, {WithA(c, 0.9f * strength), WithA(c, 0.28f * strength), WithA(c, 0)}, {0, 0.4f, 1});
    });
}

/// Hanging bulb like the mac (teardrop or round glass, dark socket, soft glow); anchor = top of
/// the socket. `level` 0..2 = twinkle brightness.
Def BulbDef(D2D1_COLOR_F c, bool round, int level, float s)
{
    int half = (int)std::ceil(12 * s) + 1;
    int top = (int)std::ceil(5 * s) + 1;
    int h = top + (int)std::ceil(19 * s) + 1;
    return PxDef(half * 2, h, (float)half, (float)top, [c, round, level, s](Painter& p) {
        float strength = 0.3f + 0.3f * level;
        p.Radial(0, 7.5f * s, 12 * s, 0, 7.5f * s, {WithA(c, 0.85f * strength), WithA(c, 0.25f * strength), WithA(c, 0)}, {0, 0.3f, 1});
        D2D1_COLOR_F bc = level == 0 ? Shade(c, 0.3f) : (level == 1 ? Shade(c, 0.1f) : c);
        Geo glass;
        if (round) {
            glass = p.Ellipse(0, 7.6f * s, 6.4f * s, 7.6f * s);
        } else {
            glass = p.Path().M(0, 12.6f * s).C(4.4f * s, 9.2f * s, 3.6f * s, 3 * s, 0, 3 * s)
                        .C(-3.6f * s, 3 * s, -4.4f * s, 9.2f * s, 0, 12.6f * s).Z().Done();
        }
        p.Fill(glass.Get(), bc);
        p.dc->FillEllipse(D2D1::Ellipse(Point2F(-1.1f * s, 6.4f * s), 0.9f * s, 1.6f * s), p.r.Solid(Rgb(1, 1, 1, 0.6f)));
        p.FillRect(-1.75f * s, -0.4f * s, 3.5f * s, 3.8f * s, Rgb(0.15f, 0.15f, 0.15f));
    });
}

/// Small amber paper lantern (every 7th bulb of long strands); anchor = top of its cap.
Def LanternDef(int level, float s)
{
    int half = (int)std::ceil(16 * s) + 1;
    int top = (int)std::ceil(5 * s) + 1;
    int h = top + (int)std::ceil(26 * s) + 1;
    return PxDef(half * 2, h, (float)half, (float)top, [level, s](Painter& p) {
        D2D1_COLOR_F glow = Rgb(1, 0.62f, 0.22f);
        float strength = 0.35f + 0.25f * level;
        p.Radial(0, 9 * s, 16 * s, 0, 9 * s, {WithA(glow, 0.8f * strength), WithA(glow, 0.22f * strength), WithA(glow, 0)}, {0, 0.3f, 1});
        D2D1_COLOR_F dark = Rgb(0.25f, 0.12f, 0.06f);
        p.FillRect(-2.5f * s, 0, 5 * s, 2 * s, dark);
        Geo body = p.RRect(-4.5f * s, 2 * s, 9 * s, 12 * s, 4 * s);
        ComPtr<ID2D1RadialGradientBrush> b;
        D2D1_GRADIENT_STOP st[] = {{0, Rgb(1, 0.93f, 0.6f)}, {0.55f, Rgb(1, 0.6f, 0.18f)}, {1, Rgb(0.8f, 0.3f, 0.08f)}};
        ComPtr<ID2D1GradientStopCollection> coll;
        p.dc->CreateGradientStopCollection(st, 3, &coll);
        float k = 0.75f + 0.125f * level;
        p.dc->CreateRadialGradientBrush(D2D1::RadialGradientBrushProperties(Point2F(0, 8 * s), Point2F(0, 0), 7 * s * k + 2 * s, 7 * s * k + 2 * s),
                                        coll.Get(), &b);
        p.dc->FillGeometry(body.Get(), b.Get());
        for (float x : {-2.f, 0.f, 2.f}) p.dc->DrawLine(Point2F(x * s, 2.5f * s), Point2F(x * s, 13.5f * s), p.r.Solid(Rgb(0.75f, 0.32f, 0.08f, 0.6f)), 0.5f * s);
        p.FillRect(-2.f * s, 14 * s, 4 * s, 2 * s, dark);
        p.dc->DrawEllipse(D2D1::Ellipse(Point2F(0, 17.2f * s), 1.5f * s, 1.25f * s), p.r.Solid(dark), 0.75f * s);
    });
}

/// Light-edit anchor dot (gold, white ring) of radius `rPt`; `red` = invalid target.
Def DotDef(float rPt, bool red, float s)
{
    float r = rPt * s;
    int d = (int)std::ceil(2 * r) + 4;
    return PxDef(d, d, d / 2.f, d / 2.f, [r, red](Painter& p) {
        if (red) p.Radial(0, 0, r, -r * 0.2f, -r * 0.2f, {Rgb(1, 0.75f, 0.75f), Rgb(1, 0.25f, 0.25f), Rgb(0.8f, 0.1f, 0.1f)}, {0, 0.55f, 1});
        else p.Radial(0, 0, r, -r * 0.2f, -r * 0.2f, {Rgb(1, 0.97f, 0.8f), Rgb(1, 0.82f, 0.3f), Rgb(0.95f, 0.62f, 0.1f)}, {0, 0.55f, 1});
        p.dc->DrawEllipse(D2D1::Ellipse(Point2F(0, 0), r * 0.92f, r * 0.92f), p.r.Solid(Rgb(1, 1, 1, 0.9f)), std::max(1.f, r * 0.14f));
    });
}

Def SparkleDef(D2D1_COLOR_F tint, float s)
{
    return ArtDef(-7, -7, 14, 14, 0, 0, s, [tint](Painter& p) {
        float k = 14.f / 32.f;
        p.Radial(0, 0, 9 * k, 0, 0, {WithA(tint, 0.55f), WithA(tint, 0)}, {0, 1});
        Geo star = p.Path().M(0, 15 * k).Q(1.5f * k, 1.5f * k, 15 * k, 0).Q(1.5f * k, -1.5f * k, 0, -15 * k)
                       .Q(-1.5f * k, -1.5f * k, -15 * k, 0).Q(-1.5f * k, 1.5f * k, 0, 15 * k).Z().Done();
        p.Fill(star.Get(), tint);
    });
}

const D2D1_COLOR_F kGiftBodies[4][3] = {
    {{0.86f, 0.12f, 0.15f, 1}, {0.93f, 0.18f, 0.2f, 1}, {0.6f, 0.05f, 0.08f, 1}},
    {{0.13f, 0.6f, 0.3f, 1}, {0.18f, 0.68f, 0.35f, 1}, {0.06f, 0.38f, 0.17f, 1}},
    {{0.18f, 0.4f, 0.85f, 1}, {0.24f, 0.47f, 0.92f, 1}, {0.08f, 0.22f, 0.55f, 1}},
    {{0.55f, 0.22f, 0.75f, 1}, {0.62f, 0.28f, 0.82f, 1}, {0.34f, 0.1f, 0.5f, 1}},
};

/// Gift box; origin at the box centre (half size 15 x 12 pt).
Def GiftDef(int v, float s)
{
    return ArtDef(-19, -14, 38, 37, 0, 0, s, [v](Painter& p) {
        D2D1_COLOR_F body = kGiftBodies[v][0], lid = kGiftBodies[v][1], edge = kGiftBodies[v][2];
        D2D1_COLOR_F gold = Rgb(1, 0.8f, 0.22f), darkGold = Rgb(0.78f, 0.55f, 0.08f);
        Geo g = p.RRect(-15, -12, 30, 20, 2); p.Fill(g.Get(), body); p.Stroke(g.Get(), edge, 1.2f);
        g = p.RRect(-17, 5, 34, 8, 2); p.Fill(g.Get(), lid); p.Stroke(g.Get(), edge, 1.2f);
        p.FillRect(-2.5f, -12, 5, 25, gold);
        p.FillRect(-15, -3, 30, 4, gold);
        g = p.Ellipse(-7, 17, 13, 9); p.Fill(g.Get(), gold); p.Stroke(g.Get(), darkGold, 1);
        g = p.Ellipse(7, 17, 13, 9); p.Fill(g.Get(), gold); p.Stroke(g.Get(), darkGold, 1);
        p.Fill(p.Circle(0, 15, 3.2f).Get(), darkGold);
    });
}

/// Toy snowplow facing +x; origin at the bottom centre of the tracks.
Def PlowDef(float s)
{
    return ArtDef(-17, -1, 38, 28, 0, 0, s, [](Painter& p) {
        D2D1_COLOR_F yellow = Rgb(1, 0.8f, 0.14f), edge = Rgb(0.78f, 0.56f, 0.05f), dark = Rgb(0.2f, 0.2f, 0.22f), steel = Rgb(0.62f, 0.66f, 0.72f);
        p.FillRect(9, 7, 6, 2.5f, dark);
        Geo g = p.RRect(-14, 8, 24, 8, 2.5f); p.Fill(g.Get(), yellow); p.Stroke(g.Get(), edge, 1);
        g = p.RRect(-10, 15, 14, 11, 2.5f); p.Fill(g.Get(), yellow); p.Stroke(g.Get(), edge, 1);
        p.Fill(p.RRect(-7.5f, 17.5f, 9, 6, 1.5f).Get(), Rgb(0.62f, 0.84f, 0.96f));
        g = p.Poly(true, {13, 0, 18, 0, 19.5f, 15, 14.5f, 13}); p.Fill(g.Get(), Rgb(0.97f, 0.98f, 1)); p.Stroke(g.Get(), Rgb(0.7f, 0.75f, 0.82f), 1);
        p.FillRect(-14, 11, 3.5f, 2, Rgb(0.95f, 0.3f, 0.2f));
        p.Fill(p.RRect(-16, 0, 27, 8.5f, 4.2f).Get(), dark);
        for (float x : {-11.5f, -5.5f, 0.5f, 6.5f}) p.Fill(p.Circle(x, 4.2f, 2.2f).Get(), steel);
    });
}

/// Sack + torso + sleigh (origin = sleigh origin).
Def SantaBodyDef(float s)
{
    return ArtDef(-64, -6, 108, 74, 0, 0, s, [](Painter& p) {
        D2D1_COLOR_F sackC = Rgb(0.84f, 0.66f, 0.46f);
        p.Blob(p.Ellipse(-44, 47, 21, 6).Get(), Shade(sackC, 0.3f), 0.8f, 0, 0);
        p.GiftBox(-49, 51, 10, 9, 0.25f, Rgb(0.3f, 0.6f, 0.95f));
        p.GiftBox(-40, 52, 9, 10, -0.18f, Rgb(0.62f, 0.36f, 0.86f));
        Geo bag = p.Path().M(-55, 47).C(-60, 36, -55, 25, -44, 25).C(-33, 25, -28, 36, -33, 47).Q(-44, 43, -55, 47).Z().Done();
        p.Blob(bag.Get(), sackC);
        p.Stroke(p.Poly(false, {-50, 41, -47, 39.5f}).Get(), Shade(sackC, 0.3f), 1);
        p.Blob(p.Ellipse(-16, 27, 27, 27).Get(), kRed);
        Geo runner = p.Path().M(-57, 6).Q(-57, 2, -51, 2).L(18, 2).Q(32, 2, 33, 10).Q(35, 15.5f, 28, 14.5f).Done();
        for (float x : {-38.f, 4.f}) {
            Geo strut = p.Poly(false, {x, 2, x, 11});
            p.Stroke(strut.Get(), Shade(kGold, 0.45f), 5);
            p.Stroke(strut.Get(), kGold, 3);
        }
        p.Stroke(runner.Get(), Rgb(0.6f, 0.12f, 0.2f), 6);
        p.Stroke(runner.Get(), Rgb(1, 0.97f, 0.95f), 4);
        p.dc->DrawGeometry(runner.Get(), p.r.Solid(Rgb(0.93f, 0.18f, 0.25f)), 4, p.r.dashStroke.Get());
        Geo tub = p.Path().M(-52, 16).Q(-52, 8, -44, 8).L(14, 8).Q(29, 8, 29, 22).Q(0, 15, -27, 22).Q(-29, 41, -42, 42).Q(-53, 43, -53, 36).Z().Done();
        p.Blob(tub.Get(), kRed, 1.2f, 0.2f, 0);
        Geo rim = p.Path().M(28, 22).Q(0, 15, -27, 22).Q(-29, 41, -42, 42).Done();
        p.Stroke(rim.Get(), Shade(kGold, 0.4f), 3.6f);
        p.Stroke(rim.Get(), kGold, 2.2f);
        p.Blob(p.Circle(28, 23, 4.2f).Get(), kGold, 0.9f, 0.1f, 0);
        p.Dot(28.6f, 23.4f, 1.6f, Shade(kGold, 0.25f));
        p.Stroke(p.Poly(false, {-48, 18, -46.5f, 33}).Get(), Rgb(1, 1, 1, 0.4f), 2.4f);
        p.Stroke(p.Poly(false, {-30, 12.5f, 4, 12.5f}).Get(), Rgb(1, 1, 1, 0.22f), 2);
        PB star = p.Path();
        for (int k = 0; k < 10; k++) {
            float a = k * kPi / 5 + kPi / 2;
            float rr = k % 2 == 0 ? 5.f : 2.3f;
            float x = -12 + std::cos(a) * rr, y = 15 + std::sin(a) * rr;
            if (k == 0) star.M(x, y); else star.L(x, y);
        }
        p.Blob(star.Z().Done().Get(), kGold, 0.7f, 0, 0);
    });
}

Def SantaArmDef(float s)
{
    return ArtDef(-10, 24, 24, 14, kArmPivot.x, kArmPivot.y, s, [](Painter& p) {
        p.Blob(p.RRect(-9, 27, 13, 8, 4).Get(), kRed, 1, 0.1f, 0);
        p.Blob(p.RRect(2, 26.5f, 4, 9, 2).Get(), kFur, 0.8f, 0, 0);
        p.Blob(p.Union(0, 0, {8.5f, 31, 4.1f, 6.8f, 34.4f, 1.9f}).Get(), kMitten, 1, 0.12f, 0);
    });
}

/// Head with hat, open eyes and pompom.
Def SantaHeadDef(float s)
{
    return ArtDef(-42, 24, 54, 50, kHeadPivot.x, kHeadPivot.y, s, [](Painter& p) {
        float cx = -15, cy = 45;
        p.Blob(p.Union(cx, cy, {-12.5f, 4.5f, 4, -13, -0.5f, 4, 12.5f, 4, 3.4f}).Get(), kFur, 1, 0.08f, 0);
        p.Blob(p.Circle(cx, cy, 12.5f).Get(), kSkin, 1, 0.08f, 0);
        p.dc->FillEllipse(D2D1::Ellipse(Point2F(cx - 7.5f, cy - 2), 2.75f, 1.8f), p.r.Solid(kBlush));
        p.dc->FillEllipse(D2D1::Ellipse(Point2F(cx + 9.5f, cy - 2), 2.5f, 1.8f), p.r.Solid(kBlush));
        Geo beard = p.Union(cx, cy, {-10, -5, 5, -6, -10, 5.5f, 0, -12.5f, 6, 6, -11, 5.5f, 10.5f, -6, 5, 12, -1.5f, 3.4f, -12, -0.5f, 3.6f},
                            {p.Ellipse(cx + 0.5f, cy - 8.5f, 20, 9)});
        p.Blob(beard.Get(), kFur, 1, 0.1f, 0);
        Geo mouth = p.Path().M(cx - 1.4f, cy - 7).Q(cx + 1.1f, cy - 11.5f, cx + 3.6f, cy - 7).Z().Done();
        p.Fill(mouth.Get(), Rgb(0.75f, 0.25f, 0.3f));
        p.Blob(p.Union(cx, cy, {-2.4f, -5, 3.3f, 4.4f, -5, 3.3f}).Get(), kFur, 0.9f, 0.1f, 0);
        p.Blob(p.Circle(cx + 1, cy - 1.8f, 2.5f).Get(), Rgb(1, 0.58f, 0.55f), 0.8f, 0, 0);
        p.Dot(cx + 0.3f, cy - 1.1f, 0.8f, Rgb(1, 1, 1, 0.8f));
        Geo hat = p.Path().M(cx + 13, cy + 8).C(cx + 13, cy + 26, cx - 5, cy + 34, cx - 18, cy + 21)
                      .Q(cx - 11, cy + 23, cx - 6, cy + 16).Q(cx - 9, cy + 12, cx - 12, cy + 8).Z().Done();
        p.Blob(hat.Get(), kRed, 1.1f, 0.12f, 0.3f);
        p.Blob(p.Union(cx, cy, {-11, 8.5f, 3.8f, -5.5f, 9, 4, 0.5f, 9.2f, 4, 6.5f, 9, 4, 11.5f, 8.5f, 3.7f}).Get(), kFur, 1, 0.12f, 0);
        p.ShinyEye(-18.4f, 47, 3.9f, 5);
        p.ShinyEye(-9.6f, 47, 3.9f, 5);
        p.Blob(p.Union(-33, 66, {0, 0, 4.4f, -2, 1.5f, 2.6f, 2, 1.8f, 2.4f}).Get(), kFur, 1, 0.15f, 0);
    });
}

/// Closed happy eyes (blink), positioned like the head sprite.
Def SantaEyesDef(float s)
{
    return ArtDef(-22, 43, 16, 8, kHeadPivot.x, kHeadPivot.y, s, [](Painter& p) {
        p.Dot(-18.4f, 47, 2.9f, kSkin);
        p.Dot(-9.6f, 47, 2.9f, kSkin);
        for (float x : {-18.4f, -9.6f}) {
            Geo arc = p.Path().M(x - 2.1f, 46.2f).Q(x, 49.4f, x + 2.1f, 46.2f).Done();
            p.Stroke(arc.Get(), kEyeInk, 1.2f);
        }
    });
}

Def DeerLegDef(bool isFar, float s)
{
    return ArtDef(-4, -13, 8, 15, 0, 0, s, [isFar](Painter& p) {
        D2D1_COLOR_F c = isFar ? Shade(kCoat, 0.18f) : kCoat;
        p.Blob(p.RRect(-2.6f, -10.5f, 5.2f, 12, 2.6f).Get(), c, 0.9f, 0.1f, 0);
        p.Blob(p.RRect(-2.8f, -11.5f, 5.6f, 3.6f, 1.8f).Get(), isFar ? Shade(kHoof, 0.15f) : kHoof, 0.7f, 0, 0);
    });
}

Def DeerBodyDef(float s)
{
    return ArtDef(-20, 4, 36, 26, 0, 0, s, [](Painter& p) {
        p.Blob(p.Union(0, 0, {-14.5f, 21, 3.3f, -16.5f, 22.5f, 2}).Get(), kCream, 0.9f, 0.1f, 0);
        Geo body = p.Ellipse(0, 17, 28, 17);
        p.Blob(body.Get(), kCoat, 1.1f, 0.18f, 0);
        p.dc->PushLayer(D2D1::LayerParameters1(D2D1::InfiniteRect(), body.Get()), nullptr);
        p.Fill(p.Ellipse(2, 11.5f, 18, 8).Get(), kCream);
        p.dc->PopLayer();
        Geo strap = p.Poly(false, {8, 25, 11.5f, 14});
        p.Stroke(strap.Get(), Rgb(0.6f, 0.1f, 0.18f), 4.2f);
        p.Stroke(strap.Get(), kRed, 2.8f);
        p.Blob(p.Circle(11.5f, 13.5f, 2.4f).Get(), kGold, 0.7f, 0.15f, 0);
    });
}

Def DeerHeadDef(bool lead, float s)
{
    return ArtDef(-3, 15, 38, 42, kNeck.x, kNeck.y, s, [lead](Painter& p) {
        D2D1_COLOR_F antler = Rgb(0.98f, 0.86f, 0.62f);
        for (int k = 0; k < 2; k++) {
            bool isFar = k == 0;
            float dx = isFar ? -4.5f : 0;
            Geo a = p.Path().M(15.5f + dx, 39).Q(17 + dx, 47, 12 + dx, 53.5f)
                        .M(15.8f + dx, 45.5f).Q(19.5f + dx, 46, 20.5f + dx, 50.5f)
                        .M(14.6f + dx, 50).L(10.5f + dx, 51.5f).Done();
            p.Stroke(a.Get(), Shade(antler, 0.5f), 4.6f);
            p.Stroke(a.Get(), isFar ? Shade(antler, 0.15f) : antler, 2.8f);
        }
        p.Blob(p.Path().M(8, 35).Q(1, 35, 0, 42).Q(7, 43, 10, 39).Z().Done().Get(), kCoat, 1, 0.1f, 0);
        p.Fill(p.Ellipse(5, 39.5f, 4.5f, 2).Get(), Rgb(1, 0.7f, 0.7f));
        p.Blob(p.Circle(15, 32, 10.5f).Get(), kCoat, 1.1f, 0.15f, 0);
        p.Blob(p.Ellipse(22.5f, 28.2f, 12.5f, 9.5f).Get(), kCream, 0.9f, 0.1f, 0);
        p.Fill(p.Ellipse(16.5f, 27.6f, 5, 3.2f).Get(), kBlush);
        p.ShinyEye(18, 33.8f, 4.6f, 5.8f);
        p.Stroke(p.Path().M(22.2f, 25.6f).Q(24.2f, 23.6f, 26, 25.8f).Done().Get(), Shade(kCoat, 0.45f), 0.9f);
        if (lead) p.Blob(p.Circle(kNose.x, kNose.y, 3.4f).Get(), Rgb(1, 0.18f, 0.22f), 0.9f, 0.1f, 0);
        else p.Blob(p.Ellipse(kNose.x, kNose.y, 5.4f, 4.4f).Get(), Rgb(0.42f, 0.24f, 0.2f), 0.8f, 0, 0);
        p.Dot(kNose.x - 0.9f, kNose.y + 1, 1, Rgb(1, 1, 1, 0.85f));
    });
}

Def NoseGlowDef(float s)
{
    return ArtDef(kNose.x - 13, kNose.y - 13, 26, 26, kNose.x, kNose.y, s, [](Painter& p) {
        p.Radial(kNose.x, kNose.y, 13, kNose.x, kNose.y, {Rgb(1, 0.3f, 0.3f, 0.75f), Rgb(1, 0.2f, 0.25f, 0.25f), Rgb(1, 0.2f, 0.25f, 0)}, {0, 0.4f, 1});
    });
}

Def ReinsDef(float s)
{
    return ArtDef(20, 6, 180, 24, 0, 0, s, [](Painter& p) {
        PB path = p.Path();
        float px = 30, py = 21;
        path.M(px, py);
        for (float x : kDeerX) {
            float cx = x + 9, cy = 19;
            path.Q((px + cx) / 2, std::min(py, cy) - 4, cx, cy);
            px = cx;
            py = cy;
        }
        Geo g = path.Done();
        p.Stroke(g.Get(), Rgb(0.45f, 0.12f, 0.16f), 2.4f);
        p.Stroke(g.Get(), Rgb(0.86f, 0.26f, 0.3f), 1.2f);
    });
}

// red, green, blue, gold, warm, warm (Warm White), white, cyan, pink
const D2D1_COLOR_F kBulbColors[kBulbColorCount] = {{1, 0.22f, 0.22f, 1}, {0.25f, 0.95f, 0.4f, 1}, {0.3f, 0.55f, 1, 1}, {1, 0.76f, 0.2f, 1},
                                                   {1, 0.86f, 0.6f, 1}, {1, 0.86f, 0.6f, 1}, {0.94f, 0.97f, 1, 1}, {0.35f, 0.9f, 1, 1},
                                                   {1, 0.45f, 0.75f, 1}};

}  // namespace

// =============================================================================================
// Renderer
// =============================================================================================

Renderer::~Renderer()
{
    if (dc) dc->SetTarget(nullptr);
    // the waitable object is owned by the swap chain; closing our handle is required
    if (waitable) CloseHandle(waitable);
}

bool Renderer::Init(HWND hwnd, int w, int h, float scale)
{
    W = w;
    H = h;
    S = scale;
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
                                        D3D_FEATURE_LEVEL_10_0, D3D_FEATURE_LEVEL_9_3};
    // single-threaded use, and no driver worker threads: our command streams are tiny
    const UINT devFlags = D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_SINGLETHREADED |
                          D3D11_CREATE_DEVICE_PREVENT_INTERNAL_THREADING_OPTIMIZATIONS;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, devFlags, levels,
                                   _countof(levels), D3D11_SDK_VERSION, &d3d, nullptr, nullptr);
    if (FAILED(hr)) {
        Logf(L"hardware D3D11 device failed (0x%08X); falling back to WARP", (unsigned)hr);
        warp = true;
        hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, devFlags, levels,
                               _countof(levels), D3D11_SDK_VERSION, &d3d, nullptr, nullptr);
        if (FAILED(hr)) { Logf(L"WARP device failed (0x%08X)", (unsigned)hr); return false; }
    }
    ComPtr<IDXGIDevice> dxgiDev;
    d3d.As(&dxgiDev);
    ComPtr<IDXGIAdapter> adapterObj;
    dxgiDev->GetAdapter(&adapterObj);
    DXGI_ADAPTER_DESC ad{};
    adapterObj->GetDesc(&ad);
    adapter = ad.Description;
    ComPtr<IDXGIFactory2> fac;
    hr = adapterObj->GetParent(IID_PPV_ARGS(&fac));
    if (FAILED(hr)) { Logf(L"IDXGIFactory2 unavailable (0x%08X)", (unsigned)hr); return false; }

    DXGI_SWAP_CHAIN_DESC1 sd{};
    sd.Width = (UINT)w;
    sd.Height = (UINT)h;
    sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = 2;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    sd.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
    sd.Scaling = DXGI_SCALING_STRETCH;
    sd.Flags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
    hr = fac->CreateSwapChainForComposition(d3d.Get(), &sd, nullptr, &swap);
    if (FAILED(hr)) { Logf(L"CreateSwapChainForComposition failed (0x%08X)", (unsigned)hr); return false; }
    ComPtr<IDXGISwapChain2> swap2;
    if (SUCCEEDED(swap.As(&swap2))) {
        swap2->SetMaximumFrameLatency(1);
        waitable = swap2->GetFrameLatencyWaitableObject();
    }

    hr = DCompositionCreateDevice(dxgiDev.Get(), IID_PPV_ARGS(&dcomp));
    if (SUCCEEDED(hr)) hr = dcomp->CreateTargetForHwnd(hwnd, TRUE, &dtarget);
    if (SUCCEEDED(hr)) hr = dcomp->CreateVisual(&visual);
    if (SUCCEEDED(hr)) hr = visual->SetContent(swap.Get());
    if (SUCCEEDED(hr)) hr = dtarget->SetRoot(visual.Get());
    if (SUCCEEDED(hr)) hr = dcomp->Commit();
    if (FAILED(hr)) { Logf(L"DirectComposition setup failed (0x%08X)", (unsigned)hr); return false; }

    D2D1_FACTORY_OPTIONS fo{};
    (void)fo;
    hr = D2DFactory() ? D2DFactory()->CreateDevice(dxgiDev.Get(), &d2dDevice) : E_FAIL;
    ComPtr<ID2D1DeviceContext> dc0;
    if (SUCCEEDED(hr)) hr = d2dDevice->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &dc0);
    if (SUCCEEDED(hr)) hr = dc0.As(&dc);
    if (FAILED(hr)) { Logf(L"Direct2D setup failed (0x%08X)", (unsigned)hr); return false; }
    dc0.As(&dc3);   // optional (Windows 10 1607+)
    dc->SetDpi(96, 96);

    ComPtr<IDXGISurface> surf;
    hr = swap->GetBuffer(0, IID_PPV_ARGS(&surf));
    D2D1_BITMAP_PROPERTIES1 bp = D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
                                                         D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
    if (SUCCEEDED(hr)) hr = dc->CreateBitmapFromDxgiSurface(surf.Get(), &bp, &target);
    if (FAILED(hr)) { Logf(L"swap chain target bitmap failed (0x%08X)", (unsigned)hr); return false; }

    IDWriteFactory* dw = DWFactory();
    hr = dw ? S_OK : E_FAIL;
    if (SUCCEEDED(hr)) hr = dw->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_STYLE_NORMAL,
                                                 DWRITE_FONT_STRETCH_NORMAL, 15 * S, L"", &fxText);
    if (SUCCEEDED(hr)) hr = dw->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_FONT_STYLE_NORMAL,
                                                 DWRITE_FONT_STRETCH_NORMAL, 13 * S, L"", &toastText);
    if (SUCCEEDED(hr)) hr = dw->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_STYLE_NORMAL,
                                                 DWRITE_FONT_STRETCH_NORMAL, 14 * S, L"", &bubbleText);
    if (FAILED(hr)) { Logf(L"DirectWrite setup failed (0x%08X)", (unsigned)hr); return false; }
    for (IDWriteTextFormat* tf : {fxText.Get(), toastText.Get(), bubbleText.Get()}) {
        tf->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
        tf->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        tf->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    }

    dc->CreateSolidColorBrush(Rgb(1, 1, 1), &solid);
    D2D1_STROKE_STYLE_PROPERTIES rp = D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND,
                                                                  D2D1_LINE_JOIN_ROUND);
    D2DFactory()->CreateStrokeStyle(rp, nullptr, 0, &roundStroke);
    D2D1_STROKE_STYLE_PROPERTIES bpp = D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT,
                                                                   D2D1_LINE_JOIN_BEVEL);
    D2DFactory()->CreateStrokeStyle(bpp, nullptr, 0, &bevelStroke);
    float dashes[] = {0.65f, 0.65f};
    D2D1_STROKE_STYLE_PROPERTIES dp = D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT,
                                                                  D2D1_LINE_JOIN_MITER, 10.f, D2D1_DASH_STYLE_CUSTOM, 0.f);
    D2DFactory()->CreateStrokeStyle(dp, dashes, 2, &dashStroke);

    auto linear = [&](std::initializer_list<D2D1_GRADIENT_STOP> st, ComPtr<ID2D1LinearGradientBrush>& out) {
        ComPtr<ID2D1GradientStopCollection> coll;
        dc->CreateGradientStopCollection(st.begin(), (UINT32)st.size(), &coll);
        dc->CreateLinearGradientBrush(D2D1::LinearGradientBrushProperties(Point2F(0, 0), Point2F(0, 1)), coll.Get(), &out);
    };
    linear({{0, Rgb(0.80f, 0.87f, 0.97f)}, {0.55f, Rgb(0.94f, 0.96f, 1)}, {1, Rgb(1, 1, 1)}}, groundBrush);
    linear({{0, Rgb(0.84f, 0.89f, 0.98f)}, {0.35f, Rgb(0.97f, 0.98f, 1)}, {1, Rgb(1, 1, 1)}}, capBrush);
    linear({{0, Rgb(0.1f, 0.15f, 0.3f, 0.22f)}, {1, Rgb(0.1f, 0.15f, 0.3f, 0)}}, capShadowBrush);
    linear({{0, Rgb(0.74f, 0.82f, 0.96f)}, {0.45f, Rgb(0.93f, 0.96f, 1)}, {1, Rgb(1, 1, 1)}}, driftBrush);
    {
        D2D1_GRADIENT_STOP st[] = {{0, Rgb(1, 1, 1)}, {0.55f, Rgb(0.95f, 0.97f, 1)}, {1, Rgb(0.82f, 0.87f, 0.96f)}};
        ComPtr<ID2D1GradientStopCollection> coll;
        dc->CreateGradientStopCollection(st, 3, &coll);
        dc->CreateRadialGradientBrush(D2D1::RadialGradientBrushProperties(Point2F(0, 0), Point2F(0, 0), 1, 1), coll.Get(), &ballBrush);
    }
    if (!solid || !roundStroke || !bevelStroke || !dashStroke || !groundBrush || !capBrush || !capShadowBrush || !driftBrush || !ballBrush) {
        Logf(L"brush creation failed");
        return false;
    }

    double t0 = NowSec();
    if (!CreateArt()) { Logf(L"art creation failed"); return false; }
    dc->SetTarget(target.Get());
    Logf(L"art rendered in %.1f ms (sprite batch %s)", (NowSec() - t0) * 1000, dc3 ? L"yes" : L"no (DrawBitmap fallback)");
    return true;
}

bool Renderer::CreateArt()
{
    Painter p(*this);
    D2D1_BITMAP_PROPERTIES1 bp = D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET,
                                                         D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
    auto render = [&](const Def& d, Sprite& out) -> bool {
        if (FAILED(dc->CreateBitmap(D2D1::SizeU((UINT32)d.w, (UINT32)d.h), nullptr, 0, &bp, &out.bmp))) return false;
        dc->SetTarget(out.bmp.Get());
        dc->BeginDraw();
        dc->Clear(Rgb(0, 0, 0, 0));
        dc->SetTransform(d.local);
        d.draw(p);
        dc->SetTransform(Matrix3x2F::Identity());
        out.ox = d.ox;
        out.oy = d.oy;
        out.w = (float)d.w;
        out.h = (float)d.h;
        return SUCCEEDED(dc->EndDraw());
    };

    bool ok = true;
    for (int v = 0; v < 4; v++) ok &= render(GiftDef(v, S), gifts[v]);
    ok &= render(PlowDef(S), plow);
    ok &= render(GlowDef(Rgb(1, 0.55f, 0.1f), std::max(8, (int)(16 * S)), 1), plowGlow);
    ok &= render(SantaBodyDef(S), santaBody);
    ok &= render(SantaHeadDef(S), santaHead);
    ok &= render(SantaEyesDef(S), santaEyes);
    ok &= render(SantaArmDef(S), santaArm);
    ok &= render(DeerLegDef(false, S), legNear);
    ok &= render(DeerLegDef(true, S), legFar);
    ok &= render(DeerBodyDef(S), deerBody);
    ok &= render(DeerHeadDef(true, S), headLead);
    ok &= render(DeerHeadDef(false, S), headPlain);
    ok &= render(NoseGlowDef(S), noseGlow);
    ok &= render(ReinsDef(S), reins);
    if (!ok) return false;
    return CreateAtlas(flakePct);
}

bool Renderer::CreateAtlas(int pct)
{
    Painter p(*this);
    D2D1_BITMAP_PROPERTIES1 bp = D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET,
                                                         D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
    // ---- atlas: flakes, bulbs, sparkles (drawn with sprite batches) ----
    std::vector<Def> defs;
    std::vector<AtlasSprite*> slots;
    const float al[3] = {0.5f, 0.75f, 1.f};
    int sizes[4];
    for (int i = 0; i < 4; i++) {
        sizes[i] = FlakePx(i, pct, S);
        for (int j = 0; j < 3; j++) { defs.push_back(FlakeDef(sizes[i], al[j])); slots.push_back(&flakes[i * 3 + j]); }
    }
    for (int c = 0; c < kBulbColorCount; c++)
        for (int sh = 0; sh < 2; sh++)
            for (int l = 0; l < 3; l++) { defs.push_back(BulbDef(kBulbColors[c], sh == 1, l, S)); slots.push_back(&bulbs[c][sh][l]); }
    for (int l = 0; l < 3; l++) { defs.push_back(LanternDef(l, S)); slots.push_back(&lanterns[l]); }
    defs.push_back(DotDef(9, false, S)); slots.push_back(&goldDot);
    defs.push_back(DotDef(15, false, S)); slots.push_back(&goldDotBig);
    defs.push_back(DotDef(10, true, S)); slots.push_back(&redDot);
    defs.push_back(GlowDef(Rgb(1, 0.8f, 0.25f), std::max(8, (int)(46 * S)), 0.9f)); slots.push_back(&goldGlow);
    defs.push_back(FlakeDef(std::max(2, (int)std::lround(2.4f * S)), 1.f)); slots.push_back(&grain);
    defs.push_back(FlakeDef(std::max(4, (int)std::lround(10 * S)), 1.f)); slots.push_back(&puff);
    const D2D1_COLOR_F tints[2] = {Rgb(0.85f, 0.95f, 1), Rgb(1, 0.88f, 0.5f)};
    for (int t = 0; t < 2; t++)
        for (int a = 0; a < 4; a++) { defs.push_back(SparkleDef(WithA(tints[t], (a + 1) / 4.f), S)); slots.push_back(&sparkles[t][a]); }

    const int gutter = 2, maxW = 1024;
    int x = gutter, y = gutter, rowH = 0, atlasW = 0;
    std::vector<POINT> pos(defs.size());
    for (size_t i = 0; i < defs.size(); i++) {
        if (x + defs[i].w + gutter > maxW) { x = gutter; y += rowH + gutter; rowH = 0; }
        pos[i] = {x, y};
        x += defs[i].w + gutter;
        rowH = std::max(rowH, defs[i].h);
        atlasW = std::max(atlasW, x);
    }
    int atlasH = y + rowH + gutter;
    ComPtr<ID2D1Bitmap1> fresh;            // the old atlas stays in use until the new one is complete
    if (FAILED(dc->CreateBitmap(D2D1::SizeU((UINT32)atlasW, (UINT32)atlasH), nullptr, 0, &bp, &fresh))) return false;
    dc->SetTarget(fresh.Get());
    dc->BeginDraw();
    dc->Clear(Rgb(0, 0, 0, 0));
    for (size_t i = 0; i < defs.size(); i++) {
        const Def& d = defs[i];
        float sx = (float)pos[i].x, sy = (float)pos[i].y;
        dc->SetTransform(Matrix3x2F::Identity());
        dc->PushAxisAlignedClip(D2D1::RectF(sx, sy, sx + d.w, sy + d.h), D2D1_ANTIALIAS_MODE_ALIASED);
        dc->SetTransform(d.local * Matrix3x2F::Translation(sx, sy));
        d.draw(p);
        dc->SetTransform(Matrix3x2F::Identity());
        dc->PopAxisAlignedClip();
    }
    if (FAILED(dc->EndDraw())) return false;
    atlas = fresh;                         // commit only on success (sprites, sizes, pct together)
    flakePct = pct;
    std::copy(sizes, sizes + 4, flakeSizes);
    for (size_t i = 0; i < defs.size(); i++) {
        const Def& d = defs[i];
        AtlasSprite& a = *slots[i];
        a.src = D2D1::RectU((UINT32)pos[i].x, (UINT32)pos[i].y, (UINT32)(pos[i].x + d.w), (UINT32)(pos[i].y + d.h));
        a.ox = d.ox;
        a.oy = d.oy;
        a.w = (float)d.w;
        a.h = (float)d.h;
    }
    return true;
}

bool Renderer::BeginFrame()
{
    dc->SetTarget(target.Get());
    dc->BeginDraw();
    dc->SetTransform(Matrix3x2F::Identity());
    dc->Clear(Rgb(0, 0, 0, 0));
    return true;
}

bool Renderer::EndFrame(UINT syncInterval)
{
    double t0 = NowSec();
    HRESULT hr = dc->EndDraw();
    double t1 = NowSec();
    endDrawSec += t1 - t0;
    if (FAILED(hr)) { Logf(L"EndDraw failed (0x%08X): treating as device loss", (unsigned)hr); return false; }
    hr = swap->Present(syncInterval, 0);
    presentSec += NowSec() - t1;
    HRESULT removed = d3d->GetDeviceRemovedReason();
    if ((FAILED(hr) && hr != DXGI_ERROR_WAS_STILL_DRAWING) || FAILED(removed)) {
        Logf(L"Present failed (0x%08X, removed reason 0x%08X): treating as device loss", (unsigned)hr, (unsigned)removed);
        return false;
    }
    return true;
}

void Renderer::DrawSprite(const Sprite& sp, float x, float y, float opacity)
{
    if (!sp.bmp) return;
    float l = x - sp.ox, t = y - sp.oy;
    dc->DrawBitmap(sp.bmp.Get(), D2D1::RectF(l, t, l + sp.w, t + sp.h), opacity, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
}

ComPtr<ID2D1PathGeometry> Renderer::NewPath()
{
    ComPtr<ID2D1PathGeometry> g;
    D2DFactory()->CreatePathGeometry(&g);
    return g;
}

// =============================================================================================
// SpriteList
// =============================================================================================

void SpriteList::Add(const AtlasSprite& s, float x, float y, float scale)
{
    float l = x - s.ox * scale, t = y - s.oy * scale;
    dst_.push_back(D2D1::RectF(l, t, l + s.w * scale, t + s.h * scale));
    src_.push_back(s.src);
}

void SpriteList::Draw(Renderer& r)
{
    if (dst_.empty()) return;
    if (r.dc3) {
        if (!batch_) r.dc3->CreateSpriteBatch(&batch_);
        if (batch_) {
            batch_->Clear();
            batch_->AddSprites((UINT32)dst_.size(), dst_.data(), src_.data());
            r.dc->SetTransform(D2D1::Matrix3x2F::Identity());
            r.dc->SetAntialiasMode(D2D1_ANTIALIAS_MODE_ALIASED);   // required by DrawSpriteBatch
            r.dc3->DrawSpriteBatch(batch_.Get(), r.atlas.Get(), D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
            r.dc->SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
            return;
        }
    }
    for (size_t i = 0; i < dst_.size(); i++) {
        D2D1_RECT_F s = D2D1::RectF((float)src_[i].left, (float)src_[i].top, (float)src_[i].right, (float)src_[i].bottom);
        r.dc->DrawBitmap(r.atlas.Get(), dst_[i], 1.f, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, &s);
    }
}
