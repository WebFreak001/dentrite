/// Sidebar and content side by side, collapsing to one at a time or to a drawer over the content when narrow.
///
/// The choice happens during layout, from the width offered, so a split view in a dock pane collapses with the
/// pane. Signals are only written after layout, through the host's update round.
module dentrite.widgets.splitview;

import dentrite.containers : panel, row, vrule;
import dentrite.node;
import dentrite.signals : Signal, effect, signal;
import dentrite.widgets.button : button;
import dentrite.widgets.icons : Icon;
import std.algorithm.comparison : max, min;
import std.math : isInfinity;

/// Look of a split view.
struct SplitViewStyle
{
    enum section = "split"; /// section name in theme files

    Color scrim = Color(0, 0, 0, 0x60);           /// fill over the content under an open drawer
    Color drawer = Color(0x1c, 0x1c, 0x20, 0xff); /// background of the sidebar as a drawer
    Color shadow = Color(0, 0, 0, 0x80);          /// soft shadow under the drawer
    float shadowBlur = 16;                        /// shadow fade width
}

/// What a split view shows when narrower than its `minW`.
enum Collapse
{
    navigate, /// the sidebar or the content, with a back bar over the content
    drawer,   /// the content, with the sidebar as a drawer over it
}

/// Sidebar beside the content while at least `minW` wide, collapsed as `mode` says when narrower.
///
/// `sideShown` picks what shows while collapsed: the sidebar over the content when navigating, the drawer
/// open over it otherwise. The app sets it, such as to false when an item of the sidebar is chosen. The back
/// button and Alt+Left set it back to true when navigating, and a press outside the drawer or Escape close the
/// drawer. Nodes that leave stay built and keep their state, focus inside them is dropped.
final class SplitView : Node, Updatable
{
    Node side;             /// sidebar
    Node content;          /// main content
    float sideW;           /// sidebar width, side by side and as a drawer
    float minW;            /// narrowest width showing both, bound included
    Collapse mode;         /// what shows when narrower than `minW`
    Signal!bool sideShown; /// while collapsed, true shows the sidebar or opens its drawer
    Signal!bool collapsed; /// set after each layout to whether it collapsed, or null
    private Node rule;     /// line between the sidebar and the content
    private Node backBar;  /// bar over the content while navigating, with the back button
    private bool narrow;   /// collapsed at the last layout

    /// Splits `side` and `content`. A null `sideShown` starts on the sidebar when navigating, closed otherwise.
    this(Node side, Node content, float sideW, float minW, Collapse mode, Signal!bool sideShown,
        Signal!bool collapsed, string backLabel)
    {
        assert(side.parent is null && content.parent is null, "node already has a parent");
        this.side = side;
        this.content = content;
        this.sideW = sideW;
        this.minW = minW;
        this.mode = mode;
        this.sideShown = sideShown is null ? signal(mode == Collapse.navigate) : sideShown;
        this.collapsed = collapsed;
        rule = vrule();
        backBar = panel(variant: "toolbar")(row()(button(backLabel, () { this.sideShown.set(true); },
            icon: Icon.chevronLeft, variant: "toolbar")));
        effect(() {
            this.sideShown.get;
            markNeedsLayout();
        });
    }

    /// True if collapsed at the last layout.
    bool isCollapsed() const
    {
        return narrow;
    }

    /// True while the sidebar shows as a drawer over the content.
    bool drawerOpen() const
    {
        return narrow && mode == Collapse.drawer && children.length == 2;
    }

    /// Attaches `kids` in place of the children. Newly attached ones are laid out in full, as the running flush
    /// may drop boundaries the attach queued.
    private void show(Node[] kids)
    {
        if (children == kids)
        {
            return;
        }
        bool[Node] had;
        foreach (Node c; children)
        {
            had[c] = true;
        }
        setChildren(kids);
        foreach (Node k; kids)
        {
            if ((k in had) is null)
            {
                k.markSubtreeNeedsLayout();
            }
        }
    }

    /// Picks what shows from the width offered and lays it out. Takes the full size offered, give it bounds.
    protected override Size performLayout(Constraints c)
    {
        float w = isInfinity(c.maxW) ? max(c.minW, minW) : c.maxW;
        float h = isInfinity(c.maxH) ? c.minH : c.maxH;
        narrow = w < minW;
        bool open = sideShown.peek;
        if (narrow == false)
        {
            show([side, rule, content]);
            float sw = min(sideW, w);
            side.layout(Constraints.tight(Size(sw, h)));
            float rw = rule.layout(Constraints(0, float.infinity, h, h)).w;
            content.layout(Constraints.tight(Size(max(0f, w - sw - rw), h)));
            side.offset = Point.init;
            rule.offset = Point(sw, 0);
            content.offset = Point(sw + rw, 0);
        }
        else if (mode == Collapse.navigate && open)
        {
            show([side]);
            side.layout(Constraints.tight(Size(w, h)));
            side.offset = Point.init;
        }
        else if (mode == Collapse.navigate)
        {
            show([backBar, content]);
            float bh = backBar.layout(Constraints(w, w, 0, h)).h;
            content.layout(Constraints.tight(Size(w, max(0f, h - bh))));
            backBar.offset = Point.init;
            content.offset = Point(0, bh);
        }
        else
        {
            show(open ? [content, side] : [content]);
            content.layout(Constraints.tight(Size(w, h)));
            content.offset = Point.init;
            if (open)
            {
                side.layout(Constraints.tight(Size(min(sideW, w), h)));
                side.offset = Point.init;
            }
        }
        interactive = drawerOpen;
        return Size(w, h);
    }

    /// The children, with a scrim over the content and a background under an open drawer.
    override void paint(ref PaintContext ctx, Point origin)
    {
        if (drawerOpen == false)
        {
            paintChildren(ctx, origin);
            return;
        }
        SplitViewStyle s = ctx.style!SplitViewStyle();
        paintChild(ctx, origin, content);
        Rect all = Rect(origin.x, origin.y, size.w, size.h);
        ctx.list.rect(all, s.scrim);
        Rect d = Rect(origin.x, origin.y, side.size.w, side.size.h);
        if (s.shadow.a > 0)
        {
            ctx.clipped(all, () { ctx.list.shadow(d, 0, s.shadowBlur, s.shadow); });
        }
        ctx.list.rect(d, s.drawer);
        paintChild(ctx, origin, side);
    }

    /// Deepest node under `p`. With the drawer open, the content counts as this view, for closing it.
    override Node hitTest(Point p, Point origin)
    {
        if (drawerOpen == false)
        {
            return super.hitTest(p, origin);
        }
        if (Rect(origin.x, origin.y, size.w, size.h).contains(p) == false)
        {
            return null;
        }
        if (Node hit = side.hitTest(p, origin + side.offset))
        {
            return hit;
        }
        return this;
    }

    /// Closes the drawer on a press outside it.
    override bool onPointer(ref const PointerEvent e)
    {
        if (drawerOpen && e.kind == PointerKind.down)
        {
            sideShown.set(false);
            return true;
        }
        return false;
    }

    /// Escape closes the drawer, Alt+Left goes back to the sidebar while navigating.
    override bool onKey(ref const KeyEvent e)
    {
        if (drawerOpen && e.key == Key.escape && e.mods == 0)
        {
            sideShown.set(false);
            return true;
        }
        if (narrow && mode == Collapse.navigate && sideShown.peek == false && e.key == Key.left && e.mods == Mod.alt)
        {
            sideShown.set(true);
            return true;
        }
        return false;
    }

    /// Writes `collapsed` after layout, the host lays out again in the same frame if that changed anything.
    void update()
    {
        if (collapsed !is null && collapsed.peek != narrow)
        {
            collapsed.set(narrow);
        }
    }

    /// Nothing cached.
    void invalidate()
    {
    }

    /// Joins the host's update round.
    override void onAttach()
    {
        tree.addUpdater(this);
    }

    /// Leaves the host's update round.
    override void onDetach()
    {
        tree.removeUpdater(this);
    }
}

/// Split view options, waiting for the sidebar and the content.
struct SplitViewSpec
{
    Signal!bool sideShown; /// while collapsed, true shows the sidebar or opens its drawer
    float minW;            /// narrowest width showing both
    float sideW;           /// sidebar width
    Collapse mode;         /// what shows when narrower than `minW`
    Signal!bool collapsed; /// set after each layout to whether it collapsed, or null
    string backLabel;      /// caption of the back button while navigating

    /// Stores the options. Needed because `opCall` hides the struct literal.
    this(Signal!bool sideShown, float minW, float sideW, Collapse mode, Signal!bool collapsed, string backLabel)
    {
        this.sideShown = sideShown;
        this.minW = minW;
        this.sideW = sideW;
        this.mode = mode;
        this.collapsed = collapsed;
        this.backLabel = backLabel;
    }

    /// The split view over `side` and `content`.
    SplitView opCall(Node side, Node content)
    {
        return new SplitView(side, content, sideW, minW, mode, sideShown, collapsed, backLabel);
    }
}

/// Sidebar beside the content, collapsing below `minW`: `splitView(shown, minW: 600)(list, details)`.
SplitViewSpec splitView(Signal!bool sideShown = null, float minW = 600, float sideW = 240,
    Collapse mode = Collapse.navigate, Signal!bool collapsed = null, string backLabel = "Back")
{
    return SplitViewSpec(sideShown, minW, sideW, mode, collapsed, backLabel);
}

// Side by side at the bound, then the sidebar or the content with a back bar below it. The back button and
// Alt+Left go back, and `collapsed` follows within the frame.
unittest
{
    import dentrite.host : Host;
    import dentrite.platform : Event, EventKind, Metrics;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.signals : Scope, effectScope;
    import dentrite.widgets.menu : clickOn, menuHost;

    Host h = menuHost(600, 300);
    scope (exit)
    {
        h.close();
    }
    void resize(int w)
    {
        (cast(HeadlessPlatform) h.platform).size = Metrics(w, 300, 1);
        Event e = Event(EventKind.resized);
        h.handle(e);
        h.frame();
    }

    Node side = new Fixed(Size(10, 10));
    Node content = new Fixed(Size(10, 10));
    Signal!bool shown = signal(true);
    Signal!bool folded = signal(false);
    SplitView v;
    scope Scope s = effectScope(() { v = splitView(shown, minW: 600, sideW: 200, collapsed: folded)(side, content); });
    h.setRoot(v);
    h.frame();
    assert(side.bounds == Rect(0, 0, 200, 300) && content.bounds == Rect(201, 0, 399, 300));
    assert(folded.peek == false && v.isCollapsed == false);
    resize(599);
    assert(folded.peek && v.children == [side] && side.size.w == 599 && content.tree is null);
    shown.set(false);
    h.frame();
    assert(v.children.length == 2 && content.bounds.y > 0 && content.bounds.bottom == 300 && side.tree is null);
    clickOn(h, v.children[0].children[0].children[0]);
    assert(shown.peek && v.children == [side]);
    shown.set(false);
    h.frame();
    h.setFocus(null);
    h.injectKey(Key.left, Mod.alt);
    assert(shown.peek);
    resize(600);
    assert(folded.peek == false && v.children.length == 3);
}

// As a drawer: the content alone when closed, the sidebar over it when open, closed by a press outside it or
// Escape, while a press inside reaches the sidebar.
unittest
{
    import dentrite.host : Host;
    import dentrite.signals : Scope, effectScope;
    import dentrite.widgets.button : Button;
    import dentrite.widgets.menu : clickOn, menuHost;

    Host h = menuHost(500, 300);
    scope (exit)
    {
        h.close();
    }
    int clicks;
    Button inSide = button("Side", () { ++clicks; });
    Node content = new Fixed(Size(10, 10));
    Signal!bool open = signal(false);
    SplitView v;
    scope Scope s = effectScope(() {
        v = splitView(open, minW: 600, sideW: 200, mode: Collapse.drawer)(inSide, content);
    });
    h.setRoot(v);
    h.frame();
    assert(v.children == [content] && content.size == Size(500, 300) && v.drawerOpen == false);
    open.set(true);
    h.frame();
    assert(v.drawerOpen && inSide.tree !is null && content.size == Size(500, 300));
    clickOn(h, inSide);
    assert(clicks == 1 && open.peek);
    h.inject(PointerKind.down, Point(400, 150));
    h.inject(PointerKind.up, Point(400, 150));
    h.frame();
    assert(open.peek == false && v.drawerOpen == false);
    open.set(true);
    h.frame();
    h.setFocus(inSide);
    h.injectKey(Key.escape);
    h.frame();
    assert(open.peek == false);
}
