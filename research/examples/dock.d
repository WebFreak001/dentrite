/// Docking layout: splits, tab stacks and floating windows, with drop zones and save/restore.
///
/// Pure data. A retained UI keeps this tree as its shell, an immediate UI
/// stores it in persistent memory and walks it every frame. Panes are string
/// IDs that the application maps to content.
module dock;

import layout : Point, Rect;
import std.algorithm.comparison : min;
import std.algorithm.mutation : remove;
import std.algorithm.searching : countUntil;
import std.json;

/// Interior node kind.
enum Kind
{
    split, /// children side by side or stacked
    tabs,  /// panes sharing one area, one visible
}

/// Where a dragged pane lands relative to a tab stack.
enum Zone
{
    none,   /// no drop
    center, /// join the stack as a tab
    left,   /// split, new pane on the left
    right,  /// split, new pane on the right
    top,    /// split, new pane on top
    bottom, /// split, new pane at the bottom
}

/// Splitter thickness between split children.
enum float splitterSize = 4;

/// Tab bar height of a stack.
enum float tabBarHeight = 24;

/// Node of the dock tree.
final class DockNode
{
    Kind kind;            /// split or tabs
    bool vertical;        /// split direction, true stacks children top to bottom
    float[] shares;       /// split weights, one per child
    DockNode[] children;  /// split children
    string[] panes;       /// tab stack contents
    size_t active;        /// selected tab
    DockNode parent;      /// null for a root
    Rect rect;            /// set by `DockSpace.layout`

    /// New tab stack holding `panes`.
    static DockNode stack(string[] panes...)
    {
        DockNode n = new DockNode;
        n.kind = Kind.tabs;
        n.panes = panes.dup;
        return n;
    }

    /// New split of `kids` with equal shares.
    static DockNode split(bool vertical, DockNode[] kids...)
    {
        DockNode n = new DockNode;
        n.kind = Kind.split;
        n.vertical = vertical;
        foreach (DockNode k; kids)
        {
            n.children ~= k;
            n.shares ~= 1;
            k.parent = n;
        }
        return n;
    }

    /// True for a stack with no panes or a split with no children.
    bool empty() const
    {
        return kind == Kind.tabs ? panes.length == 0 : children.length == 0;
    }
}

/// Window with its own dock tree, outside the main area.
struct Floating
{
    Rect rect;     /// window rectangle
    DockNode root; /// contents
}

/// Main dock tree plus floating windows.
final class DockSpace
{
    DockNode root;        /// main area
    Floating[] floating;  /// detached windows, last on top

    /// Creates a space with `root` as the main tree.
    this(DockNode root)
    {
        this.root = root;
    }

    /// Assigns rects: splits divide by share, stacks reserve a tab bar.
    void layout(Rect area)
    {
        place(root, area);
        foreach (ref Floating f; floating)
        {
            place(f.root, f.rect);
        }
    }

    /// Recursive part of `layout`.
    private void place(DockNode n, Rect r)
    {
        n.rect = r;
        if (n.kind == Kind.tabs)
        {
            return;
        }
        float total = 0;
        foreach (float s; n.shares)
        {
            total += s;
        }
        float extent = (n.vertical ? r.h : r.w) - splitterSize * (n.children.length - 1);
        float pos = n.vertical ? r.y : r.x;
        foreach (size_t i, DockNode c; n.children)
        {
            float len = extent * n.shares[i] / total;
            place(c, n.vertical ? Rect(r.x, pos, r.w, len) : Rect(pos, r.y, len, r.h));
            pos += len + splitterSize;
        }
    }

    /// Stack holding `pane`, or null.
    DockNode find(string pane)
    {
        DockNode hit = findIn(root, pane);
        foreach (ref Floating f; floating)
        {
            if (hit is null)
            {
                hit = findIn(f.root, pane);
            }
        }
        return hit;
    }

    /// Recursive part of `find`.
    private static DockNode findIn(DockNode n, string pane)
    {
        if (n.kind == Kind.tabs)
        {
            return countUntil(n.panes, pane) >= 0 ? n : null;
        }
        foreach (DockNode c; n.children)
        {
            if (DockNode hit = findIn(c, pane))
            {
                return hit;
            }
        }
        return null;
    }

    /// Stack under `p`, floating windows first, or null.
    DockNode stackAt(Point p)
    {
        foreach_reverse (ref Floating f; floating)
        {
            if (DockNode hit = stackIn(f.root, p))
            {
                return hit;
            }
        }
        return stackIn(root, p);
    }

    /// Recursive part of `stackAt`.
    private static DockNode stackIn(DockNode n, Point p)
    {
        if (n.rect.contains(p) == false)
        {
            return null;
        }
        if (n.kind == Kind.tabs)
        {
            return n;
        }
        foreach (DockNode c; n.children)
        {
            if (DockNode hit = stackIn(c, p))
            {
                return hit;
            }
        }
        return null;
    }

    /// Drop zone for `p` over `target`: the middle half joins, otherwise the nearest edge splits.
    static Zone zoneAt(DockNode target, Point p)
    {
        Rect r = target.rect;
        if (r.contains(p) == false)
        {
            return Zone.none;
        }
        float fx = (p.x - r.x) / r.w;
        float fy = (p.y - r.y) / r.h;
        if (fx >= 0.25 && fx <= 0.75 && fy >= 0.25 && fy <= 0.75)
        {
            return Zone.center;
        }
        float best = fx;
        Zone z = Zone.left;
        if (1 - fx < best)
        {
            best = 1 - fx;
            z = Zone.right;
        }
        if (fy < best)
        {
            best = fy;
            z = Zone.top;
        }
        if (1 - fy < best)
        {
            z = Zone.bottom;
        }
        return z;
    }

    /// Rect to highlight while dragging over `target` at zone `z`.
    static Rect preview(DockNode target, Zone z)
    {
        Rect r = target.rect;
        final switch (z)
        {
        case Zone.none:
            return Rect.init;
        case Zone.center:
            return r;
        case Zone.left:
            return Rect(r.x, r.y, r.w / 2, r.h);
        case Zone.right:
            return Rect(r.x + r.w / 2, r.y, r.w / 2, r.h);
        case Zone.top:
            return Rect(r.x, r.y, r.w, r.h / 2);
        case Zone.bottom:
            return Rect(r.x, r.y + r.h / 2, r.w, r.h / 2);
        }
    }

    /// Moves `pane` into or beside `target`, then simplifies.
    void dock(string pane, DockNode target, Zone z)
    {
        if (z == Zone.none || (target.panes == [pane]))
        {
            return;
        }
        detach(pane);
        if (z == Zone.center)
        {
            target.panes ~= pane;
            target.active = target.panes.length - 1;
            simplify();
            return;
        }
        bool vertical = z == Zone.top || z == Zone.bottom;
        bool before = z == Zone.left || z == Zone.top;
        DockNode added = DockNode.stack(pane);
        DockNode p = target.parent;
        if (p !is null && p.vertical == vertical)
        {
            size_t i = countUntil(p.children, target);
            float half = p.shares[i] / 2;
            p.shares[i] = half;
            size_t at = before ? i : i + 1;
            p.children = p.children[0 .. at] ~ added ~ p.children[at .. $];
            p.shares = p.shares[0 .. at] ~ half ~ p.shares[at .. $];
            added.parent = p;
        }
        else
        {
            DockNode s = before ? DockNode.split(vertical, added, target)
                : DockNode.split(vertical, target, added);
            replace(target, s, p);
        }
        simplify();
    }

    /// Moves `pane` into a new floating window at `r`.
    void undock(string pane, Rect r)
    {
        detach(pane);
        floating ~= Floating(r, DockNode.stack(pane));
        simplify();
    }

    /// Removes `pane` from its stack, leaving the stack possibly empty.
    private void detach(string pane)
    {
        DockNode s = find(pane);
        if (s is null)
        {
            return;
        }
        s.panes = s.panes.remove(countUntil(s.panes, pane));
        s.active = s.panes.length == 0 ? 0 : min(s.active, s.panes.length - 1);
    }

    /// Puts `with_` where `old` was under `p`, or makes it the root.
    private void replace(DockNode old, DockNode with_, DockNode p)
    {
        with_.parent = p;
        if (p is null)
        {
            if (root is old)
            {
                root = with_;
            }
            foreach (ref Floating f; floating)
            {
                if (f.root is old)
                {
                    f.root = with_;
                }
            }
            return;
        }
        p.children[countUntil(p.children, old)] = with_;
    }

    /// Drops empty nodes, collapses single-child splits, flattens same-direction nesting.
    void simplify()
    {
        root = tidy(root);
        if (root is null)
        {
            root = DockNode.stack();
        }
        root.parent = null;
        Floating[] kept;
        foreach (ref Floating f; floating)
        {
            f.root = tidy(f.root);
            if (f.root !is null)
            {
                f.root.parent = null;
                kept ~= f;
            }
        }
        floating = kept;
    }

    /// Simplified replacement for `n`, or null if nothing is left.
    private static DockNode tidy(DockNode n)
    {
        if (n.kind == Kind.tabs)
        {
            return n.empty ? null : n;
        }
        DockNode[] kids;
        float[] shares;
        foreach (size_t i, DockNode c; n.children)
        {
            DockNode t = tidy(c);
            if (t is null)
            {
                continue;
            }
            if (t.kind == Kind.split && t.vertical == n.vertical)
            {
                float sum = 0;
                foreach (float s; t.shares)
                {
                    sum += s;
                }
                foreach (size_t j, DockNode g; t.children)
                {
                    kids ~= g;
                    shares ~= n.shares[i] * t.shares[j] / sum;
                }
                continue;
            }
            kids ~= t;
            shares ~= n.shares[i];
        }
        if (kids.length == 0)
        {
            return null;
        }
        if (kids.length == 1)
        {
            return kids[0];
        }
        n.children = kids;
        n.shares = shares;
        foreach (DockNode k; kids)
        {
            k.parent = n;
        }
        return n;
    }

    /// Layout as JSON, for the settings file.
    JSONValue save()
    {
        JSONValue[] wins;
        foreach (ref Floating f; floating)
        {
            JSONValue w = JSONValue(["x": f.rect.x, "y": f.rect.y, "w": f.rect.w, "h": f.rect.h]);
            w["root"] = toJson(f.root);
            wins ~= w;
        }
        JSONValue j = JSONValue(["root": toJson(root)]);
        j["floating"] = JSONValue(wins);
        return j;
    }

    /// Space rebuilt from `save` output.
    static DockSpace restore(const JSONValue j)
    {
        DockSpace d = new DockSpace(fromJson(j["root"]));
        if (const(JSONValue)* wins = "floating" in j)
        {
            foreach (const JSONValue w; wins.array)
            {
                Rect r = Rect(num(w["x"]), num(w["y"]), num(w["w"]), num(w["h"]));
                d.floating ~= Floating(r, fromJson(w["root"]));
            }
        }
        return d;
    }

    /// JSON for one node.
    private static JSONValue toJson(DockNode n)
    {
        if (n.kind == Kind.tabs)
        {
            JSONValue t = JSONValue(["tabs": JSONValue(n.panes)]);
            t["active"] = n.active;
            return t;
        }
        JSONValue[] kids;
        foreach (DockNode c; n.children)
        {
            kids ~= toJson(c);
        }
        JSONValue s = JSONValue(["split": n.vertical ? "v" : "h"]);
        s["shares"] = JSONValue(n.shares);
        s["children"] = JSONValue(kids);
        return s;
    }

    /// Node from its JSON.
    private static DockNode fromJson(const JSONValue j)
    {
        if (const(JSONValue)* tabs = "tabs" in j)
        {
            DockNode t = DockNode.stack();
            foreach (const JSONValue p; tabs.array)
            {
                t.panes ~= p.str;
            }
            if (const(JSONValue)* a = "active" in j)
            {
                t.active = cast(size_t) a.integer;
            }
            return t;
        }
        DockNode s = DockNode.split(j["split"].str == "v");
        foreach (size_t i, const JSONValue c; j["children"].array)
        {
            DockNode k = fromJson(c);
            k.parent = s;
            s.children ~= k;
            s.shares ~= num(j["shares"].array[i]);
        }
        return s;
    }

    /// Number from JSON, accepting integers and floats.
    private static float num(const JSONValue v)
    {
        return v.type == JSONType.float_ ? v.floating : v.integer;
    }
}

/// Debugger layout: source left, breakpoints and watch stacked over memory on the right.
private DockSpace sample()
{
    return new DockSpace(DockNode.split(false,
        DockNode.stack("source"),
        DockNode.split(true, DockNode.stack("breakpoints", "watch"), DockNode.stack("memory"))));
}

/// Layout, hit testing and drop zones.
unittest
{
    DockSpace d = sample();
    d.layout(Rect(0, 0, 1004, 604));
    DockNode memory = d.find("memory");
    assert(d.find("source").rect == Rect(0, 0, 500, 604));
    assert(d.find("watch").rect == Rect(504, 0, 500, 300));
    assert(memory.rect == Rect(504, 304, 500, 300));
    assert(d.stackAt(Point(700, 400)) is memory);
    assert(DockSpace.zoneAt(memory, Point(754, 454)) == Zone.center);
    assert(DockSpace.zoneAt(memory, Point(990, 454)) == Zone.right);
    assert(DockSpace.zoneAt(memory, Point(754, 310)) == Zone.top);
    assert(DockSpace.preview(memory, Zone.right) == Rect(754, 304, 250, 300));
}

/// Docking to an edge splits, docking to the center joins, empty stacks disappear.
unittest
{
    DockSpace d = sample();
    d.layout(Rect(0, 0, 1004, 604));
    d.dock("watch", d.find("memory"), Zone.right);
    assert(d.find("breakpoints").panes == ["breakpoints"]);
    DockNode watch = d.find("watch");
    assert(watch.parent.vertical == false && watch.parent.children[0] is d.find("memory"));

    d.dock("breakpoints", d.find("source"), Zone.center);
    assert(d.find("source").panes == ["source", "breakpoints"]);
    assert(d.find("source").active == 1);
    assert(d.root.vertical == false && d.root.children.length == 3,
        "vertical split collapsed, then flattened into the root row");
    float total = 0;
    foreach (float s; d.root.shares)
    {
        total += s;
    }
    assert(total == 2, "the right column's share was divided among its children");
}

/// Floating windows and a save/restore round trip.
unittest
{
    DockSpace d = sample();
    d.undock("memory", Rect(100, 100, 400, 300));
    assert(d.floating.length == 1 && d.root.children.length == 2);
    string saved = d.save().toString;
    DockSpace back = DockSpace.restore(parseJSON(saved));
    assert(back.save().toString == saved);
    assert(back.find("memory") !is null);
    back.layout(Rect(0, 0, 1000, 600));
    assert(back.stackAt(Point(150, 150)) is back.find("memory"), "floating window on top");
    back.dock("memory", back.find("source"), Zone.bottom);
    assert(back.floating.length == 0, "empty window closed");
}
