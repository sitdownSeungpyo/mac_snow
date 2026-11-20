// Christmas lights (mac StringLights + Light Edit mode): user strands between windows, automatic
// strands between nearby windows, garlands along window tops; gold anchor dots for linking.
#include "winterdesk.h"

using D2D1::Matrix3x2F;
using D2D1::Point2F;

namespace {
const int kMaxBulbs = 150;
const int kMaxStrands = 40;
const float kAnchorHitPt = 12, kSnapPt = 40, kStrandHitPt = 6;

D2D1_POINT_2F Bez(D2D1_POINT_2F p0, D2D1_POINT_2F c, D2D1_POINT_2F p1, float t)
{
    float u = 1 - t;
    return Point2F(u * u * p0.x + 2 * u * t * c.x + t * t * p1.x, u * u * p0.y + 2 * u * t * c.y + t * t * p1.y);
}

float SegDist(D2D1_POINT_2F p, D2D1_POINT_2F a, D2D1_POINT_2F b)
{
    float dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy;
    float t = len2 > 0 ? Clampf(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0, 1) : 0;
    return std::hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy));
}
}  // namespace

D2D1_POINT_2F Scene::AnchorPoint(const WinCap& c, float fx) const
{
    float w = (float)(c.rect.right - c.rect.left);
    return Point2F(c.rect.left + 3 * S + fx * (w - 6 * S), c.rect.top + 1 * S);
}

bool Scene::AnchorVisible(const LightAnchor& a) const
{
    const WinCap* c = windows_.Find(a.window);
    if (!c || c->unsettled) return false;
    D2D1_POINT_2F p = AnchorPoint(*c, AnchorFx(a.kind));
    if (p.x < 0 || p.x > W || p.y < 0 || p.y > H) return false;
    return !windows_.Covered(*c, p.x, p.y + 2 * S);
}

std::vector<std::pair<LightAnchor, D2D1_POINT_2F>> Scene::VisibleAnchors() const
{
    std::vector<std::pair<LightAnchor, D2D1_POINT_2F>> out;
    for (const WinCap* c : windows_.caps)
        for (int k = 0; k < 3; k++) {
            LightAnchor a{c->hwnd, k};
            if (AnchorVisible(a)) out.push_back({a, AnchorPoint(*c, AnchorFx(k))});
        }
    return out;
}

int Scene::EligibleAnchorWindows() const
{
    std::vector<HWND> ws;
    for (auto& a : VisibleAnchors())
        if (std::find(ws.begin(), ws.end(), a.first.window) == ws.end()) ws.push_back(a.first.window);
    return (int)ws.size();
}

bool Scene::AnchorHit(float x, float y, LightAnchor* out, D2D1_POINT_2F* pt) const
{
    float best = kAnchorHitPt * S;
    bool found = false;
    for (auto& a : VisibleAnchors()) {
        float d = std::hypot(x - a.second.x, y - a.second.y);
        if (d <= best) { best = d; *out = a.first; *pt = a.second; found = true; }
    }
    return found;
}

const Strand* Scene::UserStrandNear(float x, float y, float tol) const
{
    const Strand* best = nullptr;
    float bd = tol;
    D2D1_POINT_2F p = Point2F(x, y);
    for (const Strand& s : strands_) {
        if (!s.user) continue;
        float d = 1e9f;
        for (size_t k = 0; k < s.bulbPts.size(); k++)
            if (!s.bulbHidden[k]) d = std::min(d, std::hypot(x - s.bulbPts[k].x, y - (s.bulbPts[k].y + 6 * S)) - 4 * S);
        for (const auto& w : s.wire) d = std::min(d, SegDist(p, w.first, w.second));
        if (d <= bd) { bd = d; best = &s; }
    }
    return best;
}

LinkResult Scene::ValidateLink(const UserLink& l, bool requireVisible) const
{
    if (l.a.window == l.b.window) return LinkSameWindow;
    if (!windows_.Find(l.a.window) || !windows_.Find(l.b.window)) return LinkInvalid;
    for (const UserLink& o : userLinks_) if (o.Same(l)) return LinkDuplicate;
    if ((int)userLinks_.size() >= kMaxLinks) return LinkFull;
    if (requireVisible && (!AnchorVisible(l.a) || !AnchorVisible(l.b))) return LinkCovered;
    return LinkAdded;
}

LinkResult Scene::AddUserLink(const UserLink& l, bool requireVisible)
{
    LinkResult r = ValidateLink(l, requireVisible);
    if (r != LinkAdded) return r;
    userLinks_.push_back(l);
    strandSig_.clear();
    if (onLinksChanged) onLinksChanged();
    return r;
}

void Scene::RemoveUserLink(const UserLink& l)
{
    size_t before = userLinks_.size();
    userLinks_.erase(std::remove_if(userLinks_.begin(), userLinks_.end(), [&](const UserLink& o) { return o.Same(l); }), userLinks_.end());
    if (userLinks_.size() == before) return;
    strandSig_.clear();
    if (onLinksChanged) onLinksChanged();
    Logf(L"TEST light link deleted (%d left)", (int)userLinks_.size());
}

std::vector<SavedLink> Scene::SnapshotLinks() const
{
    std::vector<SavedLink> out;
    for (const UserLink& l : userLinks_) {
        const WinCap* a = windows_.Find(l.a.window);
        const WinCap* b = windows_.Find(l.b.window);
        if (!a || !b || a->owner.empty() || b->owner.empty()) continue;
        out.push_back({a->owner, b->owner, a->ownerIndex, b->ownerIndex, l.a.kind, l.b.kind});
    }
    return out;
}

std::vector<SavedLink> Scene::RestoreLinks(const std::vector<SavedLink>& saved)
{
    std::vector<SavedLink> rest;
    auto find = [this](const std::wstring& owner, int index) -> HWND {
        HWND h = nullptr;
        int n = 0;
        for (WinCap* c : windows_.caps) if (c->owner == owner && c->ownerIndex == index) { h = c->hwnd; n++; }
        return n == 1 ? h : nullptr;
    };
    for (const SavedLink& s : saved) {
        HWND a = find(s.aOwner, s.aIndex), b = find(s.bOwner, s.bIndex);
        if (!a || !b || a == b) { rest.push_back(s); continue; }
        UserLink l{{a, s.aKind}, {b, s.bKind}};
        if (ValidateLink(l, false) == LinkAdded) { userLinks_.push_back(l); strandSig_.clear(); }
    }
    return rest;
}

/// Rebuilds the strand list when the set of windows / links / options changes (StringLights.sync).
void Scene::SyncStrands()
{
    std::vector<WinCap*> ws;
    for (WinCap* c : windows_.caps) if (!c->unsettled) ws.push_back(c);
    std::string sig = std::to_string(settings_.lightStyle) + (settings_.lightLinksAuto ? "A" : "a") + (settings_.windowGarlands ? "G" : "g") + "|";
    for (WinCap* c : ws) {
        char b[96];
        sprintf_s(b, "%p:%ld,%ld,%ld,%d;", (void*)c->hwnd, c->rect.left, c->rect.top, c->rect.right, c->zAll);
        sig += b;
    }
    for (const UserLink& l : userLinks_) { char b[64]; sprintf_s(b, "u%p.%d-%p.%d;", (void*)l.a.window, l.a.kind, (void*)l.b.window, l.b.kind); sig += b; }
    if (sig == strandSig_) return;
    strandSig_ = sig;
    std::vector<Strand> old;
    old.swap(strands_);
    int budget = kMaxBulbs, index = 0;
    auto add = [&](HWND wa, float fa, HWND wb, float fb, float sagPt, int depth, int count, bool user, const UserLink& link) {
        Strand s{};
        s.wa = wa; s.fa = fa; s.wb = wb; s.fb = fb; s.sagPt = sagPt; s.depth = depth; s.count = count; s.user = user; s.link = link;
        s.index = index++;
        s.fade = 1;
        for (const Strand& o : old)        // a strand that already existed keeps its fade state
            if (o.wa == wa && o.wb == wb && o.fa == fa && o.fb == fb) s.fade = o.fade;
        if (old.empty() == false && s.fade == 1) {
            bool existed = false;
            for (const Strand& o : old) if (o.wa == wa && o.wb == wb && o.fa == fa && o.fb == fb) existed = true;
            if (!existed) s.fade = 0;      // new strands fade in (0.5 s)
        }
        strands_.push_back(s);
    };
    // 1) user links
    for (const UserLink& l : userLinks_) {
        const WinCap* a = windows_.Find(l.a.window);
        const WinCap* b = windows_.Find(l.b.window);
        if (!a || !b || a->unsettled || b->unsettled) continue;
        D2D1_POINT_2F p0 = AnchorPoint(*a, AnchorFx(l.a.kind)), p1 = AnchorPoint(*b, AnchorFx(l.b.kind));
        float chord = std::hypot(p1.x - p0.x, p1.y - p0.y) / S;
        int count = std::min(30, std::max(3, (int)(chord / 30)));
        if (count > budget) continue;
        budget -= count;
        add(a->hwnd, AnchorFx(l.a.kind), b->hwnd, AnchorFx(l.b.kind), std::min(90.f, 18 + chord * 0.12f), std::min(a->zAll, b->zAll), count, true, l);
    }
    // 2) automatic strands: A's top-right corner to B's top-left corner of a nearby window
    if (settings_.lightLinksAuto) {
        struct Cand { WinCap* a; WinCap* b; float score; };
        std::vector<Cand> cands;
        for (WinCap* a : ws)
            for (WinCap* b : ws) {
                if (a == b) continue;
                float gap = (b->rect.left - a->rect.right) / S, dy = std::fabs((float)(a->rect.top - b->rect.top)) / S;
                if (gap >= 0 && gap <= 600 && dy < 300) cands.push_back({a, b, gap + dy});
            }
        std::sort(cands.begin(), cands.end(), [](const Cand& x, const Cand& y) { return x.score < y.score; });
        std::vector<HWND> usedRight, usedLeft;
        size_t autoLimit = strands_.size() + 6;
        for (size_t i = 0; i < cands.size() && i < 200 && strands_.size() < autoLimit; i++) {
            WinCap* a = cands[i].a;
            WinCap* b = cands[i].b;
            if (std::find(usedRight.begin(), usedRight.end(), a->hwnd) != usedRight.end()) continue;
            if (std::find(usedLeft.begin(), usedLeft.end(), b->hwnd) != usedLeft.end()) continue;
            D2D1_POINT_2F p0 = AnchorPoint(*a, 1), p1 = AnchorPoint(*b, 0);
            if (windows_.Covered(*a, p0.x, p0.y) && windows_.Covered(*b, p1.x, p1.y)) continue;
            float chord = std::hypot(p1.x - p0.x, p1.y - p0.y) / S;
            int count = std::max(3, (int)(chord / 30));
            if (count > budget) continue;
            budget -= count;
            usedRight.push_back(a->hwnd);
            usedLeft.push_back(b->hwnd);
            add(a->hwnd, 1, b->hwnd, 0, 18 + chord * 0.12f, std::min(a->zAll, b->zAll), count, false, UserLink{});
        }
    }
    // 3) garlands along each window's top: 2 (narrow) or 3 scallops; one bulb per ~40 pt
    //    (the mac uses 30 pt; spread out further at the user's request)
    if (settings_.windowGarlands) {
        for (WinCap* c : ws) {
            if ((int)strands_.size() >= kMaxStrands) break;
            float width = (float)(c->rect.right - c->rect.left);
            int hidden = 0;
            for (int i = 0; i < 12; i++) if (!c->VisibleAt(c->rect.left + (i + 0.5f) / 12 * width)) hidden++;
            if (hidden > 12 * 0.7f) continue;
            int scallops = width / S < 520 ? 2 : 3;
            float chord = (width - 6 * S) / scallops / S;
            int per = std::max(2, (int)(chord / 40));
            if (per * scallops > budget) continue;
            budget -= per * scallops;
            for (int k = 0; k < scallops; k++)
                add(c->hwnd, (float)k / scallops, c->hwnd, (float)(k + 1) / scallops, 10 + chord * 0.05f, c->zAll, per, false, UserLink{});
        }
    }
    for (Strand& s : strands_) BuildStrandGeometry(s);
    wiresKey_.clear();
}

/// Bulb points, hidden flags and visible wire pieces at the anchors' current positions.
void Scene::BuildStrandGeometry(Strand& s)
{
    s.bulbPts.clear();
    s.bulbHidden.clear();
    s.wire.clear();
    const WinCap* a = windows_.Find(s.wa);
    const WinCap* b = windows_.Find(s.wb);
    if (!a || !b) return;
    s.p0 = AnchorPoint(*a, s.fa);
    s.p1 = AnchorPoint(*b, s.fb);
    D2D1_POINT_2F mid = Point2F((s.p0.x + s.p1.x) / 2, (s.p0.y + s.p1.y) / 2);
    D2D1_POINT_2F c = Point2F(mid.x, mid.y + 2 * s.sagPt * S);
    auto hidden = [&](float x, float y) {
        if (x < 0 || x >= W) return true;
        for (int z = 0; z < s.depth && z < (int)windows_.allRects.size(); z++) {
            if (windows_.allHwnds[z] == s.wa || windows_.allHwnds[z] == s.wb) continue;
            const RECT& o = windows_.allRects[z];
            if (x >= o.left && x < o.right && y >= o.top && y < o.bottom) return true;
        }
        return false;
    };
    std::vector<float> joints = {0};
    for (int k = 0; k < s.count; k++) {
        float t = (k + 0.5f) / s.count;
        D2D1_POINT_2F p = Bez(s.p0, c, s.p1, t);
        s.bulbPts.push_back(Point2F(p.x, p.y - S));
        s.bulbHidden.push_back(hidden(p.x, p.y + 6 * S));
        joints.push_back(t);
    }
    joints.push_back(1);
    for (size_t j = 0; j + 1 < joints.size(); j++)
        for (int q = 0; q < 3; q++) {
            float t0 = joints[j] + (joints[j + 1] - joints[j]) * q / 3, t1 = joints[j] + (joints[j + 1] - joints[j]) * (q + 1) / 3;
            D2D1_POINT_2F e0 = Bez(s.p0, c, s.p1, t0), e1 = Bez(s.p0, c, s.p1, t1);
            if (!hidden((e0.x + e1.x) / 2, (e0.y + e1.y) / 2)) s.wire.push_back({e0, e1});
        }
}

void Scene::DrawLights(Renderer& r)
{
    ID2D1DeviceContext1* dc = r.dc.Get();
    static double lastT = 0;
    float dt = (float)Clampf((float)(time_ - lastT), 0, 0.2f);
    lastT = time_;
    SyncStrands();
    // a strand on a window that is moving without live tracking drops (fades out 0.3 s) and comes
    // back (fades in 0.5 s) once the window rests; live-tracked strands follow every frame
    std::string key;
    for (Strand& s : strands_) {
        const WinCap* a = windows_.Find(s.wa);
        const WinCap* b = windows_.Find(s.wb);
        bool suppressed = !a || !b || a->unsettled || b->unsettled;
        s.fade = suppressed ? std::max(0.f, s.fade - dt / 0.3f) : std::min(1.f, s.fade + dt / 0.5f);
        bool live = (a && a->live) || (b && b->live);
        if (live || (a && b && (std::fabs(AnchorPoint(*a, s.fa).x - s.p0.x) > 0.5f || std::fabs(AnchorPoint(*a, s.fa).y - s.p0.y) > 0.5f ||
                                 std::fabs(AnchorPoint(*b, s.fb).x - s.p1.x) > 0.5f || std::fabs(AnchorPoint(*b, s.fb).y - s.p1.y) > 0.5f)))
            BuildStrandGeometry(s);
        if (!live && s.fade >= 1) {
            char k[64];
            sprintf_s(k, "%d:%.0f,%.0f,%.0f,%.0f,%d;", s.index, s.p0.x, s.p0.y, s.p1.x, s.p1.y, windows_.layoutVersion);
            key += k;
        }
    }
    if (key != wiresKey_) {
        wiresKey_ = key;
        wires_.Reset();
        ComPtr<ID2D1PathGeometry> path = r.NewPath();
        ComPtr<ID2D1GeometrySink> sink;
        path->Open(&sink);
        bool any = false;
        for (const Strand& s : strands_) {
            const WinCap* a = windows_.Find(s.wa);
            const WinCap* b = windows_.Find(s.wb);
            if ((a && a->live) || (b && b->live) || s.fade < 1) continue;
            for (const auto& w : s.wire) {
                sink->BeginFigure(w.first, D2D1_FIGURE_BEGIN_HOLLOW);
                sink->AddLine(w.second);
                sink->EndFigure(D2D1_FIGURE_END_OPEN);
                any = true;
            }
        }
        sink->Close();
        if (any) dc->CreateStrokedGeometryRealization(path.Get(), D2D1_DEFAULT_FLATTENING_TOLERANCE, std::max(1.f, 1.3f * S), r.roundStroke.Get(), &wires_);
    }
    ID2D1SolidColorBrush* wire = r.Solid(Rgb(0.06f, 0.16f, 0.08f, 0.95f));
    if (wires_) dc->DrawGeometryRealization(wires_.Get(), wire);
    for (const Strand& s : strands_) {             // moving / fading strands: drawn directly
        const WinCap* a = windows_.Find(s.wa);
        const WinCap* b = windows_.Find(s.wb);
        bool live = (a && a->live) || (b && b->live);
        if (!live && s.fade >= 1) continue;
        if (s.fade <= 0) continue;
        ID2D1SolidColorBrush* w = r.Solid(Rgb(0.06f, 0.16f, 0.08f, 0.95f * s.fade));
        for (const auto& p : s.wire) dc->DrawLine(p.first, p.second, w, std::max(1.f, 1.3f * S), r.roundStroke.Get());
    }
    bulbList_.Clear();
    float t = (float)time_;
    for (const Strand& s : strands_) {
        if (s.fade <= 0.05f) continue;
        bool round = s.index % 3 == 1;
        for (size_t k = 0; k < s.bulbPts.size(); k++) {
            if (s.bulbHidden[k]) continue;
            float ph = (float)((k * 2.39996 + s.index * 1.7) - std::floor(k * 2.39996 / 6.2832) * 6.2832);
            bool lantern = s.count >= 5 && k % 7 == 3;
            float alpha;
            if (lantern) alpha = 0.55f + 0.15f * std::sin(t * 9 + ph) + 0.1f * std::sin(t * 23 + ph * 2);
            else alpha = (0.72f + 0.18f * std::sin(t * 1.3f + ph)) * (0.8f + 0.2f * std::sin(t * 2.2f - k * 0.7f));
            int lvl = alpha > 0.74f ? 2 : (alpha > 0.58f ? 1 : 0);
            if (s.fade < 0.5f) lvl = 0;
            const AtlasSprite& sp = lantern ? r.lanterns[lvl]
                                            : r.bulbs[settings_.lightStyle == 1 ? 5 : (int)((k + s.index) % 5)][round ? 1 : 0][lvl];
            bulbList_.Add(sp, s.bulbPts[k].x, s.bulbPts[k].y);
        }
    }
    bulbList_.Draw(r);
}

// ---------------------------------------------------------------------------------------------
// Light Edit mode
// ---------------------------------------------------------------------------------------------

void Scene::SetLightEdit(bool on)
{
    if (on == lightEdit_) return;
    lightEdit_ = on;
    linkDrag_ = false;
    snapping_ = false;
    lastEditTouch_ = time_;
    needsRedraw = true;
}

void Scene::DrawLightEdit(Renderer& r)
{
    ID2D1DeviceContext1* dc = r.dc.Get();
    dc->SetTransform(Matrix3x2F::Identity());
    // live preview: a sagging wire with a few bulbs from the source anchor to the cursor
    if (linkDrag_) {
        const WinCap* c = windows_.Find(linkSrc_.window);
        if (c) {
            D2D1_POINT_2F p0 = AnchorPoint(*c, AnchorFx(linkSrc_.kind)), p1 = previewEnd_;
            float chord = std::hypot(p1.x - p0.x, p1.y - p0.y) / S;
            D2D1_POINT_2F mid = Point2F((p0.x + p1.x) / 2, (p0.y + p1.y) / 2);
            D2D1_POINT_2F cc = Point2F(mid.x, mid.y + 2 * std::min(90.f, 18 + chord * 0.12f) * S);
            D2D1_POINT_2F prev = p0;
            ID2D1SolidColorBrush* w = r.Solid(Rgb(0.06f, 0.16f, 0.08f, 0.95f));
            for (int i = 1; i <= 24; i++) {
                D2D1_POINT_2F q = Bez(p0, cc, p1, i / 24.f);
                dc->DrawLine(prev, q, w, 1.3f * S, r.roundStroke.Get());
                prev = q;
            }
            int count = std::min(30, std::max(3, (int)(chord / 30)));
            dotList_.Clear();
            for (int k = 0; k < count; k++) {
                D2D1_POINT_2F q = Bez(p0, cc, p1, (k + 0.5f) / count);
                dotList_.Add(r.bulbs[k % 5][0][1], q.x, q.y - S);
            }
            dotList_.Draw(r);
        }
    }
    // gold anchor dots with a gentle pulse (the source dot is bigger)
    float pulse = 1 + 0.22f * (float)std::sin(time_ * 5);
    for (auto& a : VisibleAnchors()) {
        float ga = 0.75f + 0.25f * pulse - 0.25f;
        float gs = pulse;
        const AtlasSprite& g = r.goldGlow;
        D2D1_RECT_F dst = D2D1::RectF(a.second.x - g.ox * gs, a.second.y - g.oy * gs, a.second.x + (g.w - g.ox) * gs, a.second.y + (g.h - g.oy) * gs);
        dc->DrawBitmap(r.atlas.Get(), dst, ga, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR,
                       D2D1::RectF((float)g.src.left, (float)g.src.top, (float)g.src.right, (float)g.src.bottom));
    }
    dotList_.Clear();
    for (auto& a : VisibleAnchors()) dotList_.Add(r.goldDot, a.second.x, a.second.y, linkDrag_ && a.first == linkSrc_ ? 1.3f : 1.f);
    if (linkDrag_ && snapping_) dotList_.Add(snapValid_ ? r.goldDotBig : r.redDot, snapPt_.x, snapPt_.y);
    dotList_.Draw(r);
}

bool Scene::EditMouseDown(float x, float y)
{
    lastEditTouch_ = time_;
    LightAnchor a;
    D2D1_POINT_2F p;
    if (AnchorHit(x, y, &a, &p)) {
        linkDrag_ = true;
        linkSrc_ = a;
        previewEnd_ = Point2F(x, y);
        snapping_ = false;
        needsRedraw = true;
        return true;
    }
    if (const Strand* s = UserStrandNear(x, y, kStrandHitPt * S)) {
        UserLink l = s->link;
        RemoveUserLink(l);
        return true;
    }
    return false;
}

void Scene::EditMouseMove(float x, float y)
{
    lastEditTouch_ = time_;
    D2D1_POINT_2F cur = Point2F(Clampf(x, 0, (float)W), Clampf(y, 0, (float)H));
    snapping_ = false;
    float best = kSnapPt * S;
    for (auto& a : VisibleAnchors()) {
        if (a.first == linkSrc_) continue;
        float d = std::hypot(cur.x - a.second.x, cur.y - a.second.y);
        if (d <= best) {
            best = d;
            snapping_ = true;
            snapPt_ = a.second;
            snapValid_ = ValidateLink(UserLink{linkSrc_, a.first}, true) == LinkAdded;
        }
    }
    previewEnd_ = snapping_ && snapValid_ ? snapPt_ : cur;      // valid targets pull the wire onto the dot
    needsRedraw = true;
}

void Scene::EditMouseUp(float x, float y)
{
    lastEditTouch_ = time_;
    LightAnchor src = linkSrc_;
    linkDrag_ = false;
    needsRedraw = true;
    LightAnchor target{};
    bool found = false;
    float best = kSnapPt * S;
    for (auto& a : VisibleAnchors()) {
        if (a.first == src) continue;
        float d = std::hypot(x - a.second.x, y - a.second.y);
        if (d <= best) { best = d; target = a.first; found = true; }
    }
    snapping_ = false;
    if (!found) return;
    LinkResult r = AddUserLink(UserLink{src, target}, true);
    static const wchar_t* msgs[] = {L"", L"\U0001F4A1 전구 연결됨",
                                    L"같은 창끼리는 연결할 수 없어요",
                                    L"이미 연결된 전구예요",
                                    L"가려진 지점에는 연결할 수 없어요",
                                    L"전구 줄은 최대 20개까지예요",
                                    L"연결할 수 없어요"};
    Logf(L"TEST light link result %d (%d links)", (int)r, (int)userLinks_.size());
    Toast(msgs[r]);
}
