/// Chapter 3: rows, columns, grids, stacks, padding, sizes, panels and scrolling.
module guide.layout;

import dentrite.containers;
import dentrite.host : Host;
import dentrite.node;
import dentrite.signals;
import dentrite.widgets.button;
import dentrite.widgets.icons;
import dentrite.widgets.label;
import std.format : format;

/// Window shell: a tool bar, a sidebar of fixed width, scrolling content and a status bar.
Node shell()
{
    Node[] lines;
    foreach (int i; 1 .. 61)
    {
        lines ~= label(format("Line %d", i));
    }
    return column()(
        panel(variant: "toolbar")(row(gap: 4)(
            button("Open", icon: Icon.plus, variant: "toolbar"),
            button("Run", icon: Icon.play, variant: "toolbar"),
            spacer(),
            label("main.d", "muted"),
        )),
        expanded(row(cross: CrossAlign.stretch)(
            sized(w: 180)(panel(variant: "pane")(pad(all: 8)(column(gap: 4)(
                label("Files", "strong"),
                label("main.d"),
                label("util.d"),
            )))),
            vrule(),
            expanded(scroll()(pad(x: 12, y: 8)(column(gap: 2)(lines)))),
        )),
        panel(variant: "status")(row()(label("Ready", "muted"), spacer(), label("60 lines", "muted"))),
    );
}

/// Tiles at least 120 px wide, as many per row as fit, each a name over a stretched background.
Node tiles(string[] names)
{
    Node[] cells;
    foreach (string n; names)
    {
        cells ~= sized(h: 80)(stack(y: CrossAlign.end)(
            aligned(x: CrossAlign.stretch, y: CrossAlign.stretch)(panel(variant: "popup")(new Fixed(Size.init))),
            pad(all: 8)(label(n)),
        ));
    }
    return grid(minCell: 120, gap: 8)(cells);
}

/// Sidebar beside the content while the window is over 600 px wide, the content alone otherwise. Both are built
/// once and only attached, so they keep their state.
Node adaptive(Host h, Node side, Node content)
{
    Computed!bool narrow = h.breakpoint(maxW: 600);
    Node rule = vrule();
    Node main = expanded(content);
    Flex holder = row(cross: CrossAlign.stretch)();
    effect(() {
        holder.setChildren(narrow.get ? [main] : [side, rule, main]);
    });
    return holder;
}

/// The sidebar keeps its width, the content takes the rest, and the bars stay at the edges.
unittest
{
    import dentrite.host : Host;
    import guide.harness;

    Host h = testHost(800, 600);
    scope (exit)
    {
        h.close();
    }
    h.setRoot(shell());
    h.frame();
    Node root = h.tree.content;
    Node middle = root.children[1];
    Node side = middle.children[0].children[0];
    Node content = middle.children[0].children[2];
    Node status = root.children[2];
    assert(side.size.w == 180 && side.size.h == middle.size.h);
    assert(content.bounds.right == 800);
    assert(status.bounds.bottom == 600);
    assert(root.children[0].size.h + middle.size.h + status.size.h == 600);
}

/// Shares of the width: flex 1, 2 and 1, with fixed parts left alone.
unittest
{
    import dentrite.host : Host;
    import guide.harness;

    Host h = testHost(444, 100);
    scope (exit)
    {
        h.close();
    }
    h.setRoot(row(gap: 4)(sized(w: 32)(spacer()), expanded(spacer()), expanded(spacer(), 2), expanded(spacer())));
    h.frame();
    Node r = h.tree.content;
    assert(r.children[1].size.w == 100 && r.children[2].size.w == 200 && r.children[3].size.w == 100);
}

/// Three 128 px columns fit in 400 px, and each name sits at the bottom of its tile.
unittest
{
    import dentrite.host : Host;
    import guide.harness;

    Host h = testHost(400, 300);
    scope (exit)
    {
        h.close();
    }
    h.setRoot(column()(tiles(["Docs", "Music", "Photos", "Videos"])));
    h.frame();
    Node g = h.tree.content.children[0];
    assert(g.children[1].bounds == Rect(136, 0, 128, 80));
    assert(g.children[3].bounds == Rect(0, 88, 128, 80), "fourth tile starts the second row");
    Node name = g.children[0].children[0].children[1];
    assert(name.bounds.bottom == 80);
}

/// The sidebar leaves when the window narrows to 600 px and comes back when it widens.
unittest
{
    import dentrite.headless : HeadlessPlatform;
    import dentrite.platform : Event, EventKind, Metrics;
    import guide.harness;

    Host h = testHost(800, 600);
    scope (exit)
    {
        h.close();
    }
    void resize(int w)
    {
        (cast(HeadlessPlatform) h.platform).size = Metrics(w, 600, 1);
        Event e = Event(EventKind.resized);
        h.handle(e);
        h.frame();
    }

    Node side = sized(w: 180)(label("Files"));
    Node content = label("Text");
    scope Scope s = effectScope(() { h.setRoot(adaptive(h, side, content)); });
    h.frame();
    assert(side.parent !is null && content.bounds.x > 180);
    resize(600);
    assert(side.parent is null && content.bounds.x == 0 && content.size.w == 600);
    resize(700);
    assert(side.parent !is null && content.bounds.x > 180);
}
