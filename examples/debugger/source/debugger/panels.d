/// Retained panels of the debugger: commands, menu bar, tool bar, breakpoints, registers and status bar.
///
/// Components are functions returning nodes. They run once, and effects bind
/// signals to node properties. Each loop body that makes closures calls a helper
/// function, because closures made directly in a loop body share one frame.
module debugger.panels;

import debugger.backend;
import debugger.model;
import dentrite.command;
import dentrite.containers;
import dentrite.node;
import dentrite.signals;
import dentrite.widgets.button;
import dentrite.widgets.checkbox;
import dentrite.widgets.combobox;
import dentrite.widgets.icons;
import dentrite.widgets.label;
import dentrite.widgets.list;
import dentrite.widgets.menu;
import dentrite.widgets.tooltip : commandTip;
import std.algorithm.iteration : filter;
import std.algorithm.searching : canFind;
import std.array : array;
import std.format : format;
import std.string : capitalize, toLower;

/// True if `b` matches filter text `q`: file name, "file:line" or address, case-insensitive.
bool matches(Breakpoint b, string q)
{
    if (q.length == 0)
    {
        return true;
    }
    string lq = q.toLower;
    return canFind(format("%s:%d", b.file, b.line).toLower, lq) || canFind(format("%x", b.addr), lq);
}

/// Commands shared by the menu bar, the tool bar and their shortcuts.
struct DebugCommands
{
    Command run;            /// continue or pause, F5
    Command step;           /// step over, F10
    Command[] add;          /// add 1, 100 or 500 random breakpoints
    Command removeDisabled; /// drop the disabled breakpoints
}

/// Debugger commands over `s` and `be`.
DebugCommands debugCommands(Session s, Backend be)
{
    DebugCommands c;
    c.run = command("&Running", () {
        s.running.set(s.running.peek == false);
        be.setRunning(s.running.peek);
    }, keys: "F5", checked: &s.running.get);
    c.step = command("&Step", () { be.step(); }, keys: "F10", icon: Icon.stepOver,
        enabled: () => s.running.get == false);
    c.add = [addCommand(s, 1), addCommand(s, 100), addCommand(s, 500)];
    c.removeDisabled = command("&Remove disabled", &s.removeDisabled, enabled: &s.anyDisabled);
    return c;
}

/// Command adding `n` random breakpoints.
private Command addCommand(Session s, size_t n)
{
    return command(format(n == 1 ? "&%d breakpoint" : "&%d breakpoints", n), () { s.addRandom(n); });
}

/// Tool bar: run or pause, step, a menu adding breakpoints, target state and hit rate.
Node toolbar(Session s, DebugCommands c)
{
    Button run = button("Pause", onClick: () { c.run.run(); }, icon: Icon.pause, variant: "toolbar");
    effect(() {
        bool on = s.running.get;
        run.setCaption(on ? "Pause" : "Run");
        run.setIcon(on ? Icon.pause : Icon.play);
        run.setTooltip(format("%s (%s)", on ? "Pause" : "Run", c.run.keys));
    });
    Label state = label(() => s.running.get ? "Running" : "Paused");
    effect(() { state.setVariant(s.running.get ? "accent" : "warn"); });
    return panel(variant: "toolbar")(row(gap: 2)(
        run,
        button("Step", onClick: () { c.step.run(); }, icon: Icon.stepOver, variant: "toolbar",
            enabled: &c.step.isEnabled, tooltip: commandTip(c.step)),
        pad(x: 6, y: 0)(vrule()),
        addMenu(c),
        pad(x: 6, y: 0)(vrule()),
        state,
        spacer(),
        label(() => format("%,d hits/s", s.hitRate.get), "muted", tooltip: "Breakpoint hits per second"),
        sized(w: 8)(new Fixed(Size.init)),
    ));
}

/// Tool bar button toggling a menu of the add commands below it.
Node addMenu(DebugCommands c)
{
    Button add = button("Add", icon: Icon.plus, variant: "toolbar", tooltip: "Add random breakpoints");
    Menu m = popupMenu(menuItem(c.add[0]), menuItem(c.add[1]), menuItem(c.add[2]));
    add.onClick = () { m.toggle(add); };
    return add;
}

/// Menu bar: quitting, the theme and the layout, plus the debugger commands.
MenuBar menus(DebugCommands c, void delegate() quit, void delegate() reloadTheme, void delegate() resetLayout)
{
    return menuBar(
        menu("&File")(menuItem("&Quit", quit, keys: "Ctrl+Q")),
        menu("&Debug")(
            menuItem(c.run),
            menuItem(c.step),
            menuSeparator(),
            menu("&Add breakpoints")(menuItem(c.add[0]), menuItem(c.add[1]), menuItem(c.add[2])),
            menuItem(c.removeDisabled),
        ),
        menu("&View")(menuItem("Reload &theme", reloadTheme, keys: "Ctrl+R"), menuItem("Reset &layout", resetLayout)),
    );
}

/// Breakpoints shown by state.
enum Show
{
    all,      /// every breakpoint
    enabled,  /// enabled ones
    disabled, /// disabled ones
}

/// Breakpoints panel: filter box suggesting source files, state choice, virtual rows with live hit counts,
/// summary and "Remove disabled".
Node breakpointsPanel(Session s)
{
    Signal!string query = signal("");
    Signal!Show state = signal(Show.all);
    Computed!(Breakpoint[]) shown = computed(() {
        string q = query.get;
        Show st = state.get;
        return s.breakpoints.get.filter!(b => matches(b, q)
            && (st == Show.all || b.enabled.get == (st == Show.enabled))).array;
    });
    Computed!string summary = computed(() => format("%d of %d shown", shown.get.length, s.breakpoints.get.length));
    VirtualList!(uint, Breakpoint) rows = virtualList!(uint, Breakpoint)(items: () => shown.get,
        key: (Breakpoint b) => b.id, row: (Breakpoint delegate() b) => breakpointRow(s, b), selected: s.selected);
    return column()(
        panel(variant: "header")(row(gap: 6)(
            expanded(comboBox(Program.files.dup, query, editable: true,
                placeholder: "Filter by file, line or address")),
            comboBox(state, label: (Show v) => capitalize(format("%s", v)),
                tooltip: "Show all, enabled or disabled breakpoints"),
        )),
        expanded(panel(variant: "pane")(scroll()(rows))),
        panel(variant: "status")(row(gap: 8)(
            label(&summary.get, "muted"),
            spacer(),
            button("Remove disabled", onClick: &s.removeDisabled, variant: "danger", enabled: &s.anyDisabled),
        )),
    );
}

/// One breakpoint row: enabled checkbox, location, address and hit count, and a context menu. `b` returns the
/// row's current breakpoint.
Node breakpointRow(Session s, Breakpoint delegate() b)
{
    return contextMenu(
        menuItem("&Enabled", () { b().enabled.set(b().enabled.peek == false); }, checked: () => b().enabled.get),
        menuItem("&Remove", () { s.remove(b()); }, keys: "Delete"),
    )(listItem(onClick: () { s.selected.set(b().id); }, selected: () => s.selected.get == b().id)(
        row(gap: 8)(
            checkbox(() => b().enabled),
            expanded(label(() => format("%s:%d", b().file, b().line))),
            label(() => format("%08X", b().addr), "monoMuted"),
            sized(w: 64)(label(() => format("%,d", b().hits.get), "mono", align_: TextAlign.end)),
        )));
}

/// Registers panel: one row per register, values turn amber when they change.
Node registersPanel(Session s)
{
    Node[] rows;
    foreach (size_t i; 0 .. registerNames.length)
    {
        rows ~= registerRow(s, i);
    }
    return panel(variant: "pane")(scroll()(pad(x: 10, y: 6)(column(gap: 1)(rows))));
}

/// Name and value of register `i`.
private Node registerRow(Session s, size_t i)
{
    Label value = label("", "mono");
    ulong last;
    bool seen;
    effect(() {
        ulong v = s.registers[i].get;
        value.setText(format("%016X", v));
        value.setVariant(seen && v != last ? "changed" : "mono");
        last = v;
        seen = true;
    });
    return row(gap: 12)(sized(w: 48)(label(registerNames[i], "monoMuted")), value);
}

/// Status bar text, set by the app from frame statistics.
Node statusBar(Signal!string left, Signal!string right)
{
    return panel(variant: "status")(row(gap: 8)(label(&left.get, "muted"), spacer(), label(&right.get, "muted")));
}

/// Filtering by file, line or address, case-insensitive.
unittest
{
    Breakpoint b = new Breakpoint(1, SourceLoc("Parser.d", 99), 0x401a2c);
    assert(matches(b, "parser"));
    assert(matches(b, "r.d:99"));
    assert(matches(b, "1a2c"));
    assert(matches(b, "lexer") == false);
}
