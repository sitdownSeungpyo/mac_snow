// Snowman outfits ported from the mac app's Outfit.swift (OutfitArt). Art is authored in "ball units"
// (radius 50, origin at the ball centre, y up). Geometry is built once per outfit/tier and cached.
#include "winterdesk.h"

using D2D1::Matrix3x2F;
using D2D1::Point2F;

const wchar_t* const kHatTitles[8] = {L"None", L"Santa hat", L"Top hat", L"Beanie", L"Earmuffs", L"Crown", L"Flower pot", L"Pom-pom"};
const wchar_t* const kFaceTitles[8] = {L"Classic", L"Happy", L"Wink", L"Cool", L"Surprised", L"Sleepy", L"Grumpy", L"In love"};
const wchar_t* const kBodyTitles[8] = {L"Sticks", L"Waving", L"Mittens", L"Broom", L"Candy cane", L"Cocoa", L"Gift", L"Flowers"};
const wchar_t* const kClothesTitles[8] = {L"None", L"Red scarf", L"Green scarf", L"Striped scarf", L"Bow tie", L"Vest", L"Sweater", L"Cape"};

namespace {

typedef ComPtr<ID2D1Geometry> Geo;

struct Prim {
    int kind = 0;                      // 0 filled shape (+ optional stroke), 1 line, 2 label
    Geo geo;
    D2D1_COLOR_F fill{}, stroke{};
    float width = 0;
    float z = 0;
    std::wstring text;
    float x = 0, y = 0, size = 0;
};

const D2D1_COLOR_F kCoal = {0.12f, 0.12f, 0.14f, 1};
const D2D1_COLOR_F kCarrot = {1, 0.55f, 0.12f, 1};
const D2D1_COLOR_F kStick = {0.42f, 0.27f, 0.13f, 1};
const D2D1_COLOR_F kRed = {0.84f, 0.12f, 0.16f, 1};
const D2D1_COLOR_F kDarkRed = {0.6f, 0.06f, 0.1f, 1};
const D2D1_COLOR_F kGreen = {0.13f, 0.55f, 0.28f, 1};
const D2D1_COLOR_F kGold = {1, 0.8f, 0.22f, 1};
const D2D1_COLOR_F kDarkGold = {0.8f, 0.55f, 0.05f, 1};
const D2D1_COLOR_F kWhite = {1, 1, 1, 1};
const D2D1_COLOR_F kPink = {1, 0.5f, 0.6f, 0.45f};
const D2D1_COLOR_F kBlueZ = {0.35f, 0.55f, 0.95f, 1};

Geo Circle(float x, float y, float r)
{
    ComPtr<ID2D1EllipseGeometry> e;
    D2DFactory()->CreateEllipseGeometry(D2D1::Ellipse(Point2F(x, y), r, r), &e);
    Geo g; e.As(&g); return g;
}

Geo RectG(float x, float y, float w, float h, float r = 0)
{
    float rr = std::min(r, std::min(w / 2 - 0.01f, h / 2 - 0.01f));
    ComPtr<ID2D1RoundedRectangleGeometry> e;
    D2DFactory()->CreateRoundedRectangleGeometry(D2D1::RoundedRect(D2D1::RectF(x, y, x + w, y + h), std::max(0.f, rr), std::max(0.f, rr)), &e);
    Geo g; e.As(&g); return g;
}

class PathB {
public:
    PathB()
    {
        D2DFactory()->CreatePathGeometry(&geo_);
        geo_->Open(&sink_);
        sink_->SetFillMode(D2D1_FILL_MODE_WINDING);
    }
    PathB& M(float x, float y) { End(); sink_->BeginFigure(Point2F(x, y), D2D1_FIGURE_BEGIN_FILLED); open_ = true; return *this; }
    PathB& L(float x, float y) { sink_->AddLine(Point2F(x, y)); return *this; }
    PathB& Q(float cx, float cy, float x, float y) { sink_->AddQuadraticBezier(D2D1::QuadraticBezierSegment(Point2F(cx, cy), Point2F(x, y))); return *this; }
    PathB& C(float ax, float ay, float bx, float by, float x, float y)
    {
        sink_->AddBezier(D2D1::BezierSegment(Point2F(ax, ay), Point2F(bx, by), Point2F(x, y)));
        return *this;
    }
    /// Arc (degrees, counter-clockwise in y-up coordinates) approximated by short lines.
    PathB& Arc(float cx, float cy, float r, float a0, float a1, bool move)
    {
        const int n = 20;
        for (int i = 0; i <= n; i++) {
            float a = (a0 + (a1 - a0) * i / n) * kPi / 180;
            float x = cx + r * std::cos(a), y = cy + r * std::sin(a);
            if (i == 0 && move) M(x, y); else L(x, y);
        }
        return *this;
    }
    PathB& Z() { if (open_) sink_->EndFigure(D2D1_FIGURE_END_CLOSED); open_ = false; return *this; }
    Geo Done() { End(); sink_->Close(); Geo g; geo_.As(&g); return g; }
private:
    void End() { if (open_) sink_->EndFigure(D2D1_FIGURE_END_OPEN); open_ = false; }
    ComPtr<ID2D1PathGeometry> geo_;
    ComPtr<ID2D1GeometrySink> sink_;
    bool open_ = false;
};

Geo Poly(std::initializer_list<float> xy, bool closed = true)
{
    PathB p;
    const float* v = xy.begin();
    p.M(v[0], v[1]);
    for (size_t i = 1; i < xy.size() / 2; i++) p.L(v[2 * i], v[2 * i + 1]);
    if (closed) p.Z();
    return p.Done();
}

Prim Shape(Geo g, D2D1_COLOR_F c, float z, D2D1_COLOR_F stroke = {0, 0, 0, 0}, float width = 0)
{
    Prim p;
    p.kind = 0; p.geo = g; p.fill = c; p.z = z; p.stroke = stroke; p.width = width;
    return p;
}
Prim Line(Geo g, D2D1_COLOR_F c, float width, float z)
{
    Prim p;
    p.kind = 1; p.geo = g; p.stroke = c; p.width = width; p.z = z;
    return p;
}
Prim Label(const wchar_t* t, float x, float y, float size, float z, D2D1_COLOR_F c = {0, 0, 0, 1})
{
    Prim p;
    p.kind = 2; p.text = t; p.x = x; p.y = y; p.size = size; p.z = z; p.fill = c;
    return p;
}
Geo ArcG(float cx, float cy, float r, float a0, float a1) { PathB p; p.Arc(cx, cy, r, a0, a1, true); return p.Done(); }

typedef std::vector<Prim> Prims;
void Add(Prims& a, const Prims& b) { a.insert(a.end(), b.begin(), b.end()); }

Prim Eye(float x, float y, float r) { return Shape(Circle(x, y, r), kCoal, 2); }
Prim CarrotP() { return Shape(Poly({-2, 7, 32, 1, -2, -4}), kCarrot, 2.2f); }
Prims DotSmile()
{
    Prims p;
    for (int k = 0; k < 5; k++) {
        float a = (220 + 25 * k) * kPi / 180;
        p.push_back(Shape(Circle(22 * std::cos(a), 4 + 22 * std::sin(a), 3.2f), kCoal, 2));
    }
    return p;
}
Prim WideSmile() { return Line(ArcG(0, -2, 20, 205, 335), kCoal, 4, 2); }
Prims Cheeks() { return {Shape(Circle(-28, -4, 6), kPink, 1.5f), Shape(Circle(28, -4, 6), kPink, 1.5f)}; }
Prims Heart(float x, float y, float s)
{
    D2D1_COLOR_F c = Rgb(0.92f, 0.15f, 0.3f);
    return {Shape(Circle(x - s * 0.24f, y + s * 0.12f, s * 0.28f), c, 2), Shape(Circle(x + s * 0.24f, y + s * 0.12f, s * 0.28f), c, 2),
            Shape(Poly({x - s * 0.5f, y + s * 0.06f, x + s * 0.5f, y + s * 0.06f, x, y - s * 0.5f}), c, 2)};
}

Prims Face(int f)
{
    Prims p;
    switch (f) {
    case 0: p = {Eye(-15, 15, 5.5f), Eye(15, 15, 5.5f), CarrotP()}; Add(p, DotSmile()); break;
    case 1:
        p = {Line(ArcG(-15, 12, 6, 0, 180), kCoal, 3.5f, 2), Line(ArcG(15, 12, 6, 0, 180), kCoal, 3.5f, 2), CarrotP(), WideSmile()};
        Add(p, Cheeks());
        break;
    case 2: p = {Eye(-15, 15, 5.5f), Line(ArcG(15, 12, 6, 0, 180), kCoal, 3.5f, 2), CarrotP()}; Add(p, DotSmile()); break;
    case 3: {
        D2D1_COLOR_F black = Rgb(0.05f, 0.05f, 0.07f);
        p = {Shape(RectG(-30, 7, 24, 14, 5), black, 2), Shape(RectG(6, 7, 24, 14, 5), black, 2),
             Line(Poly({-6, 16, 6, 16}, false), black, 3, 2), Line(Poly({-30, 17, -42, 21}, false), black, 3, 2),
             Line(Poly({30, 17, 42, 21}, false), black, 3, 2), Line(Poly({-26, 17, -21, 12}, false), Rgb(1, 1, 1, 0.55f), 2, 2.1f),
             Line(Poly({10, 17, 15, 12}, false), Rgb(1, 1, 1, 0.55f), 2, 2.1f), CarrotP(),
             Line(Poly({-12, -20, 2, -19, 14, -13}, false), kCoal, 3.5f, 2)};
        break;
    }
    case 4:
        p = {Eye(-15, 15, 6.5f), Eye(15, 15, 6.5f), Line(ArcG(-15, 20, 11, 55, 125), kCoal, 3, 2),
             Line(ArcG(15, 20, 11, 55, 125), kCoal, 3, 2), CarrotP(), Shape(Circle(0, -22, 7), Rgb(0.3f, 0.1f, 0.1f), 2, kCoal, 3)};
        break;
    case 5:
        p = {Line(ArcG(-15, 18, 6, 200, 340), kCoal, 3.5f, 2), Line(ArcG(15, 18, 6, 200, 340), kCoal, 3.5f, 2), CarrotP(),
             Shape(Circle(0, -21, 3.5f), kCoal, 2), Label(L"z", 36, 40, 13, 2, kBlueZ), Label(L"Z", 48, 57, 19, 2, kBlueZ)};
        break;
    case 6:
        p = {Eye(-15, 13, 5), Eye(15, 13, 5), Line(Poly({-25, 27, -7, 21}, false), kCoal, 4, 2),
             Line(Poly({25, 27, 7, 21}, false), kCoal, 4, 2), CarrotP(), Line(ArcG(0, -34, 16, 35, 145), kCoal, 4, 2)};
        break;
    default:
        p = Heart(-15, 15, 15);
        Add(p, Heart(15, 15, 15));
        p.push_back(CarrotP());
        p.push_back(WideSmile());
        Add(p, Cheeks());
        break;
    }
    return p;
}

Prim Dome(D2D1_COLOR_F c) { PathB p; p.M(-40, 36).C(-40, 96, 40, 96, 40, 36).Z(); return Shape(p.Done(), c, 3); }

Prims Hat(int h)
{
    switch (h) {
    case 1: {
        PathB p;
        p.M(-36, 38).Q(0, 122, 44, 80).Q(24, 66, 36, 38).Z();
        return {Shape(p.Done(), kRed, 3), Shape(RectG(-42, 30, 84, 14, 7), kWhite, 3.1f), Shape(Circle(46, 77, 9), kWhite, 3.1f)};
    }
    case 2: {
        D2D1_COLOR_F black = Rgb(0.08f, 0.08f, 0.1f);
        return {Shape(RectG(-26, 42, 52, 50, 3), black, 3), Shape(RectG(-26, 46, 52, 9), kRed, 3.1f), Shape(RectG(-40, 36, 80, 8, 4), black, 3.2f)};
    }
    case 3: return {Dome(Rgb(0.2f, 0.45f, 0.85f)), Shape(RectG(-42, 30, 84, 14, 6), Rgb(0.12f, 0.3f, 0.65f), 3.1f)};
    case 4:
        return {Line(ArcG(0, 6, 50, 15, 165), Rgb(0.3f, 0.3f, 0.35f), 6, 3), Shape(Circle(-47, 18, 12), Rgb(1, 0.62f, 0.75f), 3.1f, kWhite, 3),
                Shape(Circle(47, 18, 12), Rgb(1, 0.62f, 0.75f), 3.1f, kWhite, 3)};
    case 5:
        return {Shape(Poly({-30, 40, 30, 40, 36, 84, 18, 64, 0, 92, -18, 64, -36, 84}), kGold, 3, kDarkGold, 2),
                Shape(Circle(0, 52, 4), kRed, 3.1f), Shape(Circle(-18, 50, 3), Rgb(0.2f, 0.4f, 0.95f), 3.1f), Shape(Circle(18, 50, 3), kGreen, 3.1f)};
    case 6:
        return {Shape(Poly({-24, 40, 24, 40, 31, 78, -31, 78}), Rgb(0.8f, 0.42f, 0.25f), 3), Shape(RectG(-35, 74, 70, 11, 3), Rgb(0.66f, 0.32f, 0.18f), 3.1f),
                Label(L"\U0001F337", 0, 100, 28, 2.9f)};
    case 7:
        return {Dome(kRed), Shape(RectG(-36, 50, 72, 7, 3), kWhite, 3.05f), Shape(RectG(-28, 64, 56, 6, 3), kWhite, 3.05f),
                Shape(RectG(-42, 30, 84, 13, 6), kWhite, 3.1f), Shape(Circle(0, 90, 11), kWhite, 3.1f)};
    default: return {};
    }
}

Prims StickArm(float s)
{
    return {Line(Poly({s * 40, 12, s * 104, 44}, false), kStick, 5, -1), Line(Poly({s * 86, 35, s * 94, 58}, false), kStick, 3.5f, -1),
            Line(Poly({s * 96, 39, s * 114, 36}, false), kStick, 3.5f, -1)};
}

Prims Body(int b)
{
    Prims sticks = StickArm(-1);
    Add(sticks, StickArm(1));
    Prims p;
    switch (b) {
    case 0: return sticks;
    case 1:
        p = StickArm(-1);
        Add(p, {Line(Poly({40, 14, 86, 88}, false), kStick, 5, -1), Line(Poly({78, 75, 66, 94}, false), kStick, 3.5f, -1),
                Line(Poly({86, 88, 104, 96}, false), kStick, 3.5f, -1), Line(Poly({86, 88, 88, 106}, false), kStick, 3.5f, -1)});
        return p;
    case 2:
        p = sticks;
        for (float s : {-1.f, 1.f})
            Add(p, {Shape(Circle(s * 106, 44, 11), kRed, 1), Shape(Circle(s * 98, 55, 5.5f), kRed, 1), Shape(RectG(s * 106 - 10, 30, 20, 6, 3), kWhite, 1.1f)});
        return p;
    case 3:
        p = StickArm(-1);
        Add(p, {Line(Poly({40, 12, 96, 36}, false), kStick, 5, -1), Line(Poly({112, 104, 84, -50}, false), Rgb(0.6f, 0.42f, 0.2f), 5, 1),
                Shape(Poly({72, -48, 94, -52, 100, -96, 60, -90}), Rgb(0.88f, 0.72f, 0.36f), 1.1f, Rgb(0.7f, 0.55f, 0.25f), 1.5f),
                Line(Poly({72, -54, 95, -58}, false), kRed, 4, 1.2f)});
        return p;
    case 4: {
        p = sticks;
        PathB cane;
        cane.M(102, -46).L(102, 52).Arc(90, 52, 12, 0, 180, false).L(78, 42);
        p.push_back(Line(cane.Done(), kRed, 7, 1));
        for (float y = -36; y <= 36; y += 18) p.push_back(Line(Poly({99, y - 3, 105, y + 3}, false), kWhite, 2.5f, 1.1f));
        return p;
    }
    case 5: p = sticks; p.push_back(Label(L"☕", 114, 50, 26, 1)); return p;
    case 6:
        p = sticks;
        Add(p, {Shape(RectG(94, 30, 26, 22, 2), kRed, 1), Shape(RectG(105, 30, 4, 22), kGold, 1.1f), Shape(RectG(94, 39, 26, 4), kGold, 1.1f),
                Shape(Circle(103, 55, 4), kGold, 1.2f), Shape(Circle(111, 55, 4), kGold, 1.2f)});
        return p;
    default: p = sticks; p.push_back(Label(L"\U0001F490", 114, 54, 28, 1)); return p;
    }
}

Prims Scarf(D2D1_COLOR_F c, bool striped)
{
    Prims p = {Shape(RectG(-37, -49, 74, 15, 7), c, 1.5f), Shape(RectG(12, -88, 15, 44, 5), c, 1.4f)};
    if (striped) {
        for (float x : {-22.f, -4.f, 14.f}) p.push_back(Shape(RectG(x, -49, 6, 15), kWhite, 1.55f));
        for (float y : {-70.f, -82.f}) p.push_back(Shape(RectG(12, y, 15, 5), kWhite, 1.45f));
    }
    return p;
}

Prims NeckClothes(int c)
{
    switch (c) {
    case 1: return Scarf(kRed, false);
    case 2: return Scarf(kGreen, false);
    case 3: return Scarf(kRed, true);
    case 4:
        return {Shape(Poly({0, -44, -20, -33, -20, -56}), kRed, 1.5f), Shape(Poly({0, -44, 20, -33, 20, -56}), kRed, 1.5f),
                Shape(Circle(0, -44, 5), kDarkRed, 1.6f)};
    default: return {};
    }
}

Prims BodyClothes(int c)
{
    switch (c) {
    case 5: {
        D2D1_COLOR_F v = Rgb(0.38f, 0.24f, 0.16f);
        return {Shape(Poly({-44, 22, -14, 40, -10, -34, -28, -42, -48, -10}), v, 0.4f), Shape(Poly({44, 22, 14, 40, 10, -34, 28, -42, 48, -10}), v, 0.4f)};
    }
    case 6: {
        PathB z1, z2;
        int k = 0;
        for (float x = -42; x <= 42; x += 12, k++) {
            float d = k % 2 == 0 ? 5.f : -5.f;
            if (k == 0) { z1.M(x, 12 + d); z2.M(x, -16 + d); } else { z1.L(x, 12 + d); z2.L(x, -16 + d); }
        }
        return {Shape(Circle(0, -1, 47), Rgb(0.78f, 0.15f, 0.2f), 0.3f), Line(z1.Done(), kWhite, 3, 0.35f), Line(z2.Done(), kWhite, 3, 0.35f),
                Shape(RectG(-20, 36, 40, 10, 5), kDarkRed, 0.36f)};
    }
    case 7: return {Shape(Poly({-34, 50, 34, 50, 72, -40, -72, -40}), Rgb(0.75f, 0.1f, 0.15f), -2), Shape(Circle(0, 47, 5), kGold, 0.5f)};
    default: return {};
    }
}

Prims Buttons() { return {Shape(Circle(0, 24, 5), kCoal, 0.6f), Shape(Circle(0, 2, 5), kCoal, 0.6f), Shape(Circle(0, -20, 5), kCoal, 0.6f)}; }

std::map<std::string, Prims>& Cache() { static std::map<std::string, Prims> c; return c; }

const Prims& Decor(const Outfit& o, int tiers, int i)
{
    char key[64];
    sprintf_s(key, "%d-%d-%s", tiers, i, o.Key().c_str());
    auto& c = Cache();
    auto it = c.find(key);
    if (it != c.end()) return it->second;
    Prims p;
    bool head = tiers >= 2 && i == tiers - 1;
    bool body = (tiers == 2 && i == 0) || (tiers == 3 && i == 1);
    if (head) { Add(p, Face(o.face)); Add(p, Hat(o.hat)); Add(p, NeckClothes(o.clothes)); }
    if (body) { Add(p, Body(o.body)); Add(p, BodyClothes(o.clothes)); if (tiers == 3) Add(p, Buttons()); }
    std::stable_sort(p.begin(), p.end(), [](const Prim& a, const Prim& b) { return a.z < b.z; });
    if (c.size() > 400) c.clear();
    return c[key] = p;
}

ComPtr<ID2D1StrokeStyle>& RoundCaps()
{
    static ComPtr<ID2D1StrokeStyle> s;
    if (!s) {
        D2D1_STROKE_STYLE_PROPERTIES p = D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND, D2D1_LINE_JOIN_ROUND);
        D2DFactory()->CreateStrokeStyle(p, nullptr, 0, &s);
    }
    return s;
}

void DrawPrims(ID2D1RenderTarget* rt, const Prims& prims, bool behind, const D2D1_MATRIX_3X2_F& m)
{
    ComPtr<ID2D1SolidColorBrush> brush;
    rt->CreateSolidColorBrush(Rgb(0, 0, 0), &brush);
    D2D1_MATRIX_3X2_F old;
    rt->GetTransform(&old);
    float scale = std::sqrt(m._11 * m._11 + m._12 * m._12);
    for (const Prim& p : prims) {
        if ((p.z < 0) != behind) continue;
        if (p.kind == 2) {
            D2D1_POINT_2F c = Matrix3x2F::ReinterpretBaseType(&m)->TransformPoint(Point2F(p.x, p.y));
            rt->SetTransform(Matrix3x2F::Identity());
            DrawLabel(rt, p.text.c_str(), c.x, c.y, p.size * scale, p.fill);
            continue;
        }
        rt->SetTransform(m);
        if (p.kind == 0) {
            brush->SetColor(p.fill);
            rt->FillGeometry(p.geo.Get(), brush.Get());
            if (p.width > 0) { brush->SetColor(p.stroke); rt->DrawGeometry(p.geo.Get(), brush.Get(), p.width, RoundCaps().Get()); }
        } else {
            brush->SetColor(p.stroke);
            rt->DrawGeometry(p.geo.Get(), brush.Get(), p.width, RoundCaps().Get());
        }
    }
    rt->SetTransform(old);
}

}  // namespace

void DrawLabel(ID2D1RenderTarget* rt, const wchar_t* text, float x, float y, float size, D2D1_COLOR_F color, float opacity)
{
    static ComPtr<IDWriteTextFormat> fmt;
    if (!fmt && DWFactory()) {
        DWFactory()->CreateTextFormat(L"Segoe UI Emoji", nullptr, DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                                      32, L"", &fmt);
        if (fmt) {
            fmt->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
            fmt->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
            fmt->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        }
    }
    if (!fmt || size <= 0.5f) return;
    D2D1_MATRIX_3X2_F old;
    rt->GetTransform(&old);
    float k = size / 32.f;
    rt->SetTransform(Matrix3x2F::Scale(k, k) * Matrix3x2F::Translation(x, y) * *Matrix3x2F::ReinterpretBaseType(&old));
    ComPtr<ID2D1SolidColorBrush> b;
    rt->CreateSolidColorBrush(WithA(color, color.a * opacity), &b);
    ComPtr<ID2D1DeviceContext> dctx;
    rt->QueryInterface(IID_PPV_ARGS(&dctx));
    UINT32 len = (UINT32)wcslen(text);
    D2D1_RECT_F box = D2D1::RectF(-200, -40, 200, 40);
    if (dctx) {
        if (opacity < 0.999f) {
            dctx->PushLayer(D2D1::LayerParameters1(D2D1::InfiniteRect(), nullptr, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE, D2D1::IdentityMatrix(), opacity), nullptr);
            b->SetColor(color);
        }
        dctx->DrawText(text, len, fmt.Get(), box, b.Get(), D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
        if (opacity < 0.999f) dctx->PopLayer();
    } else {
        rt->DrawText(text, len, fmt.Get(), box, b.Get());
    }
    rt->SetTransform(old);
}

void DrawBallDecor(ID2D1RenderTarget* rt, const Outfit& o, int tiers, int tierIndex, bool behind, const D2D1_MATRIX_3X2_F& m)
{
    if (tiers < 2) return;
    DrawPrims(rt, Decor(o, tiers, tierIndex), behind, m);
}

void DrawOutfitPreview(ID2D1RenderTarget* rt, int tab, int option, const D2D1_RECT_F& box)
{
    Prims p;
    float bx0, by0, bx1, by1;   // content bounds in ball units (y up)
    switch (tab) {
    case 0: p = Face(0); Add(p, Hat(option)); bx0 = -60; by0 = -55; bx1 = 60; by1 = 125; break;
    case 1: p = Face(option); bx0 = -55; by0 = -55; bx1 = 60; by1 = 65; break;
    case 2: p = Body(option); bx0 = -125; by0 = -100; bx1 = 130; by1 = 112; break;
    default:
        p = NeckClothes(option);
        if (!p.empty()) { Prims f = Face(0); Add(f, p); p = f; bx0 = -55; by0 = -92; bx1 = 55; by1 = 60; }
        else { p = BodyClothes(option); bx0 = -75; by0 = -55; bx1 = 75; by1 = 55; }
        break;
    }
    std::stable_sort(p.begin(), p.end(), [](const Prim& a, const Prim& b) { return a.z < b.z; });
    float bw = box.right - box.left, bh = box.bottom - box.top;
    float k = std::min(bw / (bx1 - bx0), bh / (by1 - by0));
    float cx = box.left + bw / 2 - (bx0 + bx1) / 2 * k;
    float cy = box.top + bh / 2 + (by0 + by1) / 2 * k;
    D2D1_MATRIX_3X2_F old;
    rt->GetTransform(&old);
    Matrix3x2F m = Matrix3x2F::Scale(k, -k) * Matrix3x2F::Translation(cx, cy) * *Matrix3x2F::ReinterpretBaseType(&old);
    DrawPrims(rt, p, true, m);
    // the ball
    ComPtr<ID2D1GradientStopCollection> coll;
    D2D1_GRADIENT_STOP st[] = {{0, Rgb(1, 1, 1)}, {0.55f, Rgb(0.95f, 0.97f, 1)}, {1, Rgb(0.82f, 0.87f, 0.96f)}};
    rt->CreateGradientStopCollection(st, 3, &coll);
    ComPtr<ID2D1RadialGradientBrush> ball;
    rt->CreateRadialGradientBrush(D2D1::RadialGradientBrushProperties(Point2F(0, 0), Point2F(-12, 15), 50, 50), coll.Get(), &ball);
    rt->SetTransform(m);
    if (ball) rt->FillEllipse(D2D1::Ellipse(Point2F(0, 0), 50, 50), ball.Get());
    rt->SetTransform(old);
    DrawPrims(rt, p, false, m);
}
