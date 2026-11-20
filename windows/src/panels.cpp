// Small layered popups on the internal display: toast / hint labels (click-through), the light
// linking coach mark (click-through except its button) and the snowman customize panel
// ("Fashion week, but colder."). Each is a per-pixel-alpha layered window drawn with a Direct2D
// DC render target into a DIB; they redraw only when something changes (the coach animates for
// at most 8 s). Shown without activation; only the customize panel can take focus, and only when
// the user clicks into it.
#include "winterdesk.h"

using D2D1::Point2F;

namespace {

HINSTANCE g_inst = nullptr;
const wchar_t* kPanelClass = L"WinterDeskPanel";

class Panel {
public:
    virtual ~Panel() { Destroy(); }
    bool Create(int x, int y, int w, int h, bool clickThrough)
    {
        Destroy();
        x_ = x; y_ = y; w_ = w; h_ = h;
        DWORD ex = WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | (clickThrough ? WS_EX_TRANSPARENT | WS_EX_NOACTIVATE : 0);
        hwnd_ = CreateWindowExW(ex, kPanelClass, L"WinterDesk", WS_POPUP, x, y, w, h, nullptr, nullptr, g_inst, nullptr);
        if (!hwnd_) return false;
        SetWindowLongPtrW(hwnd_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
        BITMAPINFO bi{};
        bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
        bi.bmiHeader.biWidth = w;
        bi.bmiHeader.biHeight = -h;
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 32;
        HDC screen = GetDC(nullptr);
        mem_ = CreateCompatibleDC(screen);
        void* bits = nullptr;
        dib_ = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
        ReleaseDC(nullptr, screen);
        if (!dib_) return false;
        old_ = SelectObject(mem_, dib_);
        D2D1_RENDER_TARGET_PROPERTIES p = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
        if (FAILED(D2DFactory()->CreateDCRenderTarget(&p, &rt_))) return false;
        return true;
    }
    void Destroy()
    {
        rt_.Reset();
        if (mem_) { SelectObject(mem_, old_); DeleteDC(mem_); mem_ = nullptr; }
        if (dib_) { DeleteObject(dib_); dib_ = nullptr; }
        if (hwnd_) { SetWindowLongPtrW(hwnd_, GWLP_USERDATA, 0); DestroyWindow(hwnd_); hwnd_ = nullptr; }
    }
    void Redraw(BYTE alpha = 255)
    {
        if (!rt_ || !hwnd_) return;
        RECT rc = {0, 0, w_, h_};
        rt_->BindDC(mem_, &rc);
        rt_->BeginDraw();
        rt_->Clear(D2D1::ColorF(0, 0, 0, 0));
        Draw(rt_.Get());
        if (rt_->EndDraw() == D2DERR_RECREATE_TARGET) return;
        POINT dst = {x_, y_}, src = {0, 0};
        SIZE size = {w_, h_};
        BLENDFUNCTION bf = {AC_SRC_OVER, 0, alpha, AC_SRC_ALPHA};
        UpdateLayeredWindow(hwnd_, nullptr, &dst, &size, mem_, &src, 0, &bf, ULW_ALPHA);
    }
    void Show() { if (hwnd_) ShowWindow(hwnd_, SW_SHOWNOACTIVATE); }
    HWND Hwnd() const { return hwnd_; }
    virtual void Draw(ID2D1RenderTarget* rt) = 0;
    virtual LRESULT Message(UINT m, WPARAM w, LPARAM l) { return DefWindowProcW(hwnd_, m, w, l); }

protected:
    HWND hwnd_ = nullptr;
    HDC mem_ = nullptr;
    HBITMAP dib_ = nullptr;
    HGDIOBJ old_ = nullptr;
    ComPtr<ID2D1DCRenderTarget> rt_;
    int x_ = 0, y_ = 0, w_ = 0, h_ = 0;
};

LRESULT CALLBACK PanelProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    Panel* p = reinterpret_cast<Panel*>(GetWindowLongPtrW(h, GWLP_USERDATA));
    if (p) return p->Message(m, w, l);
    return DefWindowProcW(h, m, w, l);
}

ComPtr<IDWriteTextFormat> Format(float size, DWRITE_FONT_WEIGHT weight, bool center = true, bool wrap = false)
{
    ComPtr<IDWriteTextFormat> f;
    DWFactory()->CreateTextFormat(L"Segoe UI", nullptr, weight, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, L"", &f);
    if (f) {
        f->SetTextAlignment(center ? DWRITE_TEXT_ALIGNMENT_CENTER : DWRITE_TEXT_ALIGNMENT_LEADING);
        f->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        f->SetWordWrapping(wrap ? DWRITE_WORD_WRAPPING_WRAP : DWRITE_WORD_WRAPPING_NO_WRAP);
    }
    return f;
}

float TextWidth(IDWriteTextFormat* f, const std::wstring& t)
{
    ComPtr<IDWriteTextLayout> l;
    if (FAILED(DWFactory()->CreateTextLayout(t.c_str(), (UINT32)t.size(), f, 4000, 200, &l))) return 100;
    DWRITE_TEXT_METRICS m{};
    l->GetMetrics(&m);
    return m.widthIncludingTrailingWhitespace;
}

void Solid(ID2D1RenderTarget* rt, ComPtr<ID2D1SolidColorBrush>& b, D2D1_COLOR_F c)
{
    if (!b) rt->CreateSolidColorBrush(c, &b); else b->SetColor(c);
}

// ---------------------------------------------------------------------------------------------
// Label (toast / hint): rounded dark translucent pill near the top centre, click-through.
// ---------------------------------------------------------------------------------------------
class Label : public Panel {
public:
    void Open(const PanelHost& h, const std::wstring& text, float fontPt, float yFromTopPt)
    {
        text_ = text;
        s_ = h.scale;
        fmt_ = Format(fontPt * s_, DWRITE_FONT_WEIGHT_SEMI_BOLD);
        int w = (int)std::ceil(TextWidth(fmt_.Get(), text) + 36 * s_), hh = (int)std::ceil((fontPt * 1.35f + 18) * s_);
        int x = (h.work.left + h.work.right) / 2 - w / 2, y = h.work.top + (int)(yFromTopPt * s_);
        Create(x, y, w, hh, true);
        Redraw();
        Show();
    }
    void Draw(ID2D1RenderTarget* rt) override
    {
        Solid(rt, brush_, D2D1::ColorF(0.08f, 0.08f, 0.08f, 0.72f));
        D2D1_RECT_F r = D2D1::RectF(0, 0, (float)w_, (float)h_);
        rt->FillRoundedRectangle(D2D1::RoundedRect(r, h_ / 2.f, h_ / 2.f), brush_.Get());
        brush_->SetColor(D2D1::ColorF(1, 1, 1));
        ComPtr<ID2D1DeviceContext> dctx;
        rt->QueryInterface(IID_PPV_ARGS(&dctx));
        if (dctx) dctx->DrawText(text_.c_str(), (UINT32)text_.size(), fmt_.Get(), r, brush_.Get(), D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
        else rt->DrawText(text_.c_str(), (UINT32)text_.size(), fmt_.Get(), r, brush_.Get());
    }
    LRESULT Message(UINT m, WPARAM w, LPARAM l) override
    {
        if (m == WM_TIMER) {
            if (w == 1) { KillTimer(hwnd_, 1); fade_ = 0; SetTimer(hwnd_, 2, 30, nullptr); }
            else if (w == 2) {
                fade_ += 30;
                if (fade_ >= 300) { KillTimer(hwnd_, 2); Destroy(); return 0; }
                Redraw((BYTE)(255 * (1 - fade_ / 300.0)));
            }
            return 0;
        }
        if (m == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
        return Panel::Message(m, w, l);
    }
    void StartFade(UINT afterMs) { if (hwnd_) SetTimer(hwnd_, 1, afterMs, nullptr); }
private:
    std::wstring text_;
    float s_ = 1;
    int fade_ = 0;
    ComPtr<IDWriteTextFormat> fmt_;
    ComPtr<ID2D1SolidColorBrush> brush_;
};

// ---------------------------------------------------------------------------------------------
// Coach mark: animated "how to link lights" with a "알겠어요" button (CoachPanel.swift)
// ---------------------------------------------------------------------------------------------
class Coach : public Panel {
public:
    void Open(const PanelHost& h, std::function<void()> onDismiss)
    {
        s_ = h.scale;
        onDismiss_ = std::move(onDismiss);
        int w = (int)(460 * s_), hh = (int)(176 * s_);
        int x = (h.work.left + h.work.right) / 2 - w / 2, y = h.work.top + (int)(64 * s_);
        text_ = L"창 위 금색 점을 끌어서 다른 창의 금색 점에 놓으면 "
                L"전구가 연결돼요 · 전구 클릭 = 삭제 · Esc = 끝내기";
        fmt_ = Format(13 * s_, DWRITE_FONT_WEIGHT_SEMI_BOLD, true, true);
        btnFmt_ = Format(13 * s_, DWRITE_FONT_WEIGHT_BOLD);
        Create(x, y, w, hh, true);
        btn_ = {x + w / 2 - (int)(50 * s_), y + hh - (int)(34 * s_), x + w / 2 + (int)(50 * s_), y + hh - (int)(8 * s_)};
        phase_ = 0;
        Redraw();
        Show();
        SetTimer(hwnd_, 1, 33, nullptr);
        SetTimer(hwnd_, 2, 8000, nullptr);
    }
    void Cursor(POINT p)
    {
        if (!hwnd_) return;
        bool over = PtInRect(&btn_, p) != FALSE;
        if (over == clickable_) return;
        clickable_ = over;
        LONG_PTR ex = GetWindowLongPtrW(hwnd_, GWL_EXSTYLE);
        SetWindowLongPtrW(hwnd_, GWL_EXSTYLE, over ? (ex & ~(LONG_PTR)WS_EX_TRANSPARENT) : (ex | WS_EX_TRANSPARENT));
    }
    void Dismiss()
    {
        if (!hwnd_) return;
        Destroy();
        clickable_ = false;
        if (onDismiss_) { auto f = onDismiss_; onDismiss_ = nullptr; f(); }
    }
    void Draw(ID2D1RenderTarget* rt) override
    {
        float W = (float)w_, H = (float)h_, s = s_;
        Solid(rt, b_, D2D1::ColorF(0.08f, 0.08f, 0.08f, 0.86f));
        rt->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(0, 0, W, H), 16 * s, 16 * s), b_.Get());
        // animation area (60, 12) .. (W-60, 92): two window tops, a dot dragging a dashed wire
        float ax = 60 * s + 26 * s, bx = W - 60 * s - 26 * s, ay = 12 * s + 80 * s / 2 - 6 * s;
        b_->SetColor(D2D1::ColorF(1, 1, 1, 0.25f));
        for (float x : {ax, bx}) rt->DrawRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(x - 22 * s, ay, x + 22 * s, 12 * s + 76 * s), 4 * s, 4 * s), b_.Get(), 1);
        float p = std::min(1.f, phase_ / 0.6f);
        D2D1_POINT_2F a = Point2F(ax, ay), e = Point2F(ax + (bx - ax) * p, ay + std::sin(kPi * p) * 14 * s);
        ComPtr<ID2D1PathGeometry> wire;
        D2DFactory()->CreatePathGeometry(&wire);
        ComPtr<ID2D1GeometrySink> sink;
        wire->Open(&sink);
        sink->BeginFigure(a, D2D1_FIGURE_BEGIN_HOLLOW);
        sink->AddBezier(D2D1::BezierSegment(Point2F(a.x + (e.x - a.x) * 0.3f, a.y + 18 * s * p), Point2F(a.x + (e.x - a.x) * 0.7f, e.y + 10 * s * p), e));
        sink->EndFigure(D2D1_FIGURE_END_OPEN);
        sink->Close();
        if (!dash_) {
            float d[] = {2.5f, 2.f};
            D2DFactory()->CreateStrokeStyle(D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT,
                                                                        D2D1_LINE_JOIN_ROUND, 10, D2D1_DASH_STYLE_CUSTOM, 0), d, 2, &dash_);
        }
        b_->SetColor(D2D1::ColorF(1, 1, 1, 0.85f));
        rt->DrawGeometry(wire.Get(), b_.Get(), 2 * s, dash_.Get());
        if (phase_ > 0.6f) {
            const D2D1_COLOR_F cols[5] = {D2D1::ColorF(1, 0.23f, 0.19f), D2D1::ColorF(0.2f, 0.78f, 0.35f), D2D1::ColorF(0, 0.48f, 1),
                                          D2D1::ColorF(1, 0.8f, 0), D2D1::ColorF(1, 0.58f, 0)};
            for (int k = 0; k < 5; k++) {
                float t = (k + 0.5f) / 5;
                D2D1_COLOR_F c = cols[k];
                c.a = std::min(1.f, (phase_ - 0.6f) * 4);
                b_->SetColor(c);
                rt->FillEllipse(D2D1::Ellipse(Point2F(ax + (bx - ax) * t, ay + std::sin(kPi * t) * 14 * s + 4 * s), 3 * s, 4 * s), b_.Get());
            }
        }
        D2D1_POINT_2F dots[2] = {a, Point2F(bx, ay)};
        for (int i = 0; i < 2; i++) {
            float r = (7 + (i == 1 && phase_ > 0.55f ? 3 : 0)) * s;
            b_->SetColor(D2D1::ColorF(1, 0.8f, 0.25f, 0.35f));
            rt->FillEllipse(D2D1::Ellipse(dots[i], r + 5 * s, r + 5 * s), b_.Get());
            b_->SetColor(D2D1::ColorF(1, 0.8f, 0.25f, 1));
            rt->FillEllipse(D2D1::Ellipse(dots[i], r, r), b_.Get());
        }
        if (phase_ <= 0.6f) {                                 // tiny cursor arrow on the moving end
            ComPtr<ID2D1PathGeometry> c;
            D2DFactory()->CreatePathGeometry(&c);
            ComPtr<ID2D1GeometrySink> cs;
            c->Open(&cs);
            cs->BeginFigure(e, D2D1_FIGURE_BEGIN_FILLED);
            cs->AddLine(Point2F(e.x, e.y + 13 * s));
            cs->AddLine(Point2F(e.x + 4 * s, e.y + 9 * s));
            cs->AddLine(Point2F(e.x + 9 * s, e.y + 9 * s));
            cs->EndFigure(D2D1_FIGURE_END_CLOSED);
            cs->Close();
            b_->SetColor(D2D1::ColorF(1, 1, 1));
            rt->FillGeometry(c.Get(), b_.Get());
        }
        b_->SetColor(D2D1::ColorF(1, 1, 1));
        rt->DrawText(text_.c_str(), (UINT32)text_.size(), fmt_.Get(), D2D1::RectF(20 * s, 96 * s, W - 20 * s, 136 * s), b_.Get());
        D2D1_RECT_F br = D2D1::RectF(W / 2 - 50 * s, H - 34 * s, W / 2 + 50 * s, H - 8 * s);
        b_->SetColor(D2D1::ColorF(1, 0.8f, 0.25f, 0.95f));
        rt->FillRoundedRectangle(D2D1::RoundedRect(br, 13 * s, 13 * s), b_.Get());
        b_->SetColor(D2D1::ColorF(0.1f, 0.1f, 0.1f));
        const wchar_t* ok = L"알겠어요";
        rt->DrawText(ok, (UINT32)wcslen(ok), btnFmt_.Get(), br, b_.Get());
    }
    LRESULT Message(UINT m, WPARAM w, LPARAM l) override
    {
        switch (m) {
        case WM_TIMER:
            if (w == 1) { phase_ = std::fmod(phase_ + 1.f / 60, 1.f); Redraw(); }
            else if (w == 2) Dismiss();
            return 0;
        case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
        case WM_LBUTTONUP: Logf(L"TEST coach dismissed by button"); Dismiss(); return 0;
        default: return Panel::Message(m, w, l);
        }
    }
    bool Visible() const { return hwnd_ != nullptr; }
private:
    float s_ = 1, phase_ = 0;
    std::wstring text_;
    RECT btn_{};
    bool clickable_ = false;
    std::function<void()> onDismiss_;
    ComPtr<IDWriteTextFormat> fmt_, btnFmt_;
    ComPtr<ID2D1SolidColorBrush> b_;
    ComPtr<ID2D1StrokeStyle> dash_;
};

// ---------------------------------------------------------------------------------------------
// Customize panel (CustomizePanel.swift): 340 x 266 pt, title, ↺ / ✕, Hat / Face / Body / Clothes
// tabs, 2 x 4 option tiles with live previews; picks apply to the snowman immediately.
// ---------------------------------------------------------------------------------------------
class Customize : public Panel {
public:
    void Open(const PanelHost& h, const RECT& anchor, const CustomizeTarget& t)
    {
        s_ = h.scale;
        target_ = t;
        tab_ = 0;
        int w = (int)(340 * s_), hh = (int)(266 * s_);
        int x = anchor.right + (int)(14 * s_);
        if (x + w > h.work.right) x = anchor.left - (int)(14 * s_) - w;
        x = std::max((int)h.work.left + (int)(8 * s_), std::min(x, (int)h.work.right - w - (int)(8 * s_)));
        int y = (anchor.top + anchor.bottom) / 2 - hh / 2;
        y = std::max((int)h.work.top + (int)(8 * s_), std::min(y, (int)h.work.bottom - hh - (int)(8 * s_)));
        titleFmt_ = Format(15 * s_, DWRITE_FONT_WEIGHT_SEMI_BOLD, false);
        tabFmt_ = Format(12 * s_, DWRITE_FONT_WEIGHT_MEDIUM);
        tileFmt_ = Format(10.5f * s_, DWRITE_FONT_WEIGHT_MEDIUM);
        iconFmt_ = Format(12 * s_, DWRITE_FONT_WEIGHT_SEMI_BOLD);
        if (!hwnd_) { Create(x, y, w, hh, false); activated_ = false; }
        else { x_ = x; y_ = y; }
        Redraw();
        Show();
        SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }
    void Close()
    {
        Destroy();
        target_ = CustomizeTarget();
    }
    void Validate() { if (hwnd_ && (!target_.valid || !target_.valid())) { Logf(L"TEST customize panel closed (snowman gone)"); Close(); } }
    bool Visible() const { return hwnd_ != nullptr; }

    void Draw(ID2D1RenderTarget* rt) override
    {
        float W = (float)w_, H = (float)h_, s = s_;
        Solid(rt, b_, D2D1::ColorF(0.11f, 0.12f, 0.15f, 0.94f));     // frosted dark HUD look
        D2D1_ROUNDED_RECT bg = D2D1::RoundedRect(D2D1::RectF(0, 0, W, H), 16 * s, 16 * s);
        rt->FillRoundedRectangle(bg, b_.Get());
        b_->SetColor(D2D1::ColorF(1, 1, 1));
        const wchar_t* title = L"Fashion week, but colder.";
        rt->DrawText(title, (UINT32)wcslen(title), titleFmt_.Get(), D2D1::RectF(16 * s, 16 * s, 246 * s, 38 * s), b_.Get());
        const wchar_t* icons[2] = {L"↺", L"✕"};
        for (int i = 0; i < 2; i++) {
            D2D1_RECT_F r = IconRect(i);
            b_->SetColor(D2D1::ColorF(1, 1, 1, 0.14f));
            rt->FillEllipse(D2D1::Ellipse(Point2F((r.left + r.right) / 2, (r.top + r.bottom) / 2), (r.right - r.left) / 2 - 1, (r.bottom - r.top) / 2 - 1), b_.Get());
            b_->SetColor(D2D1::ColorF(1, 1, 1, 0.9f));
            rt->DrawText(icons[i], 1, iconFmt_.Get(), r, b_.Get());
        }
        // tab bar
        D2D1_RECT_F bar = D2D1::RectF(16 * s, 46 * s, W - 16 * s, 72 * s);
        float bh = bar.bottom - bar.top;
        b_->SetColor(D2D1::ColorF(1, 1, 1, 0.08f));
        rt->FillRoundedRectangle(D2D1::RoundedRect(bar, bh / 2, bh / 2), b_.Get());
        const wchar_t* tabs[4] = {L"Hat", L"Face", L"Body", L"Clothes"};
        float tw = (bar.right - bar.left) / 4;
        for (int i = 0; i < 4; i++) {
            D2D1_RECT_F r = D2D1::RectF(bar.left + i * tw, bar.top, bar.left + (i + 1) * tw, bar.bottom);
            if (i == tab_) {
                b_->SetColor(D2D1::ColorF(1, 1, 1, 0.24f));
                D2D1_RECT_F rr = D2D1::RectF(r.left + 2 * s, r.top + 2 * s, r.right - 2 * s, r.bottom - 2 * s);
                rt->FillRoundedRectangle(D2D1::RoundedRect(rr, (rr.bottom - rr.top) / 2, (rr.bottom - rr.top) / 2), b_.Get());
            }
            b_->SetColor(D2D1::ColorF(1, 1, 1, i == tab_ ? 1.f : 0.7f));
            rt->DrawText(tabs[i], (UINT32)wcslen(tabs[i]), tabFmt_.Get(), r, b_.Get());
        }
        // tiles
        Outfit o = target_.get ? target_.get() : Outfit();
        int sel = tab_ == 0 ? o.hat : (tab_ == 1 ? o.face : (tab_ == 2 ? o.body : o.clothes));
        const wchar_t* const* titles = tab_ == 0 ? kHatTitles : (tab_ == 1 ? kFaceTitles : (tab_ == 2 ? kBodyTitles : kClothesTitles));
        for (int i = 0; i < 8; i++) {
            D2D1_RECT_F r = TileRect(i);
            D2D1_RECT_F in = D2D1::RectF(r.left + 1, r.top + 1, r.right - 1, r.bottom - 1);
            D2D1_ROUNDED_RECT rr = D2D1::RoundedRect(in, 10 * s, 10 * s);
            b_->SetColor(D2D1::ColorF(1, 1, 1, i == sel ? 0.18f : 0.07f));
            rt->FillRoundedRectangle(rr, b_.Get());
            if (i == sel) { b_->SetColor(D2D1::ColorF(0.55f, 0.82f, 1, 1)); rt->DrawRoundedRectangle(rr, b_.Get(), 2 * s); }
            else { b_->SetColor(D2D1::ColorF(1, 1, 1, 0.12f)); rt->DrawRoundedRectangle(rr, b_.Get(), 1); }
            DrawOutfitPreview(rt, tab_, i, D2D1::RectF(r.left + 6 * s, r.top + 5 * s, r.right - 6 * s, r.bottom - 20 * s));
            b_->SetColor(D2D1::ColorF(1, 1, 1, 0.9f));
            rt->DrawText(titles[i], (UINT32)wcslen(titles[i]), tileFmt_.Get(), D2D1::RectF(r.left + 2, r.bottom - 18 * s, r.right - 2, r.bottom - 3 * s), b_.Get());
        }
        b_->SetColor(D2D1::ColorF(1, 1, 1, 0.2f));
        rt->DrawRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(0.5f, 0.5f, W - 0.5f, H - 0.5f), 16 * s, 16 * s), b_.Get(), 1);
    }

    LRESULT Message(UINT m, WPARAM w, LPARAM l) override
    {
        switch (m) {
        case WM_LBUTTONUP: Click((float)(short)LOWORD(l), (float)(short)HIWORD(l)); return 0;
        case WM_KEYDOWN:
            if (w == VK_ESCAPE) { Logf(L"TEST customize panel closed by Esc"); Close(); return 0; }
            break;
        case WM_SETCURSOR: SetCursor(LoadCursorW(nullptr, IDC_ARROW)); return TRUE;
        case WM_ACTIVATE:
            // it may take focus only after the user clicks into it; losing it again closes it
            if (LOWORD(w) != WA_INACTIVE) activated_ = true;
            else if (activated_) { Logf(L"TEST customize panel closed (deactivated)"); PostMessageW(hwnd_, WM_APP + 77, 0, 0); }
            return 0;
        case WM_APP + 77: Close(); return 0;
        default: break;
        }
        return Panel::Message(m, w, l);
    }

private:
    bool activated_ = false;
    D2D1_RECT_F IconRect(int i) const
    {
        float W = (float)w_, s = s_;
        float x = i == 0 ? W - 70 * s : W - 40 * s;
        return D2D1::RectF(x, 16 * s, x + 24 * s, 40 * s);
    }
    D2D1_RECT_F TileRect(int i) const
    {
        float W = (float)w_, s = s_;
        float tw = (W - 32 * s - 24 * s) / 4, th = 78 * s;
        int row = i / 4, col = i % 4;
        float x = 16 * s + col * (tw + 8 * s), y = row == 0 ? 84 * s : 170 * s;
        return D2D1::RectF(x, y, x + tw, y + th);
    }
    void Click(float x, float y)
    {
        auto in = [&](D2D1_RECT_F r) { return x >= r.left && x < r.right && y >= r.top && y < r.bottom; };
        if (in(IconRect(1))) { Logf(L"TEST customize panel closed by X"); Close(); return; }
        if (in(IconRect(0))) {
            if (target_.set) target_.set(Outfit());
            Logf(L"TEST outfit reset");
            Redraw();
            return;
        }
        float s = s_;
        D2D1_RECT_F bar = D2D1::RectF(16 * s, 46 * s, (float)w_ - 16 * s, 72 * s);
        if (in(bar)) {
            tab_ = std::max(0, std::min(3, (int)((x - bar.left) / ((bar.right - bar.left) / 4))));
            Redraw();
            return;
        }
        for (int i = 0; i < 8; i++) {
            if (!in(TileRect(i)) || !target_.get || !target_.set) continue;
            Outfit o = target_.get();
            if (tab_ == 0) o.hat = i; else if (tab_ == 1) o.face = i; else if (tab_ == 2) o.body = i; else o.clothes = i;
            target_.set(o);
            Logf(L"TEST outfit set tab=%d option=%d -> %S", tab_, i, o.Key().c_str());
            Redraw();
            return;
        }
    }

    float s_ = 1;
    int tab_ = 0;
    CustomizeTarget target_;
    ComPtr<IDWriteTextFormat> titleFmt_, tabFmt_, tileFmt_, iconFmt_;
    ComPtr<ID2D1SolidColorBrush> b_;
};

std::unique_ptr<Label> g_toast, g_hint;
std::unique_ptr<Coach> g_coach;
std::unique_ptr<Customize> g_custom;

}  // namespace

void PanelsInit(HINSTANCE inst)
{
    g_inst = inst;
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = PanelProc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = kPanelClass;
    RegisterClassExW(&wc);
}

void PanelsShutdown()
{
    g_toast.reset();
    g_hint.reset();
    g_coach.reset();
    g_custom.reset();
}

void ShowToast(const PanelHost& h, const std::wstring& text)
{
    if (text.empty()) return;
    g_toast.reset(new Label());
    g_toast->Open(h, text, 15, 24);
    g_toast->StartFade(1200);
    Logf(L"TEST toast: %s", text.c_str());
}

HWND ToastHwnd() { return g_toast ? g_toast->Hwnd() : nullptr; }

void ShowHint(const PanelHost& h, const std::wstring& text)
{
    g_hint.reset(new Label());
    g_hint->Open(h, text, 13, 70);
}

void HideHint() { g_hint.reset(); }

void ShowCoach(const PanelHost& h, const std::function<void()>& onDismiss)
{
    g_coach.reset(new Coach());
    g_coach->Open(h, onDismiss);
}

void HideCoach() { if (g_coach) { g_coach->Destroy(); g_coach.reset(); } }
bool CoachVisible() { return g_coach && g_coach->Visible(); }
void CoachCursor(POINT p) { if (g_coach) g_coach->Cursor(p); }

void ShowCustomize(const PanelHost& h, const RECT& anchorScreen, const CustomizeTarget& t)
{
    if (!g_custom) g_custom.reset(new Customize());
    g_custom->Open(h, anchorScreen, t);
}

void HideCustomize() { if (g_custom) g_custom->Close(); }
bool CustomizeVisible() { return g_custom && g_custom->Visible(); }
void ValidateCustomize() { if (g_custom) g_custom->Validate(); }
HWND CustomizeHwnd() { return g_custom && g_custom->Visible() ? g_custom->Hwnd() : nullptr; }
