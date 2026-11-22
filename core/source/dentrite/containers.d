/// Layout containers: rows, columns, padding, panels, fixed sizes and a vertical scroll view.
///
/// Builders take options by name in one call and children in a second call:
/// `row(gap: 4)(a, b)`. One call would bind a positional child after a named
/// option to the next parameter.
module dentrite.containers;

import dentrite.draw;
import dentrite.node;
import std.algorithm.comparison : clamp, max, min;
import std.math : isInfinity, round;

/// Main axis of a flex container.
enum Axis
{
    horizontal, /// children left to right, as in a row
    vertical,   /// children top to bottom, as in a column
}

/// Placement of children across the main axis.
enum CrossAlign
{
    start,   /// left or top
    center,  /// centered
    end,     /// right or bottom
    stretch, /// stretched across the full cross extent
}

/// Single child inset by `insets`.
final class Padding : Node
{
    Insets insets; /// space around the child

    /// Wraps `child` with `insets`.
    this(Insets insets, Node child)
    {
        this.insets = insets;
        add(child);
    }

    /// Lays out the child in the deflated space and offsets it.
    protected override Size performLayout(Constraints c)
    {
        Node child = children[0];
        Size s = child.layout(c.deflate(insets));
        child.offset = Point(insets.left, insets.top);
        return Size(s.w + insets.left + insets.right, s.h + insets.top + insets.bottom);
    }
}

/// Flex child that takes a share of the remaining main-axis space.
final class Flexible : Node
{
    int flex = 1;      /// weight of its share of the remaining main-axis space
    bool tight = true; /// true fills the share, false allows smaller

    /// Wraps `child` with a flex weight.
    this(Node child, int flex = 1, bool tight = true)
    {
        this.flex = flex;
        this.tight = tight;
        add(child);
    }

    /// Passes constraints through to the child.
    protected override Size performLayout(Constraints c)
    {
        Node child = children[0];
        child.offset = Point.init;
        return child.layout(c);
    }
}

/// Flexible child that fills its share.
Flexible expanded(Node child, int flex = 1)
{
    return new Flexible(child, flex, true);
}

/// Empty flexible child, pushing its siblings apart.
Flexible spacer(int flex = 1)
{
    return new Flexible(new Fixed(Size.init), flex, true);
}

/// Row or column with gaps and flex children.
class Flex : Node
{
    Axis axis;        /// main axis
    float gap = 0;    /// space between children
    CrossAlign cross; /// placement of children across the main axis

    /// Creates a flex container with `kids`.
    this(Axis axis, float gap, CrossAlign cross, Node[] kids)
    {
        this.axis = axis;
        this.gap = gap;
        this.cross = cross;
        foreach (Node k; kids)
        {
            add(k);
        }
    }

    /// Main-axis extent of `s`.
    private float mainOf(Size s) const
    {
        return axis == Axis.horizontal ? s.w : s.h;
    }

    /// Cross-axis extent of `s`.
    private float crossOf(Size s) const
    {
        return axis == Axis.horizontal ? s.h : s.w;
    }

    /// Child constraints from main and cross ranges.
    private Constraints make(float mainMin, float mainMax, float crossMin, float crossMax) const
    {
        return axis == Axis.horizontal
            ? Constraints(mainMin, mainMax, crossMin, crossMax)
            : Constraints(crossMin, crossMax, mainMin, mainMax);
    }

    /// Inflexible children first, then flex shares of what is left, then positions.
    /// Flex children in an unbounded main axis get their natural size.
    protected override Size performLayout(Constraints c)
    {
        float mainMax = axis == Axis.horizontal ? c.maxW : c.maxH;
        float crossMax = axis == Axis.horizontal ? c.maxH : c.maxW;
        bool stretch = cross == CrossAlign.stretch && isInfinity(crossMax) == false;
        float crossMin = stretch ? crossMax : 0;
        bool bounded = isInfinity(mainMax) == false;

        float used = children.length > 1 ? gap * (children.length - 1) : 0;
        float crossSize = 0;
        int totalFlex;
        foreach (Node k; children)
        {
            Flexible f = cast(Flexible) k;
            if (bounded && f !is null && f.flex > 0)
            {
                totalFlex += f.flex;
                continue;
            }
            Size s = k.layout(make(0, float.infinity, crossMin, crossMax));
            used += mainOf(s);
            crossSize = max(crossSize, crossOf(s));
        }

        float free = bounded ? max(0f, mainMax - used) : 0;
        float perFlex = totalFlex > 0 ? free / totalFlex : 0;
        float handed = 0;
        int flexSeen;
        foreach (Node k; children)
        {
            Flexible f = cast(Flexible) k;
            if (bounded == false || f is null || f.flex <= 0)
            {
                continue;
            }
            flexSeen += f.flex;
            float share = round(perFlex * flexSeen) - handed;
            handed += share;
            Size s = k.layout(make(f.tight ? share : 0, share, crossMin, crossMax));
            used += mainOf(s);
            crossSize = max(crossSize, crossOf(s));
        }

        float mainSize = bounded ? max(mainMax, 0f) : used;
        if (bounded && totalFlex == 0)
        {
            mainSize = max(used, axis == Axis.horizontal ? c.minW : c.minH);
        }
        if (stretch)
        {
            crossSize = crossMax;
        }
        else
        {
            crossSize = max(crossSize, axis == Axis.horizontal ? c.minH : c.minW);
        }

        float pos = 0;
        foreach (Node k; children)
        {
            float slack = crossSize - crossOf(k.size);
            float across = cross == CrossAlign.center ? round(slack / 2) : cross == CrossAlign.end ? slack : 0;
            k.offset = axis == Axis.horizontal ? Point(pos, across) : Point(across, pos);
            pos += mainOf(k.size) + gap;
        }
        return axis == Axis.horizontal ? Size(mainSize, crossSize) : Size(crossSize, mainSize);
    }
}

/// Options of a row or column, waiting for the children: `row(gap: 4)(a, b)`.
struct FlexSpec
{
    Axis axis;        /// main axis
    float gap;        /// space between children
    CrossAlign cross; /// placement of children across the main axis

    /// Stores the options. Needed because `opCall` hides the struct literal.
    this(Axis axis, float gap, CrossAlign cross)
    {
        this.axis = axis;
        this.gap = gap;
        this.cross = cross;
    }

    /// The container holding `kids`.
    Flex opCall(Node[] kids...)
    {
        return new Flex(axis, gap, cross, kids.dup);
    }
}

/// Horizontal flex container: `row(gap: 4)(a, b)`.
FlexSpec row(float gap = 0, CrossAlign cross = CrossAlign.center)
{
    return FlexSpec(Axis.horizontal, gap, cross);
}

/// Vertical flex container: `column(gap: 4)(a, b)`.
FlexSpec column(float gap = 0, CrossAlign cross = CrossAlign.stretch)
{
    return FlexSpec(Axis.vertical, gap, cross);
}

/// Padding options, waiting for the child.
struct PadSpec
{
    Insets insets; /// space around the child

    /// Stores the insets. Needed because `opCall` hides the struct literal.
    this(Insets insets)
    {
        this.insets = insets;
    }

    /// The padding around `child`.
    Padding opCall(Node child)
    {
        return new Padding(insets, child);
    }
}

/// Padding of `all` on every side, or `x` and `y` when given: `pad(all: 8)(child)`.
PadSpec pad(float all = 0, float x = float.nan, float y = float.nan)
{
    import std.math : isNaN;

    return PadSpec(Insets.xy(isNaN(x) ? all : x, isNaN(y) ? all : y));
}

/// Child with fixed width, height or both. NaN leaves an axis to the parent.
final class Sized : Node
{
    float w; /// fixed width, NaN to leave it to the parent
    float h; /// fixed height, NaN to leave it to the parent

    /// Fixes `child` to `w` by `h`.
    this(float w, float h, Node child)
    {
        this.w = w;
        this.h = h;
        add(child);
    }

    /// Tightens the constraints on the fixed axes.
    protected override Size performLayout(Constraints c)
    {
        import std.math : isNaN;

        Constraints k = c;
        if (isNaN(w) == false)
        {
            k.minW = k.maxW = clamp(w, c.minW, c.maxW);
        }
        if (isNaN(h) == false)
        {
            k.minH = k.maxH = clamp(h, c.minH, c.maxH);
        }
        children[0].offset = Point.init;
        return children[0].layout(k);
    }
}

/// Size options, waiting for the child.
struct SizedSpec
{
    float w; /// fixed width, NaN to leave it to the parent
    float h; /// fixed height, NaN to leave it to the parent

    /// Stores the size. Needed because `opCall` hides the struct literal.
    this(float w, float h)
    {
        this.w = w;
        this.h = h;
    }

    /// The box around `child`.
    Sized opCall(Node child)
    {
        return new Sized(w, h, child);
    }
}

/// Fixed width and or height: `sized(w: 80)(child)`.
SizedSpec sized(float w = float.nan, float h = float.nan)
{
    return SizedSpec(w, h);
}

/// Look of a panel.
struct PanelStyle
{
    enum section = "panel"; /// section name in theme files

    /// Variants theme files can style as `[section.variant]`.
    enum Variants
    {
        toolbar, /// top bar
        pane,    /// dock pane body
        status,  /// bottom bar
        header,  /// strip above a list
        popup,   /// popup body
    }

    Color fill;           /// background
    Color border;         /// outline
    float borderWidth = 0; /// outline width
    float radius = 0;     /// corner radius
    float padX = 0;       /// horizontal padding
    float padY = 0;       /// vertical padding
    Color topLine;        /// one pixel line along the top edge
    Color bottomLine;     /// one pixel line along the bottom edge
    Color shadow;         /// soft shadow under the box
    float shadowBlur = 0; /// shadow fade width
    float shadowY = 0;    /// shadow drop below the box

    /// Look of `variant` without a theme. The base panel draws nothing.
    static void applyVariant(ref PanelStyle s, string variant)
    {
        enum Color bar = Color(0x22, 0x22, 0x27, 0xff);
        enum Color sunk = Color(0x1c, 0x1c, 0x20, 0xff);
        enum Color edge = Color(0x11, 0x11, 0x13, 0xff);
        switch (variant)
        {
        case "toolbar":
            s.fill = bar;
            s.bottomLine = edge;
            s.padX = 6;
            s.padY = 4;
            break;
        case "status":
            s.fill = bar;
            s.topLine = edge;
            s.padX = 10;
            s.padY = 3;
            break;
        case "header":
            s.fill = sunk;
            s.bottomLine = bar;
            s.padX = 8;
            s.padY = 6;
            break;
        case "pane":
            s.fill = sunk;
            break;
        case "popup":
            s.fill = bar;
            s.border = Color(0x43, 0x43, 0x4c, 0xff);
            s.borderWidth = 1;
            s.radius = 6;
            s.padX = 4;
            s.padY = 4;
            s.shadow = Color(0, 0, 0, 0x70);
            s.shadowBlur = 10;
            s.shadowY = 4;
            break;
        default:
            break;
        }
    }
}

/// Box with a themed background, outline and padding around one child.
final class Panel : Node
{
    string variant; /// PanelStyle variant

    /// Wraps `child` in a panel of `variant`.
    this(string variant, Node child)
    {
        this.variant = variant;
        add(child);
    }

    /// Lays out the child inside the style's padding.
    protected override Size performLayout(Constraints c)
    {
        PanelStyle s = tree.style!PanelStyle(variant);
        Insets i = Insets.xy(s.padX, s.padY);
        Size cs = children[0].layout(c.deflate(i));
        children[0].offset = Point(i.left, i.top);
        return Size(cs.w + s.padX * 2, cs.h + s.padY * 2);
    }

    /// Shadow, background, then children, then edge lines.
    override void paint(ref PaintContext ctx, Point origin)
    {
        PanelStyle s = ctx.style!PanelStyle(variant);
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        if (s.shadow.a > 0)
        {
            ctx.list.shadow(Rect(r.x, r.y + s.shadowY, r.w, r.h), s.radius, s.shadowBlur, s.shadow);
        }
        if (s.fill.a > 0 || s.border.a > 0)
        {
            ctx.list.rect(r, s.fill, s.radius, s.border, s.borderWidth);
        }
        paintChildren(ctx, origin);
        if (s.topLine.a > 0)
        {
            ctx.list.hline(r.x, r.right, r.y, s.topLine);
        }
        if (s.bottomLine.a > 0)
        {
            ctx.list.hline(r.x, r.right, r.bottom - 1, s.bottomLine);
        }
    }
}

/// Panel options, waiting for the child.
struct PanelSpec
{
    string variant; /// `PanelStyle` variant

    /// Stores the variant. Needed because `opCall` hides the struct literal.
    this(string variant)
    {
        this.variant = variant;
    }

    /// The panel around `child`.
    Panel opCall(Node child)
    {
        return new Panel(variant, child);
    }
}

/// Themed panel: `panel(variant: "toolbar")(child)`.
PanelSpec panel(string variant = null)
{
    return PanelSpec(variant);
}

/// Look of a separator line.
struct SeparatorStyle
{
    enum section = "separator"; /// section name in theme files
    Color color = Color(0x80, 0x80, 0x80, 0xff); /// line color
}

/// One pixel line across the cross axis of its parent flex.
final class Separator : Node
{
    bool vertical; /// true for a vertical line in a row

    /// Creates a separator.
    this(bool vertical)
    {
        this.vertical = vertical;
    }

    /// One pixel thick, as long as allowed.
    protected override Size performLayout(Constraints c)
    {
        return vertical ? Size(1, isInfinity(c.maxH) ? 0 : c.maxH) : Size(isInfinity(c.maxW) ? 0 : c.maxW, 1);
    }

    /// The line.
    override void paint(ref PaintContext ctx, Point origin)
    {
        ctx.list.rect(Rect(origin.x, origin.y, size.w, size.h), ctx.style!SeparatorStyle().color);
    }
}

/// Horizontal line for a column.
Separator hrule()
{
    return new Separator(false);
}

/// Vertical line for a row.
Separator vrule()
{
    return new Separator(true);
}

/// Look of scroll bars.
struct ScrollStyle
{
    enum section = "scroll"; /// section name in theme files
    Color thumb = Color(0x80, 0x80, 0x80, 0x80);      /// thumb color
    Color thumbHover = Color(0x80, 0x80, 0x80, 0xc0); /// thumb under the pointer or dragged
    float width = 8;     /// bar width
    float minThumb = 24; /// shortest thumb length
    float wheelStep = 48; /// distance per wheel notch
}

/// Child of a ScrollView that lays out only the part in view, such as a virtual list.
interface ViewportAware
{
    /// Takes the visible part of the content, `height` tall from `top`, before layout and on every scroll.
    void viewport(float top, float height);
}

/// Vertical scroll view over one child as tall as it wants.
final class ScrollView : Node
{
    float scrollY = 0;  /// distance scrolled from the top, in logical pixels
    bool follow;        /// true to keep showing the end while scrolled to it, for logs
    private bool dragging;  /// thumb is being dragged
    private float grabY;    /// pointer y minus thumb top at grab
    private bool atBottom = true; /// was at the bottom before the last layout

    /// Wraps `child`.
    this(Node child, bool follow)
    {
        this.follow = follow;
        add(child);
        interactive = true;
    }

    /// Content height.
    private float contentH()
    {
        return children[0].size.h;
    }

    /// Largest scroll distance.
    private float maxScroll()
    {
        return max(0f, contentH - size.h);
    }

    /// Fills the constraints, lays the child out with unbounded height.
    /// A ViewportAware child is laid out again if clamping the scroll moved the view.
    protected override Size performLayout(Constraints c)
    {
        Size own = Size(isInfinity(c.maxW) ? c.minW : c.maxW, isInfinity(c.maxH) ? c.minH : c.maxH);
        Constraints cc = Constraints(own.w, own.w, 0, float.infinity);
        ViewportAware va = cast(ViewportAware) children[0];
        size = own;
        if (va !is null)
        {
            va.viewport(scrollY, own.h);
        }
        children[0].layout(cc);
        if (follow && atBottom)
        {
            scrollY = maxScroll;
        }
        scrollY = clamp(scrollY, 0, maxScroll);
        if (va !is null)
        {
            va.viewport(scrollY, own.h);
            children[0].layout(cc);
        }
        children[0].offset = contentOffset();
        return own;
    }

    /// Child offset for the scroll distance, on whole physical pixels so the content's layers move without
    /// tessellating again.
    private Point contentOffset()
    {
        float ppp = tree is null ? 1 : tree.ppp;
        return Point(0, -round(scrollY * ppp) / ppp);
    }

    /// Scrolls to `y`, clamped.
    void scrollTo(float y)
    {
        float before = scrollY;
        scrollY = clamp(y, 0, maxScroll);
        atBottom = scrollY >= maxScroll - 0.5f;
        children[0].offset = contentOffset();
        if (ViewportAware va = cast(ViewportAware) children[0])
        {
            va.viewport(scrollY, size.h);
        }
        if (scrollY != before)
        {
            markNeedsPaint();
        }
    }

    /// Scrolls the least distance that shows `r`, given in content coordinates. A rect taller than the view
    /// shows its top.
    void reveal(Rect r)
    {
        if (r.y < scrollY)
        {
            scrollTo(r.y);
        }
        else if (r.bottom > scrollY + size.h)
        {
            scrollTo(min(r.y, r.bottom - size.h));
        }
    }

    /// Thumb rect in window coordinates, empty when everything fits.
    private Rect thumb(Point origin, ScrollStyle s)
    {
        if (contentH <= size.h || size.h <= 0)
        {
            return Rect.init;
        }
        float h = max(s.minThumb, size.h * size.h / contentH);
        float y = (size.h - h) * scrollY / maxScroll;
        return Rect(origin.x + size.w - s.width - 2, origin.y + y, s.width, h);
    }

    /// Children clipped, then the thumb.
    override void paint(ref PaintContext ctx, Point origin)
    {
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        ctx.clipped(r, { paintChildren(ctx, origin); });
        ScrollStyle s = ctx.style!ScrollStyle();
        Rect t = thumb(origin, s);
        if (t.empty == false)
        {
            ctx.list.rect(t, dragging || hovered ? s.thumbHover : s.thumb, s.width / 2);
        }
    }

    /// The bar area belongs to the view, the rest to the children.
    override Node hitTest(Point p, Point origin)
    {
        Rect r = Rect(origin.x, origin.y, size.w, size.h);
        if (r.contains(p) == false)
        {
            return null;
        }
        ScrollStyle s = tree.style!ScrollStyle();
        if (contentH > size.h && p.x >= r.right - s.width - 4)
        {
            return this;
        }
        return super.hitTest(p, origin);
    }

    /// Thumb dragging and track clicks.
    override bool onPointer(ref const PointerEvent e)
    {
        ScrollStyle s = tree.style!ScrollStyle();
        Rect b = bounds;
        Rect t = thumb(b.pos, s);
        switch (e.kind)
        {
        case PointerKind.down:
            if (t.empty)
            {
                return false;
            }
            if (t.contains(e.pos) == false)
            {
                if (e.pos.x < b.right - s.width - 4)
                {
                    return false;
                }
                scrollTo(scrollY + (e.pos.y < t.y ? -size.h : size.h));
                return true;
            }
            dragging = true;
            grabY = e.pos.y - t.y;
            markNeedsPaint();
            return true;
        case PointerKind.move:
            if (dragging)
            {
                float track = size.h - t.h;
                float top = e.pos.y - grabY - b.y;
                scrollTo(track > 0 ? top / track * maxScroll : 0);
                return true;
            }
            return false;
        case PointerKind.up:
            dragging = false;
            markNeedsPaint();
            return true;
        case PointerKind.enter:
        case PointerKind.leave:
            markNeedsPaint();
            return true;
        default:
            return false;
        }
    }

    /// Wheel scrolling. Horizontal turns and Shift with the wheel go on to the parents.
    override bool onWheel(ref const WheelEvent e)
    {
        if (contentH <= size.h || e.dy == 0 || (e.mods & Mod.shift) != 0)
        {
            return false;
        }
        scrollTo(scrollY + e.dy);
        return true;
    }
}

/// Scrolls every scroll view holding `n` so that `n` shows, innermost first. A view's own content, such as a
/// focused virtual list, keeps its scroll.
void scrollIntoView(Node n)
{
    scrollIntoView(n, n.bounds);
}

/// Scrolls every scroll view holding `n` so that the window rect `r` inside `n` shows, innermost first. A view's
/// own content keeps its scroll when `r` is all of it.
void scrollIntoView(Node n, Rect r)
{
    Rect t = r;
    for (Node p = n.parent; p !is null; p = p.parent)
    {
        ScrollView sv = cast(ScrollView) p;
        if (sv is null)
        {
            continue;
        }
        Rect c = sv.children[0].bounds;
        if (t != c)
        {
            sv.reveal(Rect(t.x - c.x, t.y - c.y, t.w, t.h));
        }
        t = sv.bounds;
    }
}

/// Scroll options, waiting for the child.
struct ScrollSpec
{
    bool follow; /// true to keep showing the end while scrolled to it, for logs

    /// Stores the options. Needed because `opCall` hides the struct literal.
    this(bool follow)
    {
        this.follow = follow;
    }

    /// The scroll view around `child`.
    ScrollView opCall(Node child)
    {
        return new ScrollView(child, follow);
    }
}

/// Vertical scroll view: `scroll(follow: true)(child)`.
ScrollSpec scroll(bool follow = false)
{
    return ScrollSpec(follow);
}

// Panel skeleton from research/examples/layout.d, now with default cross alignments and spacers.
unittest
{
    Fixed filter = new Fixed(Size(40, 16));
    Fixed box = new Fixed(Size(0, 20));
    Fixed summary = new Fixed(Size(96, 16));
    Fixed button = new Fixed(Size(120, 24));
    Flex top = row(gap: 4)(filter, expanded(box));
    Flex bottom = row(gap: 4)(summary, spacer(), button);
    Flex body = column(gap: 4)(top, expanded(new Fixed(Size.init)), bottom);
    Padding root = pad(all: 8)(body);
    Tree t = bareTree(root, Size(400, 300));
    t.flush();
    assert(top.bounds == Rect(8, 8, 384, 20));
    assert(filter.bounds == Rect(8, 10, 40, 16), "centered in a 20 px row");
    assert(box.bounds == Rect(52, 8, 340, 20));
    assert(button.bounds == Rect(272, 268, 120, 24));
}

// Flex shares are whole pixels and add up to the free space.
unittest
{
    Fixed[3] k;
    foreach (ref Fixed f; k)
    {
        f = new Fixed(Size.init);
    }
    Flex r = row()(expanded(k[0]), expanded(k[1]), expanded(k[2]));
    Tree t = bareTree(r, Size(100, 10));
    t.flush();
    assert(k[0].size.w + k[1].size.w + k[2].size.w == 100);
    assert(k[1].size.w == 34 && k[0].size.w == 33);
}

// A column inside a scroll view gets unbounded height, and flex children keep their natural size.
unittest
{
    Node[] rows;
    foreach (int i; 0 .. 50)
    {
        rows ~= new Fixed(Size(10, 20));
    }
    Flex list = column()(rows);
    Flex withFlex = column()(expanded(new Fixed(Size(5, 7))));
    ScrollView sv = scroll()(column()(list, withFlex));
    Tree t = bareTree(sv, Size(200, 100));
    t.flush();
    assert(list.size == Size(200, 1000), "stretched across, as tall as the rows");
    assert(withFlex.size.h == 7);
    sv.scrollTo(5000);
    assert(sv.scrollY == 907);
    assert(sv.hitTest(Point(50, 50), Point(0, 0)) is rows[47]);
    sv.reveal(Rect(0, 40, 10, 20));
    assert(sv.scrollY == 40);
    sv.reveal(Rect(0, 300, 10, 400));
    assert(sv.scrollY == 300, "a tall rect shows its top");
    scrollIntoView(rows[49]);
    assert(sv.scrollY == 900);
    scrollIntoView(list);
    assert(sv.scrollY == 0);
    sv.scrollTo(50);
    scrollIntoView(sv.children[0]);
    assert(sv.scrollY == 50, "the content itself keeps the scroll");
}

// A press on the content bubbling up to the view does not page it, only a press in the scrollbar strip does.
unittest
{
    Node[] rows;
    foreach (int i; 0 .. 50)
    {
        rows ~= new Fixed(Size(10, 20));
    }
    ScrollView sv = scroll()(column()(rows));
    Tree t = bareTree(sv, Size(200, 100));
    t.flush();
    PointerEvent e;
    e.kind = PointerKind.down;
    e.button = 1;
    e.pos = Point(100, 50);
    assert(sv.onPointer(e) == false && sv.scrollY == 0);
    e.pos = Point(199, 90);
    assert(sv.onPointer(e) && sv.scrollY == 100);
}
