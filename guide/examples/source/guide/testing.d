/// Chapter 11: testing a UI headless, by role and name, with scripts and screenshots.
module guide.testing;

import dentrite.host : Host;
import dentrite.node;
import dentrite.signals;
import guide.counter : counter;
import guide.harness;

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

/// Middle of `r` as script coordinates, "X,Y".
string coords(Rect r)
{
    import std.format : format;

    return format("%g,%g", r.x + r.w / 2, r.y + r.h / 2);
}

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
