/// Chapter 3: rows, columns, padding, sizes, panels and scrolling.
module guide.layout;

import dentrite.containers;
import dentrite.node;
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
