/// Chapter 10: a widget of its own, a star rating, as a retained node and an island function.
module guide.rating;

import dentrite.containers;
import dentrite.immediate;
import dentrite.node;
import dentrite.signals : Signal, effect;
import std.algorithm.comparison : clamp;
import std.math : PI, cos, floor, isNaN, sin;

/// Look of a rating, theme section `[rating]`.
struct RatingStyle
{
    enum section = "rating"; /// theme section

    Color on = Color(0xf2, 0xb9, 0x50, 0xff);    /// stars up to the value
    Color off = Color(0x43, 0x43, 0x4c, 0xff);   /// the rest
    Color hover = Color(0xf7, 0xd3, 0x8c, 0xff); /// stars up to the one under the pointer
    Color focus = Color(0x3b, 0x82, 0xf6, 0xff); /// focus ring
    float star = 16; /// star width and height
    float gap = 4;   /// between stars
}

/// Size of `stars` stars.
Size measureRating(const ref RatingStyle s, int stars)
{
    return Size(stars * s.star + (stars - 1) * s.gap, s.star);
}

/// Star under `x`, relative to the left edge, from 1, or 0 left of the first.
int starAt(const ref RatingStyle s, float x, int stars)
{
    if (x < 0)
    {
        return 0;
    }
    return clamp(cast(int) floor(x / (s.star + s.gap)) + 1, 1, stars);
}

/// Paints `stars` stars in `r`, filled up to `value`, or up to `hot` in the hover color when it is not 0, with a
/// focus ring when `ring`. Shared by the node and the island function.
void paintRating(ref PaintContext ctx, Rect r, const ref RatingStyle s, int stars, int value, int hot, bool ring)
{
    foreach (int i; 0 .. stars)
    {
        Rect box = Rect(r.x + i * (s.star + s.gap), r.y, s.star, s.star);
        Color c = hot > 0 ? (i < hot ? s.hover : s.off) : (i < value ? s.on : s.off);
        ctx.list.polygon(starPoints(box), c);
    }
    if (ring)
    {
        ctx.list.rect(r.inset(-3), Color.init, 4, s.focus, 1);
    }
}

/// Five pointed star filling `box`.
Point[] starPoints(Rect box)
{
    Point[] pts;
    float cx = box.x + box.w / 2;
    float cy = box.y + box.h / 2 + box.h * 0.05f;
    foreach (int i; 0 .. 10)
    {
        float radius = (i % 2 == 0 ? 0.5f : 0.2f) * box.w;
        double a = -PI / 2 + i * PI / 5;
        pts ~= Point(cx + cast(float)(radius * cos(a)), cy + cast(float)(radius * sin(a)));
    }
    return pts;
}

/// Retained rating bound to a signal: click a star, or use the arrow keys while focused.
final class Rating : Node
{
    Signal!int value; /// stars given, 0 for none
    int stars;        /// stars shown
    private int shown; /// value last read
    private int hot;   /// star under the pointer, 0 for none

    /// Creates a rating over `value`. The binding effect belongs to the current owner.
    this(Signal!int value, int stars)
    {
        this.value = value;
        this.stars = stars;
        interactive = true;
        focusable = true;
        cursor = CursorShape.pointer;
        effect(() {
            int v = value.get;
            if (v != shown)
            {
                shown = v;
                markNeedsPaint();
            }
        });
    }

    /// Sets the value, kept in range.
    private void choose(int v)
    {
        value.set(clamp(v, 0, stars));
    }

    /// As wide as its stars.
    protected override Size performLayout(Constraints c)
    {
        RatingStyle s = tree.style!RatingStyle();
        return c.constrain(measureRating(s, stars));
    }

    /// Stars for the current state.
    override void paint(ref PaintContext ctx, Point origin)
    {
        RatingStyle s = ctx.style!RatingStyle();
        paintRating(ctx, Rect(origin.x, origin.y, size.w, size.h), s, stars, shown, hot, focusRing);
    }

    /// Hover shows the stars a click would give, a press gives them.
    override bool onPointer(ref const PointerEvent e)
    {
        RatingStyle s = tree.style!RatingStyle();
        int at = starAt(s, e.pos.x - bounds.x, stars);
        switch (e.kind)
        {
        case PointerKind.enter:
        case PointerKind.move:
            if (at != hot)
            {
                hot = at;
                markNeedsPaint();
            }
            return true;
        case PointerKind.leave:
            hot = 0;
            markNeedsPaint();
            return true;
        case PointerKind.down:
            if (e.button != 1)
            {
                return false;
            }
            choose(at == shown ? 0 : at);
            return true;
        default:
            return false;
        }
    }

    /// Left and Right step, Home clears, End gives every star.
    override bool onKey(ref const KeyEvent e)
    {
        switch (e.key)
        {
        case Key.left:
            choose(shown - 1);
            return true;
        case Key.right:
            choose(shown + 1);
            return true;
        case Key.home:
            choose(0);
            return true;
        case Key.end:
            choose(stars);
            return true;
        default:
            return false;
        }
    }

    /// Focus ring changes.
    override void onFocus(bool gained)
    {
        markNeedsPaint();
    }

    /// A slider from 0 to the star count, for screen readers.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.slider;
        a.number = shown;
        a.min = 0;
        a.max = stars;
        a.step = 1;
        a.allow(AccessAction.increment);
        a.allow(AccessAction.decrement);
        a.allow(AccessAction.setValue);
    }

    /// Steps or sets the value for a screen reader.
    override bool accessAction(ref const AccessRequest r)
    {
        switch (r.action)
        {
        case AccessAction.increment:
            choose(shown + 1);
            return true;
        case AccessAction.decrement:
            choose(shown - 1);
            return true;
        case AccessAction.setValue:
            if (isNaN(r.number))
            {
                return false;
            }
            choose(cast(int) r.number);
            return true;
        default:
            return false;
        }
    }
}

/// Retained rating: `rating(stars, accessName: "Rating")`.
Rating rating(Signal!int value, int stars = 5, string accessName = null, string tooltip = null)
{
    Rating r = new Rating(value, stars);
    r.accessName = accessName;
    r.setTooltip(tooltip);
    return r;
}

/// Paint-only rating declared by an island pass.
final class RatingBox : Node
{
    RatingStyle style; /// resolved look
    int stars;         /// stars shown
    int value;         /// filled stars
    int hot;           /// star under the pointer, 0 for none
    bool ring;         /// focused by keyboard

    /// Same size as the retained rating.
    protected override Size performLayout(Constraints c)
    {
        return c.constrain(measureRating(style, stars));
    }

    /// Same look as the retained rating.
    override void paint(ref PaintContext ctx, Point origin)
    {
        paintRating(ctx, Rect(origin.x, origin.y, size.w, size.h), style, stars, value, hot, ring);
    }
}

/// Island rating, true on the pass `value` changed by a click or a key.
bool rating(Ui ui, ref int value, int stars = 5, string file = __FILE__, size_t line = __LINE__)
{
    Id i = ui.id(file, line);
    Press p = ui.clickable(i);
    RatingStyle s = ui.style!RatingStyle(null);
    Rect last = ui.lastRect(i);
    int at = p.hovered ? starAt(s, ui.mouse.x - last.x, stars) : 0;
    int before = value;
    if (p.pressedNow)
    {
        value = at == value ? 0 : at;
    }
    if (ui.focusStop(i))
    {
        value = clamp(value + ui.takeKey(Key.right) - ui.takeKey(Key.left), 0, stars);
    }
    RatingBox b = new RatingBox;
    b.style = s;
    b.stars = stars;
    b.value = value;
    b.hot = at;
    b.ring = ui.focusRing(i);
    ui.put(b);
    ui.track(b, i);
    if (value != before)
    {
        ui.again = true;
    }
    return value != before;
}

/// Clicks and keys set the retained rating, and both kinds have the same size.
unittest
{
    import dentrite.host : Host;
    import dentrite.island : island;
    import dentrite.signals : Scope, effectScope, signal;
    import guide.harness;

    Host h = testHost(300, 200);
    scope (exit)
    {
        h.close();
    }
    Signal!int stars = signal(2);
    int islandStars = 1;
    Rating r;
    scope Scope root = effectScope(() {
        r = rating(stars, accessName: "Rating");
        h.setRoot(column(gap: 10, cross: CrossAlign.start)(r, expanded(island((Ui ui) {
            ui.column(cross: CrossAlign.start)({ ui.rating(islandStars); });
        }))));
    });
    h.frame();
    Rect b = h.find(Role.slider, "Rating").bounds;
    assert(b.w == 5 * 16 + 4 * 4);
    Point fourth = Point(b.x + 3 * 20 + 8, b.y + 8);
    h.inject(PointerKind.move, fourth);
    h.inject(PointerKind.down, fourth);
    h.inject(PointerKind.up, fourth);
    h.frame();
    assert(stars.peek == 4);
    h.setFocus(r);
    h.injectKey(Key.left);
    h.injectKey(Key.left);
    assert(stars.peek == 2);
    h.injectKey(Key.end);
    assert(stars.peek == 5);

    Point second = Point(b.x + 20 + 8, b.y + 26 + 8);
    h.inject(PointerKind.move, second);
    h.frame();
    h.inject(PointerKind.down, second);
    h.inject(PointerKind.up, second);
    h.frame();
    assert(islandStars == 2);
}
