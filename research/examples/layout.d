/// Box-constraint layout: constraints go down, sizes go up, parents set positions.
///
/// Same protocol as Flutter's RenderBox. Each node caches its last constraints
/// and skips work when clean. Relayout stops at boundaries: nodes whose parent
/// ignores their size or whose constraints are tight.
module layout;

import std.algorithm.comparison : clamp, max, min;
import std.algorithm.sorting : sort;
import std.math : ceil, floor, isInfinity;

/// Width and height in logical pixels.
struct Size
{
    float w = 0; /// width
    float h = 0; /// height
}

/// Position in logical pixels.
struct Point
{
    float x = 0; /// horizontal
    float y = 0; /// vertical
}

/// Axis-aligned rectangle.
struct Rect
{
    float x = 0; /// left
    float y = 0; /// top
    float w = 0; /// width
    float h = 0; /// height

    /// True if `p` lies inside, right and bottom edges excluded.
    bool contains(Point p) const
    {
        return p.x >= x && p.y >= y && p.x < x + w && p.y < y + h;
    }
}

/// Space around a child.
struct Insets
{
    float left = 0;   /// left inset
    float top = 0;    /// top inset
    float right = 0;  /// right inset
    float bottom = 0; /// bottom inset

    /// Same inset on all four sides.
    static Insets all(float v)
    {
        return Insets(v, v, v, v);
    }
}

/// Allowed size range handed from parent to child.
struct Constraints
{
    float minW = 0;               /// smallest allowed width
    float maxW = float.infinity;  /// largest allowed width
    float minH = 0;               /// smallest allowed height
    float maxH = float.infinity;  /// largest allowed height

    /// Exactly `s`.
    static Constraints tight(Size s)
    {
        return Constraints(s.w, s.w, s.h, s.h);
    }

    /// Anything from zero up to `s`.
    static Constraints loose(Size s)
    {
        return Constraints(0, s.w, 0, s.h);
    }

    /// True if only one size satisfies the constraints.
    bool isTight() const
    {
        return minW == maxW && minH == maxH;
    }

    /// `s` clamped into range.
    Size constrain(Size s) const
    {
        return Size(clamp(s.w, minW, maxW), clamp(s.h, minH, maxH));
    }

    /// Constraints shrunk by `i`, never below zero.
    Constraints deflate(Insets i) const
    {
        float dx = i.left + i.right;
        float dy = i.top + i.bottom;
        return Constraints(max(0f, minW - dx), max(0f, maxW - dx),
            max(0f, minH - dy), max(0f, maxH - dy));
    }
}

/// Main axis of a flex container.
enum Axis
{
    horizontal, /// row
    vertical,   /// column
}

/// Placement of children across the main axis.
enum CrossAlign
{
    start,   /// left or top
    center,  /// centered
    stretch, /// fill the cross extent
}

/// Queue of relayout boundaries waiting for the next flush.
final class LayoutOwner
{
    Node root;       /// tree root, laid out with tight viewport constraints
    Size viewport;   /// window size
    Node[] dirty;    /// boundaries marked since the last flush

    /// Creates an owner for `root` in a `viewport` sized window.
    this(Node root, Size viewport)
    {
        this.root = root;
        this.viewport = viewport;
        attach(root);
    }

    /// Sets `owner` on `n` and its descendants.
    void attach(Node n)
    {
        n.owner = this;
        foreach (Node c; n.children)
        {
            attach(c);
        }
    }

    /// Changes the viewport and relayouts from the root.
    void resize(Size s)
    {
        viewport = s;
        root.layout(Constraints.tight(s), false);
    }

    /// Relayouts every dirty boundary, parents first.
    void flush()
    {
        if (root.constraints != Constraints.tight(viewport) || root.needsLayout)
        {
            root.layout(Constraints.tight(viewport), false);
        }
        sort!((Node a, Node b) => a.depth < b.depth)(dirty);
        foreach (Node n; dirty)
        {
            if (n.needsLayout)
            {
                n.layout(n.constraints, n.parentUsesSize);
            }
        }
        dirty.length = 0;
    }
}

/// Node in the retained layout tree.
abstract class Node
{
    Node parent;      /// set by `add`
    Node[] children;  /// in paint order
    Point offset;     /// position inside the parent, set by the parent
    Size size;        /// result of the last layout
    LayoutOwner owner; /// set by `LayoutOwner.attach`
    int layoutRuns;   /// times `performLayout` ran

    private Constraints constraints; /// constraints of the last layout
    private bool needsLayout = true; /// stale since the last layout
    private bool boundary;           /// relayout stops here
    private bool parentUsesSize;     /// parent read our size last time

    /// Adds `child` and returns it.
    final Node add(Node child)
    {
        child.parent = this;
        children ~= child;
        if (owner !is null)
        {
            owner.attach(child);
        }
        markNeedsLayout();
        return child;
    }

    /// Lays out under `c`, skipping work when clean and `c` is unchanged.
    final Size layout(Constraints c, bool parentUsesSize = true)
    {
        boundary = parentUsesSize == false || c.isTight || parent is null;
        if (needsLayout == false && c == constraints)
        {
            return size;
        }
        constraints = c;
        this.parentUsesSize = parentUsesSize;
        size = c.constrain(performLayout(c));
        needsLayout = false;
        ++layoutRuns;
        return size;
    }

    /// Marks this node stale and walks up to the nearest relayout boundary.
    final void markNeedsLayout()
    {
        if (needsLayout)
        {
            return;
        }
        needsLayout = true;
        if (boundary == false && parent !is null)
        {
            parent.markNeedsLayout();
        }
        else if (owner !is null)
        {
            owner.dirty ~= this;
        }
    }

    /// True if this node relayouts without its parent.
    final bool isBoundary() const
    {
        return boundary;
    }

    /// Distance from the root.
    final int depth()
    {
        int d;
        for (Node p = parent; p !is null; p = p.parent)
        {
            ++d;
        }
        return d;
    }

    /// Rectangle in window coordinates.
    final Rect bounds()
    {
        Point p = offset;
        for (Node n = parent; n !is null; n = n.parent)
        {
            p.x += n.offset.x;
            p.y += n.offset.y;
        }
        return Rect(p.x, p.y, size.w, size.h);
    }

    /// Deepest node under `p` in window coordinates, or null. Later children win.
    final Node hitTest(Point p)
    {
        if (bounds.contains(p) == false)
        {
            return null;
        }
        foreach_reverse (Node c; children)
        {
            if (Node hit = c.hitTest(p))
            {
                return hit;
            }
        }
        return this;
    }

    /// Computes this node's size under `c` and positions its children.
    protected abstract Size performLayout(Constraints c);
}

/// Fixed-pitch text leaf: 8 px per character, 16 px per line, wraps at the max width.
final class Text : Node
{
    private string text; /// content

    /// Creates a text leaf.
    this(string text)
    {
        this.text = text;
    }

    /// Replaces the text and requests relayout if it changed.
    void setText(string s)
    {
        if (s != text)
        {
            text = s;
            markNeedsLayout();
        }
    }

    /// Current text.
    string content() const
    {
        return text;
    }

    /// Wraps to the available width.
    protected override Size performLayout(Constraints c)
    {
        enum float glyphW = 8;
        enum float lineH = 16;
        float natural = text.length * glyphW;
        if (isInfinity(c.maxW) || natural <= c.maxW)
        {
            return Size(natural, lineH);
        }
        size_t perLine = max(1, cast(size_t) floor(c.maxW / glyphW));
        size_t lines = (text.length + perLine - 1) / perLine;
        return Size(perLine * glyphW, lines * lineH);
    }
}

/// Leaf that wants a given size, used for boxes, buttons and stand-ins.
final class Fixed : Node
{
    Size want; /// preferred size before constraints

    /// Creates a leaf preferring `want`.
    this(Size want)
    {
        this.want = want;
    }

    /// Returns the preferred size, clamped by `layout`.
    protected override Size performLayout(Constraints c)
    {
        return want;
    }
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
    int flex = 1;      /// share weight
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

/// Row or column with gaps and flex children.
final class Flex : Node
{
    Axis axis;          /// main axis
    float gap = 0;      /// space between children
    CrossAlign cross;   /// cross-axis placement

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
    protected override Size performLayout(Constraints c)
    {
        float mainMax = axis == Axis.horizontal ? c.maxW : c.maxH;
        float crossMax = axis == Axis.horizontal ? c.maxH : c.maxW;
        bool stretch = cross == CrossAlign.stretch && isInfinity(crossMax) == false;
        float crossMin = stretch ? crossMax : 0;

        float used = children.length > 1 ? gap * (children.length - 1) : 0;
        float crossSize = 0;
        int totalFlex;
        foreach (Node k; children)
        {
            Flexible f = cast(Flexible) k;
            if (f !is null && f.flex > 0)
            {
                totalFlex += f.flex;
                continue;
            }
            Size s = k.layout(make(0, float.infinity, crossMin, crossMax));
            used += mainOf(s);
            crossSize = max(crossSize, crossOf(s));
        }

        bool bounded = isInfinity(mainMax) == false;
        float free = bounded ? max(0f, mainMax - used) : 0;
        float perFlex = totalFlex > 0 ? free / totalFlex : 0;
        foreach (Node k; children)
        {
            Flexible f = cast(Flexible) k;
            if (f is null || f.flex <= 0)
            {
                continue;
            }
            float share = perFlex * f.flex;
            Size s = k.layout(make(f.tight ? share : 0, share, crossMin, crossMax));
            used += mainOf(s);
            crossSize = max(crossSize, crossOf(s));
        }

        float mainSize = bounded ? mainMax : used;
        if (stretch)
        {
            crossSize = crossMax;
        }

        float pos = 0;
        foreach (Node k; children)
        {
            float slack = crossSize - crossOf(k.size);
            float across = cross == CrossAlign.center ? slack / 2 : 0;
            k.offset = axis == Axis.horizontal ? Point(pos, across) : Point(across, pos);
            pos += mainOf(k.size) + gap;
        }
        return axis == Axis.horizontal ? Size(mainSize, crossSize) : Size(crossSize, mainSize);
    }
}

/// Options of a row or column, waiting for the children: `row(gap: 4)(a, b)`.
///
/// Options and children take two calls because D binds a positional argument
/// after a named one to the next parameter. One call would send `a` in
/// `row(gap: 4, a)` to `cross`.
struct FlexSpec
{
    Axis axis;        /// main axis
    float gap;        /// space between children
    CrossAlign cross; /// cross-axis placement

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

/// Horizontal flex container. Options by name in any order, then children: `row(gap: 4)(a, b)`.
FlexSpec row(float gap = 0, CrossAlign cross = CrossAlign.start)
{
    return FlexSpec(Axis.horizontal, gap, cross);
}

/// Vertical flex container, as `row`.
FlexSpec column(float gap = 0, CrossAlign cross = CrossAlign.start)
{
    return FlexSpec(Axis.vertical, gap, cross);
}

/// Padding of `all` on every side around `child`.
Padding pad(float all, Node child)
{
    return new Padding(Insets.all(all), child);
}

/// Leaf wanting `w` by `h`, clamped by its constraints like any node.
Fixed box(float w = 0, float h = 0)
{
    return new Fixed(Size(w, h));
}

/// Breakpoints panel skeleton in a 400x300 window.
unittest
{
    Text filterLabel = new Text("Filter");
    Fixed filterBox = new Fixed(Size(0, 20));
    Text listItem = new Text("main.d:42");
    Flex listBody = column(cross: CrossAlign.stretch)(listItem);
    Padding listPad = new Padding(Insets.all(4), listBody);
    Flexible list = expanded(listPad);
    Text summary = new Text("5 of 5 shown");
    Fixed spacer = new Fixed(Size(0, 0));
    Fixed button = new Fixed(Size(120, 24));
    Flex top = row(gap: 4, cross: CrossAlign.center)(filterLabel, expanded(filterBox));
    Flex bottom = row(gap: 4, cross: CrossAlign.center)(summary, expanded(spacer), button);
    Flex body = column(gap: 4, cross: CrossAlign.stretch)(top, list, bottom);
    Padding root = new Padding(Insets.all(8), body);
    LayoutOwner owner = new LayoutOwner(root, Size(400, 300));
    owner.flush();

    assert(root.size == Size(400, 300));
    assert(top.bounds == Rect(8, 8, 384, 20));
    assert(filterLabel.bounds == Rect(8, 10, 48, 16), "centered in a 20 px row");
    assert(filterBox.bounds == Rect(60, 8, 332, 20), "takes what the label left");
    assert(list.bounds == Rect(8, 32, 384, 232), "column remainder");
    assert(bottom.bounds == Rect(8, 268, 384, 24));
    assert(button.bounds == Rect(272, 268, 120, 24), "pushed right by the spacer");
    assert(owner.root.hitTest(Point(300, 280)) is button);
    assert(owner.root.hitTest(Point(100, 50)) is listItem);

    // Caching: a longer summary relayouts the outer column, not the list or the top row.
    assert(body.isBoundary, "tight constraints from the padding");
    summary.setText("10 of 50 shown");
    assert(owner.dirty == [cast(Node) body]);
    owner.flush();
    assert(root.layoutRuns == 1);
    assert(body.layoutRuns == 2);
    assert(bottom.layoutRuns == 2 && summary.layoutRuns == 2);
    assert(spacer.layoutRuns == 2, "its share shrank");
    assert(button.layoutRuns == 1, "same constraints, cached");
    assert(top.layoutRuns == 1 && list.layoutRuns == 1 && listItem.layoutRuns == 1);
    assert(button.bounds == Rect(272, 268, 120, 24));

    // Boundary: the list gets tight constraints, so its contents relayout alone.
    assert(listBody.isBoundary);
    listItem.setText("very/long/path/to/some/deeply/nested/source/file.d:1234");
    owner.flush();
    assert(body.layoutRuns == 2, "outer column untouched");
    assert(listBody.layoutRuns == 2);
    assert(listItem.size == Size(376, 32), "wrapped to the list width");
}

/// Loose flex children may be smaller than their share.
unittest
{
    Fixed a = new Fixed(Size(50, 10));
    Fixed b = new Fixed(Size(500, 10));
    Flex r = row()(new Flexible(a, tight: false), new Flexible(b, tight: false));
    LayoutOwner owner = new LayoutOwner(r, Size(200, 10));
    owner.flush();
    assert(a.size == Size(50, 10), "loose: keeps its own width");
    assert(b.size == Size(100, 10), "clamped to its share");
    assert(b.bounds.x == 50);
}
