/// Popups above the window content: placement next to an anchor, light dismiss, modality and focus return.
///
/// The root of every tree is a `Stage` holding the app root, then the open popups from bottom to top, so
/// paint order, hit testing and Tab order work as for any other children. Popups are placed after every
/// layout, which keeps them next to an anchor that moved. `Host` asks the stage which input to block.
module dentrite.overlay;

import dentrite.containers : CrossAlign;
import dentrite.node;
import std.algorithm.comparison : clamp, max, min;
import std.math : round;

/// Side of the anchor a popup opens on. It flips to the other side when that has more room.
enum Side
{
    below, /// under the anchor
    above, /// over the anchor
    right, /// right of the anchor
    left,  /// left of the anchor
}

/// Look of the popup layer.
struct PopupStyle
{
    enum section = "popup"; /// section name in theme files
    Color scrim; /// fill over everything below a modal popup
}

/// Root of a tree: the app root, then the open popups from bottom to top.
final class Stage : Node
{
    private Node app;      /// app root, or null
    private Popup[] stack; /// open popups, bottom first

    /// App root, or null.
    Node content()
    {
        return app;
    }

    /// Copy of the open popups, bottom first.
    Popup[] popups()
    {
        return stack.dup;
    }

    /// Replaces the app root, keeping the popups above it. The old root leaves first, so popups it closes on
    /// the way out stay closed.
    void setContent(Node n)
    {
        if (app !is null && app !is n)
        {
            Node old = app;
            app = null;
            removeChild(old);
        }
        Node[] kids;
        if (n !is null)
        {
            kids ~= n;
        }
        foreach (Popup p; stack)
        {
            kids ~= p;
        }
        app = n;
        setChildren(kids);
    }

    /// Fills the constraints with the app root. Popups are laid out by `place`.
    protected override Size performLayout(Constraints c)
    {
        Size s = c.constrain(Size(c.maxW, c.maxH));
        if (app !is null)
        {
            app.offset = Point.init;
            app.layout(Constraints.tight(s), false);
        }
        return s;
    }

    /// The app root, then each popup, with the scrim under modal ones.
    override void paint(ref PaintContext ctx, Point origin)
    {
        foreach (Node c; children)
        {
            Popup p = cast(Popup) c;
            if (p !is null && p.modal)
            {
                PopupStyle s = ctx.style!PopupStyle();
                if (s.scrim.a > 0)
                {
                    ctx.list.rect(Rect(origin.x, origin.y, size.w, size.h), s.scrim);
                }
            }
            paintChild(ctx, origin, c);
        }
    }

    /// Lays out and positions every popup. Popups whose anchor left the tree close.
    void place()
    {
        foreach (Popup p; stack.dup)
        {
            if (p.parent !is this)
            {
                continue;
            }
            if (p.atPoint == false && p.anchor !is null && p.anchor.tree !is tree)
            {
                p.close();
                continue;
            }
            placeOne(p);
        }
    }

    /// Lays out `p` in the room next to its anchor and moves it to the side that fits.
    private void placeOne(Popup p)
    {
        Size vp = size;
        bool centered = p.atPoint == false && p.anchor is null;
        Rect a = p.atPoint ? p.at : centered ? Rect.init : p.anchor.bounds;
        bool vertical = p.side == Side.below || p.side == Side.above;
        float after = vertical ? vp.h - a.bottom - p.gap : vp.w - a.right - p.gap;
        float before = vertical ? a.y - p.gap : a.x - p.gap;
        Constraints c = Constraints(0, vp.w, 0, vp.h);
        if (centered == false)
        {
            float room = max(0f, max(after, before));
            if (vertical)
            {
                c.maxH = min(c.maxH, room);
                c.minW = p.align_ == CrossAlign.stretch ? min(a.w, vp.w) : 0;
            }
            else
            {
                c.maxW = min(c.maxW, room);
                c.minH = p.align_ == CrossAlign.stretch ? min(a.h, vp.h) : 0;
            }
        }
        Size s = p.layout(c, false);
        Point o;
        if (centered)
        {
            o = Point((vp.w - s.w) / 2, (vp.h - s.h) / 2);
        }
        else
        {
            bool forward = p.side == Side.below || p.side == Side.right;
            float want = vertical ? s.h : s.w;
            bool useAfter = forward ? want <= after || after >= before : want > before && after > before;
            if (vertical)
            {
                o.y = useAfter ? a.bottom + p.gap : a.y - p.gap - s.h;
                o.x = along(a.x, a.w, s.w, p.align_);
            }
            else
            {
                o.x = useAfter ? a.right + p.gap : a.x - p.gap - s.w;
                o.y = along(a.y, a.h, s.h, p.align_);
            }
        }
        o.x = clamp(o.x, 0, max(0f, vp.w - s.w));
        o.y = clamp(o.y, 0, max(0f, vp.h - s.h));
        float ppp = tree.ppp;
        o = Point(round(o.x * ppp) / ppp, round(o.y * ppp) / ppp);
        if (o != p.offset)
        {
            p.offset = o;
            markNeedsPaint();
        }
    }

    /// Puts `p` on top and moves focus into it if it asks.
    private void push(Popup p)
    {
        Services sv = tree.services;
        p.restore = sv is null || p.focus == false ? null : sv.focused;
        stack ~= p;
        add(p);
        if (p.focus && sv !is null)
        {
            Node f = firstFocusable(p);
            sv.setFocus(f is null ? p : f);
        }
    }

    /// Closes `p` and the popups above it, top first.
    private void pop(Popup p)
    {
        while (stack.length > 0)
        {
            Popup top = stack[$ - 1];
            stack = stack[0 .. $ - 1];
            closeOne(top);
            if (top is p)
            {
                break;
            }
        }
    }

    /// Gives focus back if `p` took it and focus was inside, then detaches `p` and tells its owner.
    private void closeOne(Popup p)
    {
        Services sv = tree.services;
        if (sv !is null && p.focus)
        {
            Node f = sv.focused;
            if (f is null || f.isInside(p))
            {
                sv.setFocus(p.restore !is null && p.restore.tree is tree ? p.restore : null);
            }
        }
        p.restore = null;
        p.atPoint = false;
        removeChild(p);
        markNeedsPaint();
        if (p.onClose !is null)
        {
            p.onClose();
        }
    }

    /// True if a popup above `n` keeps pointer input from it.
    bool blocks(Node n)
    {
        foreach_reverse (Popup p; stack)
        {
            if (p.covers(n))
            {
                return false;
            }
            if (p.grabs)
            {
                return true;
            }
        }
        return false;
    }

    /// Closes the light-dismiss popups that a press on `hit` is outside of, top first.
    /// True if the press goes no further: it closed something, or a modal popup is in the way.
    bool pressOutside(Node hit)
    {
        bool swallow;
        foreach_reverse (Popup p; stack.dup)
        {
            if (p.covers(hit))
            {
                return false;
            }
            if (p.dismiss)
            {
                p.close();
                swallow = true;
            }
            if (p.modal)
            {
                return true;
            }
        }
        return swallow;
    }

    /// Topmost popup that grabs input, or null. Tab stays inside it.
    Popup grabber()
    {
        foreach_reverse (Popup p; stack)
        {
            if (p.grabs)
            {
                return p;
            }
        }
        return null;
    }

    /// True if window keys wait: `focus` is inside a popup that grabs input, as in an open menu, or nothing has
    /// focus while one is open. A list that leaves focus in its field, as a combo box's does, lets them through.
    bool holdsKeys(Node focus)
    {
        if (focus is null)
        {
            return grabber() !is null;
        }
        foreach (Popup p; stack)
        {
            if (p.grabs && focus.isInside(p))
            {
                return true;
            }
        }
        return false;
    }

    /// Closes the topmost grabbing popup if Escape may close it. True if it did.
    bool escape()
    {
        Popup g = grabber();
        if (g is null || g.dismiss == false)
        {
            return false;
        }
        g.close();
        return true;
    }

    /// Closes the light-dismiss popups down to the first modal one, when the window loses focus.
    void dismissAll()
    {
        foreach_reverse (Popup p; stack.dup)
        {
            if (p.dismiss)
            {
                p.close();
            }
            else if (p.modal)
            {
                return;
            }
        }
    }
}

/// Start of a popup `len` long next to an anchor span `len` long starting at `pos`, for alignment `a`.
private float along(float pos, float span, float len, CrossAlign a)
{
    final switch (a)
    {
    case CrossAlign.start:
    case CrossAlign.stretch:
        return pos;
    case CrossAlign.center:
        return pos + round((span - len) / 2);
    case CrossAlign.end:
        return pos + span - len;
    }
}

/// First Tab stop in `n` in tree order, laid out or not, or null.
private Node firstFocusable(Node n)
{
    if (n.tabStop)
    {
        return n;
    }
    foreach (Node c; n.children)
    {
        if (Node f = firstFocusable(c))
        {
            return f;
        }
    }
    return null;
}

/// Box above the window content. Build it once with `popup(...)(content)`, then open and close it as needed.
/// It opens next to the point or rectangle given to `openAt`, else next to `anchor`, else centered.
final class Popup : Node
{
    Node anchor;          /// opens next to this node, and closes when it leaves the tree
    Side side;            /// preferred side of the anchor
    CrossAlign align_;    /// placement along the anchor. Stretch makes it at least as wide (or tall)
    float gap = 0;        /// space between anchor and popup
    bool dismiss = true;  /// closes on a press outside and on Escape
    bool modal;           /// keeps pointer input from everything below
    bool focus = true;    /// takes focus when opened and gives it back when closed
    Node source;          /// node outside that keeps input while open, such as the menu bar that opened it
    bool passPointer;     /// pointer input goes to what is below, as for a tooltip
    void delegate() onClose; /// runs after closing

    private Node restore; /// focus before opening
    private Rect at;      /// rectangle given to `openAt`
    private bool atPoint; /// `at` replaces the anchor until closed

    /// Creates a closed popup around `content`.
    this(Node content)
    {
        add(content);
    }

    /// True while open.
    bool isOpen()
    {
        return parent !is null;
    }

    /// Opens on top of the popups of `t`. Does nothing if already open.
    void open(Tree t)
    {
        if (isOpen == false)
        {
            t.root.push(this);
        }
    }

    /// Opens on top of the popups of the anchor's tree.
    void open()
    {
        assert(anchor !is null && anchor.tree !is null, "open() needs an anchor in a tree");
        open(anchor.tree);
    }

    /// Opens on `t` next to window point `p`, such as the pointer for a context menu. Reopens if open.
    void openAt(Tree t, Point p)
    {
        openAt(t, Rect(p.x, p.y, 0, 0));
    }

    /// Opens on `t` next to window rectangle `r`, such as the pointer and the cursor below it. Reopens if open.
    void openAt(Tree t, Rect r)
    {
        close();
        at = r;
        atPoint = true;
        open(t);
    }

    /// Moves a popup opened next to a rectangle to `r`, as when the control it belongs to moved.
    void moveTo(Rect r)
    {
        if (atPoint && r != at)
        {
            at = r;
            markNeedsLayout();
        }
    }

    /// Closes this popup and the ones above it. Does nothing if closed.
    void close()
    {
        if (Stage s = cast(Stage) parent)
        {
            s.pop(this);
        }
    }

    /// Opens if closed, closes if open.
    void toggle()
    {
        if (isOpen)
        {
            close();
        }
        else
        {
            open();
        }
    }

    /// True if pointer input reaching `n` counts as inside: `n` is in the popup, in `source`, or covered by the
    /// popup holding `source`, so a submenu keeps its parent menus and their menu bar.
    bool covers(Node n)
    {
        if (n is null || source is null)
        {
            return n !is null && n.isInside(this);
        }
        if (n.isInside(this) || n.isInside(source))
        {
            return true;
        }
        for (Node up = source.parent; up !is null; up = up.parent)
        {
            if (Popup p = cast(Popup) up)
            {
                return p !is this && p.covers(n);
            }
        }
        return false;
    }

    /// True if it closes on outside presses or blocks what is below, either way taking input from below.
    bool grabs() const
    {
        return dismiss || modal;
    }

    /// Deepest node under `p`, or null if the popup passes the pointer through.
    override Node hitTest(Point p, Point origin)
    {
        return passPointer ? null : super.hitTest(p, origin);
    }

    /// The content, at its natural size within the constraints.
    protected override Size performLayout(Constraints c)
    {
        children[0].offset = Point.init;
        return children[0].layout(c);
    }
}

/// Popup options, waiting for the content.
struct PopupSpec
{
    Node anchor;          /// opens next to this node
    Side side;            /// preferred side of the anchor
    CrossAlign align_;    /// placement along the anchor
    float gap = 0;        /// space to the anchor
    bool dismiss = true;  /// closes on outside presses and Escape
    bool modal;           /// blocks input below
    bool focus = true;    /// takes focus while open
    Node source;          /// node outside the popup that keeps input while it is open, such as a menu bar
    void delegate() onClose; /// runs after closing

    /// The closed popup around `content`.
    Popup opCall(Node content)
    {
        Popup p = new Popup(content);
        p.anchor = anchor;
        p.side = side;
        p.align_ = align_;
        p.gap = gap;
        p.dismiss = dismiss;
        p.modal = modal;
        p.focus = focus;
        p.source = source;
        p.onClose = onClose;
        return p;
    }
}

/// Closed popup: `popup(anchor: b, side: Side.right)(content)`, then `open` or `toggle` it.
PopupSpec popup(Node anchor = null, Side side = Side.below, CrossAlign align_ = CrossAlign.start, float gap = 0,
    bool dismiss = true, bool modal = false, bool focus = true, Node source = null, void delegate() onClose = null)
{
    PopupSpec s;
    s.anchor = anchor;
    s.side = side;
    s.align_ = align_;
    s.gap = gap;
    s.dismiss = dismiss;
    s.modal = modal;
    s.focus = focus;
    s.source = source;
    s.onClose = onClose;
    return s;
}

version (unittest)
{
    /// Full-size node that puts its one child at `pos`.
    final class At : Node
    {
        Point pos; /// child position

        /// Puts `child` at `pos`.
        this(Node child, Point pos)
        {
            this.pos = pos;
            add(child);
        }

        /// Fills the constraints, the child at its natural size.
        protected override Size performLayout(Constraints c)
        {
            children[0].layout(Constraints.loose(Size(c.maxW, c.maxH)));
            children[0].offset = pos;
            return Size(c.maxW, c.maxH);
        }
    }
}

// Placement: alignments and gap below the anchor, flips to the side with room, clamps into the window,
// shrinks to the larger side, centers without an anchor, opens at a point, and follows a moved anchor.
unittest
{
    Fixed anchor = new Fixed(Size(40, 20));
    At at = new At(anchor, Point(100, 10));
    Tree t = bareTree(at, Size(300, 200));
    Fixed box = new Fixed(Size(80, 50));
    Popup p = popup(anchor: anchor)(box);
    p.open();
    t.flush();
    assert(p.isOpen && p.bounds == Rect(100, 30, 80, 50));

    p.gap = 4;
    p.align_ = CrossAlign.end;
    t.flush();
    assert(p.bounds == Rect(60, 34, 80, 50), "right edges line up");
    p.align_ = CrossAlign.center;
    t.flush();
    assert(p.bounds.x == 80);
    p.gap = 0;
    p.align_ = CrossAlign.stretch;
    box.want = Size(10, 50);
    box.markNeedsLayout();
    t.flush();
    assert(p.bounds == Rect(100, 30, 40, 50), "as wide as the anchor");

    box.want = Size(80, 50);
    box.markNeedsLayout();
    p.align_ = CrossAlign.start;
    at.pos = Point(250, 170);
    at.markNeedsLayout();
    t.flush();
    assert(p.bounds == Rect(220, 120, 80, 50), "flipped above, moved left into the window");

    box.want = Size(80, 500);
    box.markNeedsLayout();
    t.flush();
    assert(p.bounds == Rect(220, 0, 80, 170), "as tall as the room above");

    box.want = Size(80, 50);
    box.markNeedsLayout();
    p.side = Side.right;
    t.flush();
    assert(p.bounds == Rect(170, 150, 80, 50), "flipped left, top clamped");

    p.close();
    p.anchor = null;
    p.open(t);
    t.flush();
    assert(p.bounds == Rect(110, 75, 80, 50), "centered");

    p.side = Side.below;
    p.openAt(t, Point(290, 195));
    t.flush();
    assert(p.bounds == Rect(220, 145, 80, 50));
    p.close();
    assert(p.isOpen == false && t.root.popups.length == 0);
}

// A popup closes when its anchor leaves the tree, and closing one closes the popups above it.
unittest
{
    Fixed anchor = new Fixed(Size(40, 20));
    At at = new At(anchor, Point(0, 0));
    Tree t = bareTree(at, Size(300, 200));
    string[] closed;
    Popup lower = popup(anchor: anchor, onClose: () { closed ~= "lower"; })(new Fixed(Size(10, 10)));
    Popup upper = popup(onClose: () { closed ~= "upper"; })(new Fixed(Size(10, 10)));
    lower.open();
    upper.open(t);
    t.flush();
    assert(t.root.children.length == 3);
    at.setChildren([new Fixed(Size(1, 1))]);
    t.flush();
    assert(closed == ["upper", "lower"] && t.root.children.length == 1);
}

// A boundary inside a closed popup that changed while detached is laid out again when it reopens.
unittest
{
    import dentrite.containers : column, sized;

    Fixed leaf = new Fixed(Size(10, 10));
    Popup p = popup()(column(cross: CrossAlign.start)(sized(w: 30, h: 30)(column()(leaf))));
    Tree t = bareTree(new Fixed(Size.init), Size(300, 200));
    p.open(t);
    t.flush();
    assert(leaf.size == Size(30, 10));
    p.close();
    leaf.want = Size(10, 20);
    leaf.markNeedsLayout();
    p.open(t);
    t.flush();
    assert(leaf.size == Size(30, 20));
}

// Through a host: presses outside close and go no further, hover below is blocked, focus moves in and comes
// back, Escape closes, Tab stays inside, a press in a lower popup closes the upper one and is delivered,
// a modal popup ignores outside presses, `source` keeps input, and losing window focus closes.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : column, sized;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.host : Host;
    import dentrite.platform : Event, EventKind, WindowOptions;
    import dentrite.widgets.button : Button, button;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    HeadlessPlatform hp = new HeadlessPlatform(300, 200);
    Host h = new Host(hp, new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    int under;
    int inside;
    Popup p;
    Button opener = button("Open", onClick: () { p.toggle(); });
    Button below = button("Below", onClick: () { ++under; });
    Button item = button("Item", onClick: () { ++inside; p.close(); });
    Button other = button("Other");
    p = popup(anchor: opener)(column(cross: CrossAlign.start)(item, other));
    h.setRoot(column(cross: CrossAlign.start)(opener, sized(h: 100)(new Fixed(Size.init)), below));

    void click(Node n)
    {
        Rect b = n.bounds;
        Point c = Point(b.x + b.w / 2, b.y + b.h / 2);
        h.inject(PointerKind.move, c);
        h.inject(PointerKind.down, c);
        h.inject(PointerKind.up, c);
        h.frame();
    }

    h.frame();
    click(opener);
    assert(p.isOpen && h.focused is item, "focus moved in");
    Rect bb = below.bounds;
    h.inject(PointerKind.move, Point(bb.x + 2, bb.y + 2));
    assert(below.hovered == false && hp.cursor == CursorShape.arrow, "hover blocked");
    click(below);
    assert(p.isOpen == false && under == 0, "outside press closed and stopped");
    assert(h.focused is opener, "focus came back");
    click(below);
    assert(under == 1);

    click(opener);
    click(item);
    assert(inside == 1 && p.isOpen == false && h.focused is opener);

    click(opener);
    h.injectKey(Key.escape);
    assert(p.isOpen == false && h.focused is opener);

    click(opener);
    h.injectKey(Key.tab);
    h.injectKey(Key.tab);
    assert(h.focused is item, "Tab cycles inside");
    click(opener);
    assert(p.isOpen == false, "the opener is outside, so it closes and its click is stopped");

    Popup sub = popup(anchor: item, side: Side.right)(new Fixed(Size(20, 20)));
    click(opener);
    sub.open();
    h.frame();
    click(item);
    assert(sub.isOpen == false && p.isOpen == false && inside == 2, "closed the upper one, then clicked");

    p.modal = true;
    p.dismiss = false;
    click(opener);
    click(below);
    h.injectKey(Key.escape);
    assert(p.isOpen && under == 1, "modal: outside presses and Escape do nothing");
    p.close();

    p.modal = false;
    p.dismiss = true;
    p.source = opener;
    click(opener);
    click(opener);
    assert(p.isOpen == false, "the click reached the opener, which toggled");
    p.source = null;

    click(opener);
    Event lost = { kind: EventKind.focusLost };
    h.handle(lost);
    assert(p.isOpen == false);
}

// Popups paint over the content, and the scrim of a modal popup covers what is below it.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.containers : panel;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.host : Host;
    import dentrite.platform : WindowOptions;
    import dentrite.theme : Theme;

    WindowOptions o;
    o.fonts = ["fonts/Inter-Regular.otf", "fonts/Inter-SemiBold.otf", "fonts/JetBrainsMono-Regular.ttf"];
    HeadlessPlatform hp = new HeadlessPlatform(100, 100);
    SoftwareRenderer r = new SoftwareRenderer;
    Host h = new Host(hp, r, o);
    scope (exit)
    {
        h.close();
    }
    h.tree.theme = new Theme("[panel]\nfill = #0000ff\n[panel.popup]\nfill = #ff0000\n[popup]\nscrim = #00000080\n",
        "test");
    h.setRoot(panel()(new Fixed(Size.init)));
    Popup p = popup(modal: true)(panel(variant: "popup")(new Fixed(Size(20, 20))));
    p.open(h.tree);
    h.frame();
    uint pixel(int x, int y)
    {
        return r.pixels[y * r.width + x];
    }

    assert(pixel(50, 50) == 0xff0000ff, "popup red over the content");
    assert(pixel(5, 5) == 0xff7f0000, "blue content under half black");
    p.modal = false;
    h.tree.root.markNeedsPaint();
    h.frame();
    assert(pixel(5, 5) == 0xffff0000);
}
