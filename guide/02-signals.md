# 2. Signals

State lives in signals. Nodes are built once and bound to signals, so a
change updates the nodes that show it and nothing else. There is no
rebuild-on-change step and no virtual tree to diff.

## Signals, computed values, effects

<!-- src="examples/source/guide/signals.d" from="/// Signals, a computed value and an effect." -->
```d
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
```

- `get` reads and subscribes the running effect or computed value. `peek`
  reads without subscribing. Inside event handlers, use `peek`.
- `set` with an equal value does nothing. Classes compare by identity, the
  rest by `!=`, so setting an array with the same contents is no change.
- A `computed` runs when first read and again only after a dependency
  changed. It is the place for derived data such as a filtered list.
- An `effect` runs once at once, then again after anything it read
  changes. Effects run synchronously inside `set`.

## Batching and untracked reads

<!-- src="examples/source/guide/signals.d" from="/// `peek` reads without subscribing" -->
```d
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
```

Wrap related `set` calls in `batch` so views never see half an update.
`untracked(() => expr)` evaluates an expression without subscribing, like
`peek` for a whole block, and returns the block's value if it has one.

## Bindings in builders

Most builder options that change at run time take a delegate: `label(() =>
...)`, `enabled: () => ...`, `selected: () => ...`. The builder wraps it in
an effect. A member function works as a delegate too, `label(&greeting.get)`:

<!-- src="examples/source/guide/signals.d" from="Node profile()" -->
```d
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
```

Editing widgets take the signal itself: `textBox(name)` reads and writes
`name`, as do `checkbox`, `slider`, `comboBox` and the rest. Two widgets on
one signal stay in step.

`accessName:` names the box for screen readers, since a placeholder is not
a name. Tests find nodes by that name too, see [chapter 11](11-testing.md).

For a property without a binding option, write the effect yourself next to
the node:

<!-- src="examples/source/guide/signals.d" from="Node temperature(" -->
```d
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
```

## Owners

Every effect belongs to the owner that was current when it was made: the
`effectScope` around the builder, or the effect whose body made it.
Disposing an owner disposes everything it owns.

<!-- src="examples/source/guide/signals.d" from="/// Effects belong to the owner current" -->
```d
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
```

So build the window inside one `effectScope` and keep the scope alive as
long as the window (chapter 1 does this with `scope Scope root`). A builder
run with no owner current still works, but its bindings are never disposed.

## Content that changes shape

To swap a subtree when a signal changes, build the new content inside an
effect. The effect owns what the builders make, and disposes it before it
runs again, so the old subtree's bindings stop:

<!-- src="examples/source/guide/signals.d" from="Node details(" -->
```d
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
```

The `untracked` block keeps the builders' own reads from subscribing the
outer effect. Without it, a builder that calls `get` outside its bindings
would rebuild the pane whenever that signal changes.

Rebuilding drops the old nodes' state, such as a text box's caret. To keep
pages alive, build them all once and only switch which one is attached, as
the gallery's shell does. For lists of items, use the keyed lists of
[chapter 5](05-collections.md), which keep the rows whose key survives.

## Closures in loops

D closures made directly in a loop body share one frame, so they all see
the last iteration:

<!-- src="examples/source/guide/signals.d" from="/// Closures made directly in a loop body" -->
```d
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
```

Builders capture closures all the time, so a loop that builds rows calls a
function per row. The function call gives each row its own frame:

<!-- src="examples/source/guide/signals.d" from="Node switches(" -->
```d
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
```
