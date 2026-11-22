/// Chapter 2: signals, computed values, effects, owners, and content that changes shape.
module guide.signals;

import dentrite.containers;
import dentrite.node;
import dentrite.signals;
import dentrite.widgets.checkbox;
import dentrite.widgets.label;
import dentrite.widgets.textbox;
import std.format : format;

/// Signals, a computed value and an effect.
unittest
{
    Signal!string first = signal("Ada");
    Signal!string last = signal("Lovelace");
    Computed!string full = computed(() => first.get ~ " " ~ last.get);
    string[] seen;
    Effect e = effect(() { seen ~= full.get; });
    assert(seen == ["Ada Lovelace"]);
    last.set("Byron");
    assert(seen == ["Ada Lovelace", "Ada Byron"]);
    last.set("Byron");
    assert(seen.length == 2, "an equal value changes nothing");
    e.dispose();
}

/// `peek` reads without subscribing, `batch` runs effects once at its end.
unittest
{
    Signal!int a = signal(1);
    Signal!int b = signal(2);
    int runs;
    Effect e = effect(() {
        ++runs;
        a.get;
        b.peek;
    });
    b.set(3);
    assert(runs == 1, "b was peeked, so changing it does not re-run");
    batch(() {
        a.set(10);
        a.set(11);
        b.set(4);
    });
    assert(runs == 2, "one run for the whole batch");
    e.dispose();
}

/// Effects belong to the owner current when they are made. Disposing the owner stops them.
unittest
{
    Signal!int n = signal(0);
    int seen;
    Scope s = effectScope(() {
        effect(() { seen = n.get; });
    });
    n.set(1);
    assert(seen == 1);
    s.dispose();
    n.set(2);
    assert(seen == 1, "disposed with its scope");
}

/// Profile form: a text box and a check box bound to signals, with labels derived from them.
Node profile()
{
    Signal!string name = signal("");
    Signal!bool admin = signal(false);
    Computed!string greeting = computed(() => name.get.length == 0 ? "Who are you?" : "Hello, " ~ name.get);
    return column(gap: 8)(
        textBox(name, placeholder: "Your name", accessName: "Name"),
        checkbox(admin, "Administrator"),
        label(&greeting.get),
        label(() => admin.get ? "Can change settings" : "Read only", "muted"),
    );
}

/// Typing into the box updates the greeting, the check box updates the other label.
unittest
{
    import dentrite.host : Host;
    import guide.harness;

    Host h = testHost();
    scope (exit)
    {
        h.close();
    }
    scope Scope root = effectScope(() { h.setRoot(profile()); });
    h.frame();
    assert(shows(h, Role.label, "Who are you?"));
    h.click(Role.textInput, "Name");
    h.injectText("Ada");
    h.frame();
    assert(shows(h, Role.label, "Hello, Ada"));
    h.click(Role.checkBox, "Administrator");
    assert(shows(h, Role.label, "Can change settings"));
}

/// Effects binding node properties in a builder, for what has no binding parameter.
Node temperature(Signal!double celsius)
{
    Label value = label("", "mono");
    effect(() {
        double c = celsius.get;
        value.setText(format("%.1f °C", c));
        value.setVariant(c > 30 ? "warn" : "mono");
    });
    return row(gap: 8)(label("Temperature"), value);
}

/// The effect follows the signal.
unittest
{
    Signal!double c = signal(21.0);
    Node n;
    scope Scope s = effectScope(() { n = temperature(c); });
    Label v = cast(Label) n.children[1];
    assert(v.text == "21.0 °C" && v.variant == "mono");
    c.set(35);
    assert(v.text == "35.0 °C" && v.variant == "warn");
}

/// Views of the details pane.
enum View
{
    summary, /// one line
    full,    /// every field
}

/// Pane whose content is built again when `view` changes. The builders' effects belong to the effect, which
/// disposes them before it runs again.
Node details(Signal!View view, Signal!string name)
{
    Flex holder = column()();
    effect(() {
        View v = view.get;
        untracked(() {
            holder.setChildren([v == View.summary ? summaryOf(name) : fullOf(name)]);
        });
    });
    return holder;
}

/// One line about `name`.
Node summaryOf(Signal!string name)
{
    return label(() => name.get);
}

/// Every field of `name`.
Node fullOf(Signal!string name)
{
    return column(gap: 4)(label("Name", "muted"), label(() => name.get), label(() => format("%d letters",
        name.get.length), "muted"));
}

/// Switching views rebuilds the pane and stops the old view's bindings.
unittest
{
    Signal!View view = signal(View.summary);
    Signal!string name = signal("Ada");
    Node n;
    scope Scope s = effectScope(() { n = details(view, name); });
    Label line = cast(Label) n.children[0];
    view.set(View.full);
    assert(n.children[0] !is line, "rebuilt");
    name.set("Grace");
    assert(line.text == "Ada", "the old label's binding was disposed");
    assert((cast(Label) n.children[0].children[1]).text == "Grace");
}

/// Rows made in a loop. Each row is built by a function, so each gets its own closure frame.
Node switches(string[] names, Signal!bool[] values)
{
    Node[] rows;
    foreach (size_t i, string n; names)
    {
        rows ~= switchRow(n, values[i]);
    }
    return column(gap: 4)(rows);
}

/// Check box for `value` with a label repeating its state.
Node switchRow(string name, Signal!bool value)
{
    return row(gap: 8)(checkbox(value, name), label(() => value.get ? "on" : "off", "muted"));
}

/// Closures made directly in a loop body share the body's frame, so they all see the last iteration.
unittest
{
    int delegate()[] direct;
    foreach (int i; 0 .. 3)
    {
        direct ~= () => i;
    }
    assert(direct[0]() == 2);
    Signal!bool[] values = [signal(true), signal(false)];
    Node n;
    scope Scope s = effectScope(() { n = switches(["Wrap", "Spell check"], values); });
    assert((cast(Label) n.children[0].children[1]).text == "on");
    assert((cast(Label) n.children[1].children[1]).text == "off");
}
