/// Chapter 1: a counter, the smallest app with state.
module guide.counter;

import dentrite.containers;
import dentrite.node;
import dentrite.signals;
import dentrite.widgets.button;
import dentrite.widgets.label;
import std.format : format;

/// Counter: a label showing the count and buttons changing it.
Node counter()
{
    Signal!int count = signal(0);
    return pad(all: 16)(column(gap: 8, cross: CrossAlign.start)(
        label(() => format("Count: %d", count.get)),
        row(gap: 8)(
            button("Add one", onClick: () { count.set(count.peek + 1); }, variant: "primary"),
            button("Reset", onClick: () { count.set(0); }, enabled: () => count.get > 0),
        ),
    ));
}

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
