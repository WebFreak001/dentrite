# 11. Testing

`dentrite:core` runs without a window: `HeadlessPlatform` stands in for
SDL, and `SoftwareRenderer` draws on the CPU. A `Host` over them runs the
same input routing, layout and paint as a window, so unittests drive the
real UI.

## A headless host

The guide's tests share a small harness:

<!-- src="examples/source/guide/harness.d" from="Host testHost(" -->
```d
/// Headless host of `w` by `h` logical pixels, drawing in software, with the theme file `themePath` if given.
/// Close it when done.
Host testHost(int w = 400, int h = 300, string themePath = null)
{
    WindowOptions o;
    o.fonts = guideFonts;
    o.themePath = themePath;
    o.checkTheme = (Theme t) { t.check!GuideStyles(); };
    return new Host(new HeadlessPlatform(w, h), new SoftwareRenderer, o);
}
```

Fonts load relative to the working directory, which is the package
directory under `dub test`. Close the host at the end of the test.

## Finding nodes

Tests that walk `children[1].children[0]` break with every layout change.
Find nodes the way a screen reader does instead, by role and name:

- `h.find(role, name)` gives the node a screen reader would see, with its
  window `bounds`, or null.
- `h.click(role, name)` clicks its middle and renders a frame.

The harness adds one helper on top:

<!-- src="examples/source/guide/harness.d" from="bool shows(" -->
```d
/// True if a node with `role` and `name` is shown, as a screen reader would see it after the last frame.
bool shows(Host h, Role role, string name)
{
    return h.find(role, name) !is null;
}
```

`find` reads the tree as the last frame laid it out, so render a frame
after changes. A node without a caption needs an `accessName` to be found,
which is what a screen reader needs anyway. Rows of lists and tables are
named by their labels joined, such as `"info Message number 2"`, and rows
scrolled out of view are not found.

A test then reads like a user session:

<!-- src="examples/source/guide/counter.d" from="/// Clicking" -->
```d
/// Clicking "Add one" updates the label and enables "Reset".
unittest
{
    import dentrite.host : Host;
    import guide.harness;

    Host h = testHost();
    scope (exit)
    {
        h.close();
    }
    scope Scope root = effectScope(() { h.setRoot(counter()); });
    h.frame();
    assert(shows(h, Role.label, "Count: 0"));
    h.click(Role.button, "Add one");
    h.click(Role.button, "Add one");
    assert(shows(h, Role.label, "Count: 2"));
    h.click(Role.button, "Reset");
    assert(shows(h, Role.label, "Count: 0"));
}
```

## Input

- `inject(PointerKind, Point, clicks, button, mods)` sends pointer events.
- `injectKey(key, mods)` sends a key to the focused node, then its
  parents, then the window's shortcuts: `injectKey('s', Mod.ctrl)`.
- `injectText("...")` types into the focused node.
- `injectWheel(point, dy)` scrolls.
- `setFocus(node)` moves focus directly.

Each changes signals at once, through the same handlers as real input.
Call `frame()` before checking anything laid out or painted.

`dentrite.script` runs scripted steps, the same ones the examples take on
the command line with `--script`. `settle(host, n)` renders `n` frames 16 ms
apart, so timers, animations and posts from other threads move on:

<!-- src="examples/source/guide/testing.d" from="/// Keys reach the focused node" -->
```d
/// Keys reach the focused node, Tab moves focus, and a script drives the pointer by coordinates.
unittest
{
    import dentrite.script : runScript;

    Host h = testHost();
    scope (exit)
    {
        h.close();
    }
    scope Scope root = effectScope(() { h.setRoot(counter()); });
    h.frame();
    h.injectKey(Key.tab);
    h.injectKey(Key.enter);
    h.frame();
    assert(shows(h, Role.label, "Count: 1"));
    Rect add = h.find(Role.button, "Add one").bounds;
    runScript(h, "click:" ~ coords(add) ~ "; click:" ~ coords(add));
    assert(shows(h, Role.label, "Count: 3"));
}
```

## Screenshots

Set `screenshotPath` and the next frame writes a PNG. Comparing shots
before and after a change finds paint regressions, as the gallery's
`--shots` does with `magick compare -metric AE`:

<!-- src="examples/source/guide/testing.d" from="/// A headless frame writes a screenshot" -->
```d
/// A headless frame writes a screenshot, for comparing paint before and after a change.
unittest
{
    import std.file : exists, remove, tempDir;
    import std.path : buildPath;

    Host h = testHost(200, 100, "themes/dark.theme");
    scope (exit)
    {
        h.close();
    }
    scope Scope root = effectScope(() { h.setRoot(counter()); });
    string path = buildPath(tempDir, "dentrite-guide-counter.png");
    h.frame();
    h.screenshotPath = path;
    h.requestFrame();
    h.frame();
    assert(exists(path));
    remove(path);
}
```

In a running window, F12 writes a screenshot to the working directory.
