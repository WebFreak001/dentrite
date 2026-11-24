/// Chapter 3: rows, columns, grids, stacks, padding, sizes, panels and scrolling.
module guide.layout;

import dentrite.containers;
import dentrite.host : Host;
import dentrite.node;
import dentrite.signals;
import dentrite.widgets.button;
import dentrite.widgets.icons;
import dentrite.widgets.label;
import dentrite.widgets.splitview;
import dentrite.widgets.textbox;
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

/// Search bar with a caption and a button when given 500 px or more, the text box alone otherwise.
Node searchBar(Signal!string query)
{
    return squeeze()(
        fits(minW: 500)(row(gap: 6)(label("Search"), expanded(textBox(query)), button("Go"))),
        textBox(query),
    );
}

/// Folders beside the open folder, one at a time below 500 px. Choosing a folder shows it when collapsed.
Node mail(Signal!string folder)
{
    Signal!bool shown = signal(true);
    Node side = column(cross: CrossAlign.start)(
        button("Inbox", () { folder.set("Inbox"); shown.set(false); }),
        button("Sent", () { folder.set("Sent"); shown.set(false); }),
    );
    Node content = pad(all: 12)(label(() => folder.get));
    return splitView(shown, minW: 500, sideW: 160)(side, content);
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

/// The search bar drops its caption and button below 500 px, focus inside them is dropped, and
/// the same text box comes back with the text typed meanwhile.
unittest
{
    import dentrite.access : Role;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.platform : Event, EventKind, Metrics;
    import guide.harness;

    Host h = testHost(600, 100);
    scope (exit)
    {
        h.close();
    }
    void resize(int w)
    {
        (cast(HeadlessPlatform) h.platform).size = Metrics(w, 100, 1);
        Event e = Event(EventKind.resized);
        h.handle(e);
        h.frame();
    }

    Signal!string query = signal("");
    scope Scope s = effectScope(() { h.setRoot(searchBar(query)); });
    h.frame();
    TextBox wide = cast(TextBox) h.tree.content.children[0].children[0].children[1].children[0];
    h.setFocus(wide);
    assert(h.shows(Role.button, "Go"));
    resize(499);
    assert(h.shows(Role.button, "Go") == false);
    assert(h.focused is null);
    query.set("dentrite");
    resize(500);
    assert(h.shows(Role.button, "Go"));
    assert(h.tree.content.children[0].children[0].children[1].children[0] is wide && wide.text == "dentrite");
}

/// Below 500 px the folders show alone, choosing one shows it with a back button, and the back button returns.
unittest
{
    import dentrite.access : Role;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.platform : Event, EventKind, Metrics;
    import guide.harness;

    Host h = testHost(600, 300);
    scope (exit)
    {
        h.close();
    }
    Signal!string folder = signal("Inbox");
    scope Scope s = effectScope(() { h.setRoot(mail(folder)); });
    h.frame();
    assert(h.shows(Role.button, "Sent") && h.shows(Role.label, "Inbox"));
    (cast(HeadlessPlatform) h.platform).size = Metrics(400, 300, 1);
    Event e = Event(EventKind.resized);
    h.handle(e);
    h.frame();
    assert(h.shows(Role.button, "Sent") && h.shows(Role.label, "Inbox") == false);
    h.click(Role.button, "Sent");
    h.frame();
    assert(folder.peek == "Sent" && h.shows(Role.button, "Back") && h.shows(Role.button, "Sent") == false);
    h.click(Role.button, "Back");
    h.frame();
    assert(h.shows(Role.button, "Sent"));
}
