/// Gallery window contents: menu bar, page list and the current page.
module gallery.shell;

import dentrite.access : AccessNode, AccessUpdate;
import dentrite.containers;
import dentrite.host : Host;
import dentrite.node;
import dentrite.signals;
import dentrite.theme : Theme;
import dentrite.widgets.label;
import dentrite.widgets.list : listItem;
import dentrite.widgets.menu;
import gallery.pages;
import std.algorithm.searching : canFind;
import std.string : join, split, toLower;

/// Gallery window contents: menu bar, page list, and the page `current` selects. Pages are built once.
Node galleryUi(Host w, Gallery g, Page[] ps, Signal!size_t current)
{
    Node[] built;
    Node[] items;
    foreach (size_t i, Page p; ps)
    {
        built ~= expanded(pageView(p));
        items ~= sideItem(current, i, p.name);
    }
    Flex holder = column()();
    effect(() { holder.setChildren([built[current.get]]); });
    return column()(
        menus(w, g),
        expanded(row(cross: CrossAlign.stretch)(
            sized(w: 170)(panel(variant: "pane")(scroll()(pad(x: 0, y: 8)(column()(items))))),
            vrule(),
            expanded(holder),
        )),
    );
}

/// Page list row selecting page `i`.
Node sideItem(Signal!size_t current, size_t i, string name)
{
    return listItem(onClick: () { current.set(i); }, selected: () => current.get == i)(label(name));
}

/// Menu bar: items that show up as the last action on the Menus page, word wrap, theme reload and quitting.
MenuBar menus(Host w, Gallery g)
{
    return menuBar(
        menu("&File")(
            menuItem("&New", g.note("New"), keys: "Ctrl+N"),
            menuItem("&Open", g.note("Open"), keys: "Ctrl+O"),
            menu("Open &recent")(menuItem("&1 notes.txt", g.note("Open notes.txt")),
                menuItem("&2 todo.md", g.note("Open todo.md"))),
            menuSeparator(),
            menuItem("&Quit", () { w.running = false; }, keys: "Ctrl+Q"),
        ),
        menu("&Edit")(
            menuItem("&Undo", g.note("Undo"), keys: "Ctrl+Z", enabled: () => false),
            menuSeparator(),
            menuItem("Cu&t", g.note("Cut"), keys: "Ctrl+X"),
            menuItem("&Copy", g.note("Copy"), keys: "Ctrl+C"),
            menuItem("&Paste", g.note("Paste"), keys: "Ctrl+V"),
        ),
        menu("&View")(
            menuItem("&Word wrap", () { g.wrap.set(g.wrap.peek == false); }, checked: &g.wrap.get),
            menuSeparator(),
            menuItem("Reload &theme", &w.reloadTheme, keys: "Ctrl+R"),
        ),
    );
}

/// File name for page `name`: lower case, spaces as dashes.
string fileName(string name)
{
    return name.toLower.split(" ").join("-");
}

/// Page file names.
unittest
{
    assert(fileName("Check boxes") == "check-boxes" && fileName("Dock") == "dock");
}

/// Every page builds, lays out and paints with the theme, and switching pages swaps the content.
unittest
{
    import dentrite.backend.software : SoftwareRenderer;
    import dentrite.headless : HeadlessPlatform;
    import dentrite.platform : WindowOptions;

    WindowOptions o;
    o.fonts = ["../../fonts/Inter-Regular.otf", "../../fonts/Inter-SemiBold.otf",
        "../../fonts/JetBrainsMono-Regular.ttf"];
    o.themePath = "themes/dark.theme";
    o.checkTheme = (Theme t) { t.check!GalleryStyles(); };
    Host h = new Host(new HeadlessPlatform(1100, 760), new SoftwareRenderer, o);
    scope (exit)
    {
        h.close();
    }
    Gallery g = new Gallery(h);
    Page[] ps = pages(g);
    Signal!size_t current = signal(size_t(0));
    scope Scope root = effectScope(() { h.setRoot(galleryUi(h, g, ps, current)); });
    /// Titles of the title labels in the tree under `n` with a size.
    string[] titles(Node n)
    {
        string[] ts;
        Label l = cast(Label) n;
        if (l !is null && l.variant == "title" && l.size.w > 0)
        {
            ts ~= l.text;
        }
        foreach (Node c; n.children)
        {
            ts ~= titles(c);
        }
        return ts;
    }

    foreach (size_t i, Page p; ps)
    {
        current.set(i);
        h.frame();
        string[] ts = titles(h.tree.content);
        assert(ts.length > 0 && ts[0] == p.name, p.name);
        foreach (Page q; ps)
        {
            assert(q.name == p.name || canFind(ts, q.name) == false, "page left attached: " ~ q.name);
        }
        AccessUpdate u = h.access.update(h.tree, h.focused, true);
        bool[ulong] exposed;
        foreach (ref AccessNode a; u.nodes)
        {
            exposed[a.id] = true;
        }
        /// Asserts that every shown focusable node under `n` is exposed, or inside a node that is.
        void check(Node n)
        {
            if (n.focusable && n.size.w > 0)
            {
                Node e = n;
                while (e !is null && (e.accessId in exposed) is null)
                {
                    e = e.parent;
                }
                assert(e !is null, p.name ~ ": focusable " ~ typeid(n).name ~ " is not exposed");
            }
            foreach (Node c; n.children)
            {
                check(c);
            }
        }

        check(h.tree.root);
    }
}
