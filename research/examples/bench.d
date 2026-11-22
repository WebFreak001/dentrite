/// Headless timings and memory use of the breakpoints panel on paths A1, A2, B, C and D.
///
/// Every path runs the same operations at several list sizes. No path
/// virtualizes, so cost grows with the list, and the smallest size stands in
/// for a virtualized view. Times stop at the command list or laid-out tree.
/// Nothing is rasterized. Build with optimizations, see README.md.
///
/// Each path and size runs in its own process. A heap grown by an earlier path
/// would hide this one's growth and change when its collections happen.
module bench;

static import immediate;
static import panel;
static import panel_ddui;
import ddui;
import hybrid;
import layout;
import signals;
import core.memory : GC;
import core.runtime : CArgs, Runtime;
import core.time : Duration, MonoTime;
import core.volatile : volatileStore;
import std.algorithm.comparison : max, min;
import std.algorithm.iteration : filter, map, splitter;
import std.algorithm.searching : endsWith, findSplitAfter, startsWith;
import std.algorithm.sorting : sort;
import std.array : array;
import std.conv : to;
import std.datetime.date : Date;
import std.datetime.systime : Clock;
import std.exception : enforce;
import std.file : exists, readText, thisExePath;
import std.format : format;
import std.process : spawnProcess, wait;
import std.stdio : File, stdout, writef, writefln, writeln;
import std.string : fromStringz, lineSplitter, splitLines, strip;

/// Source files cycled through by generated breakpoints.
immutable string[4] files = ["main.d", "parser.d", "lexer.d", "eval.d"];

/// Filter text matching a quarter of the generated breakpoints.
enum string query = "main.d";

/// Window size shared by all paths.
enum Size window = Size(400, 300);

/// One path driven through the panel operations.
interface Path
{
    /// Short label, "A1" and so on.
    string name();
    /// Fresh state with `n` breakpoints. Not timed.
    void setup(size_t n);
    /// First frame, or building the retained tree.
    void first();
    /// Pointer moved over the list, nothing changes.
    void pointer();
    /// One hit count went up.
    void oneHit();
    /// Every hit count went up.
    void allHits();
    /// Filter switched on or off, alternating.
    void toggleFilter();
    /// Summary label as currently shown, or null if not drawn.
    string summary();
}

/// Breakpoint `i` of a generated list, as `make(id, file, line)`.
T generated(T)(size_t i, T delegate(uint, string, uint) make)
{
    return make(cast(uint) i + 1, files[i % files.length], cast(uint) (10 + i));
}

/// Fixed-pitch text width for ddui: 8 px per byte.
private extern (C) int width8(mu_Font, const(char)* s, int len)
{
    return 8 * (len < 0 ? cast(int) fromStringz(s).length : len);
}

/// Fixed line height for ddui.
private extern (C) int height16(mu_Font)
{
    return 16;
}

/// Path A1: ddui as it is, plain data, one-pass row layout.
final class A1 : Path
{
    mu_Context* ctx;            /// ddui context
    panel_ddui.PanelState st;   /// application state
    private size_t next;        /// breakpoint for the next `oneHit`
    private bool filtered;      /// filter state
    private int x;              /// pointer x, moves each call
    private size_t commands;    /// commands read back, so the work is not dropped

    /// Label.
    string name()
    {
        return "A1";
    }

    /// New context and `n` breakpoints.
    void setup(size_t n)
    {
        if (ctx !is null)
        {
            mu_destroy(ctx);
        }
        ctx = mu_create();
        ctx.text_width = &width8;
        ctx.text_height = &height16;
        st = panel_ddui.PanelState.init;
        st.items.length = n;
        foreach (size_t i; 0 .. n)
        {
            st.items[i] = generated(i, (uint id, string f, uint l) => panel_ddui.Breakpoint(id, f, l));
        }
        next = 0;
        filtered = false;
    }

    /// One ddui frame, then a walk over the commands as a renderer would.
    private void frame()
    {
        mu_begin(ctx);
        panel_ddui.breakpointsPanel(ctx, st);
        mu_end(ctx);
        mu_Command* cmd = null;
        while (mu_get_next_command(ctx, &cmd))
        {
            ++commands;
        }
    }

    /// First frame.
    void first()
    {
        frame();
    }

    /// Mouse move, then a frame.
    void pointer()
    {
        x = (x + 1) % 50;
        mu_input_mousemove(ctx, 100 + x, 100);
        frame();
    }

    /// Bumps one count, then a frame.
    void oneHit()
    {
        ++st.items[next++ % st.items.length].hits;
        frame();
    }

    /// Bumps every count, then a frame.
    void allHits()
    {
        foreach (ref panel_ddui.Breakpoint b; st.items)
        {
            ++b.hits;
        }
        frame();
    }

    /// Edits the text box buffer, then a frame.
    void toggleFilter()
    {
        filtered = filtered == false;
        st.filter[] = '\0';
        if (filtered)
        {
            st.filter[0 .. query.length] = query;
        }
        frame();
    }

    /// Text drawn last frame ending in " shown".
    string summary()
    {
        mu_Command* cmd = null;
        while (mu_get_next_command(ctx, &cmd))
        {
            if (cmd.type == MU_COMMAND_TEXT && mu_command_text_slice(ctx, cmd).endsWith(" shown"))
            {
                return mu_command_text_slice(ctx, cmd).idup;
            }
        }
        return null;
    }
}

/// The A2 panel with every row behind `memo`, which is path D.
void memoPanel(immediate.Ui ui, ref immediate.Breakpoint[] items, string filter)
{
    // NOTE: here, not at module level, where `row` and `column` would hide layout's
    import immediate : box, button, checkbox, column, expand, label, row;

    ui.row(gap: 4, cross: CrossAlign.center)({
        ui.label("Filter");
        ui.expand({ ui.box(height: 20); });
    });
    size_t shown;
    ui.expand({
        ui.column(cross: CrossAlign.stretch)({
            foreach (ref immediate.Breakpoint bp; items)
            {
                if (filter.length > 0 && bp.file != filter)
                {
                    continue;
                }
                ++shown;
                ui.pushId(bp.id);
                scope (exit)
                {
                    ui.popId();
                }
                ui.memo(bp, {
                    ui.row(gap: 4, cross: CrossAlign.center)({
                        ui.checkbox(bp.enabled, format("%s:%d", bp.file, bp.line));
                        ui.label(format("%d", bp.hits));
                    });
                });
            }
        });
    });
    ui.row(gap: 4, cross: CrossAlign.center)({
        ui.label(format("%d of %d shown", shown, items.length));
        ui.expand({ ui.box(); });
        ui.button("Remove disabled");
    });
}

/// Paths A2 and D: immediate API over a per-frame tree with box-constraint layout.
final class A2 : Path
{
    immediate.Ui ui;                 /// context
    immediate.Breakpoint[] items;    /// application state
    private bool memo;               /// D when set
    private string filterText;       /// current filter
    private size_t next;             /// breakpoint for the next `oneHit`
    private int x;                   /// pointer x, moves each call

    /// Path A2, or D if `memo`.
    this(bool memo)
    {
        this.memo = memo;
    }

    /// Label.
    string name()
    {
        return memo ? "D" : "A2";
    }

    /// New context and `n` breakpoints.
    void setup(size_t n)
    {
        ui = new immediate.Ui;
        items.length = n;
        foreach (size_t i; 0 .. n)
        {
            items[i] = generated(i, (uint id, string f, uint l) => immediate.Breakpoint(id, f, l));
        }
        filterText = null;
        next = 0;
    }

    /// One frame: declare, lay out, record rects, paint.
    private void frame()
    {
        ui.frame({
            if (memo)
            {
                memoPanel(ui, items, filterText);
            }
            else
            {
                immediate.breakpointsPanel(ui, items, filterText);
            }
        }, window);
    }

    /// First frame.
    void first()
    {
        frame();
    }

    /// Pointer move, then a frame.
    void pointer()
    {
        x = (x + 1) % 50;
        ui.mouse = Point(100 + x, 100);
        frame();
    }

    /// Bumps one count, then a frame.
    void oneHit()
    {
        ++items[next++ % items.length].hits;
        frame();
    }

    /// Bumps every count, then a frame.
    void allHits()
    {
        foreach (ref immediate.Breakpoint b; items)
        {
            ++b.hits;
        }
        frame();
    }

    /// Switches the filter, then a frame.
    void toggleFilter()
    {
        filterText = filterText.length > 0 ? null : query;
        frame();
    }

    /// Text drawn last frame ending in " shown".
    string summary()
    {
        foreach (immediate.Drawn d; ui.drawn)
        {
            if (d.text.endsWith(" shown"))
            {
                return d.text;
            }
        }
        return null;
    }
}

/// Path B panel: retained layout nodes, effects keep their text current.
final class RetainedPanel
{
    Signal!(panel.Breakpoint[]) all; /// every breakpoint
    Signal!string query;             /// filter text
    LayoutOwner owner;               /// layout tree and relayout queue
    Scope root;                      /// owns every effect
    panel.KeyedRows!(uint, panel.Breakpoint, Node) rows; /// one row per shown breakpoint
    Text summary;                    /// "N of M shown"
    private Flex list;               /// row container

    /// Builds the panel over `initial`, laid out in `window`.
    this(panel.Breakpoint[] initial)
    {
        list = column(cross: CrossAlign.stretch)();
        summary = new Text("");
        Node tree = pad(all: 8, column(gap: 4, cross: CrossAlign.stretch)(
            row(gap: 4, cross: CrossAlign.center)(new Text("Filter"), expanded(box(h: 20))),
            expanded(list),
            row(gap: 4, cross: CrossAlign.center)(summary, expanded(box()), box(w: 120, h: 24))));
        owner = new LayoutOwner(tree, window);
        root = effectScope(() {
            all = signal(initial);
            query = signal("");
            Computed!(panel.Breakpoint[]) shown = computed(() {
                string q = query.get;
                return all.get.filter!((panel.Breakpoint b) => panel.matches(b, q)).array;
            });
            rows = new panel.KeyedRows!(uint, panel.Breakpoint, Node)(effectScope(() {}),
                (panel.Breakpoint b) => b.id, &makeRow);
            effect(() {
                rows.update(shown.get);
                list.children.length = 0;
                foreach (Node r; rows.ordered)
                {
                    list.add(r);
                }
            });
            effect(() {
                summary.setText(format("%d of %d shown", shown.get.length, all.get.length));
            });
        });
        owner.flush();
    }

    /// Row for `b`, with one effect per changing label.
    private Node makeRow(panel.Breakpoint b)
    {
        string where = format("%s:%d", b.file, b.line);
        Text check = new Text("");
        Text hits = new Text("");
        effect(() { check.setText((b.enabled.get ? "[x] " : "[ ] ") ~ where); });
        effect(() { hits.setText(format("%d", b.hits.get)); });
        return row(gap: 4, cross: CrossAlign.center)(check, hits);
    }
}

/// Text leaves under `n` with window rects, as a full repaint would emit them.
void repaint(Node n, ref immediate.Drawn[] into)
{
    if (Text t = cast(Text) n)
    {
        into ~= immediate.Drawn(t.bounds, t.content);
    }
    foreach (Node c; n.children)
    {
        repaint(c, into);
    }
}

/// Path B: signals into a retained tree. Timed work stops at a laid-out tree.
final class B : Path
{
    panel.Breakpoint[] bps;  /// application state
    RetainedPanel p;         /// the panel
    private size_t next;     /// breakpoint for the next `oneHit`
    private bool filtered;   /// filter state
    private int x;           /// pointer x, moves each call
    private size_t hits;     /// hit-test results, so the work is not dropped

    /// Label.
    string name()
    {
        return "B";
    }

    /// Disposes the panel, which unsubscribes its effects from the breakpoints.
    private void drop()
    {
        if (p !is null)
        {
            p.root.dispose();
            p = null;
        }
    }

    /// Disposes the last panel and makes `n` breakpoints.
    void setup(size_t n)
    {
        drop();
        bps.length = n;
        foreach (size_t i; 0 .. n)
        {
            bps[i] = generated(i, (uint id, string f, uint l) => new panel.Breakpoint(id, f, l));
        }
        next = 0;
        filtered = false;
    }

    /// Builds the tree and its effects, then the first layout. Drops an earlier panel.
    void first()
    {
        drop();
        p = new RetainedPanel(bps);
    }

    /// Hit test only. Nothing reads the pointer, so nothing else runs.
    void pointer()
    {
        x = (x + 1) % 50;
        hits += p.owner.root.hitTest(Point(100 + x, 100)) !is null;
    }

    /// One signal write, its effect, relayout.
    void oneHit()
    {
        panel.Breakpoint b = bps[next++ % bps.length];
        b.hits.set(b.hits.peek + 1);
        p.owner.flush();
    }

    /// Every count in one batch, then relayout.
    void allHits()
    {
        batch(() {
            foreach (panel.Breakpoint b; bps)
            {
                b.hits.set(b.hits.peek + 1);
            }
        });
        p.owner.flush();
    }

    /// Query write, keyed reconcile, relayout.
    void toggleFilter()
    {
        filtered = filtered == false;
        p.query.set(filtered ? query : "");
        p.owner.flush();
    }

    /// Summary label text.
    string summary()
    {
        return p.summary.content;
    }
}

/// Timing summary of one operation.
struct Stat
{
    Duration median; /// typical run
    Duration p99;    /// 99th percentile run
    ulong bytes;     /// GC bytes allocated per run
}

/// Times `runs` calls of `op` after a warm-up. `setup` runs untimed before each call.
Stat measure(int runs, scope void delegate() setup, scope void delegate() op)
{
    foreach (int i; 0 .. 3)
    {
        if (setup !is null)
        {
            setup();
        }
        op();
    }
    Duration[] times = new Duration[runs];
    ulong bytes;
    foreach (int i; 0 .. runs)
    {
        if (setup !is null)
        {
            setup();
        }
        ulong before = GC.allocatedInCurrentThread;
        MonoTime start = MonoTime.currTime;
        op();
        times[i] = MonoTime.currTime - start;
        bytes += GC.allocatedInCurrentThread - before;
    }
    sort(times);
    return Stat(times[runs / 2], times[min(runs - 1, runs * 99 / 100)], bytes / runs);
}

/// Microseconds in `d`, as a float.
double micros(Duration d)
{
    return d.total!"nsecs" / 1000.0;
}

/// Prints one row: path, size, operation, median, p99, KiB.
void report(string path, size_t n, string op, Stat s)
{
    writefln("%-3s %6d  %-9s %10.1f %10.1f %10.1f", path, n, op, micros(s.median), micros(s.p99),
        s.bytes / 1024.0);
    stdout.flush();
}

/// Times every operation of `p` at size `n`.
void run(Path p, size_t n, int runs)
{
    GC.collect();
    size_t collections = GC.profileStats().numCollections;
    report(p.name, n, "first", measure(runs, () { p.setup(n); }, &p.first));
    p.setup(n);
    p.first();
    p.first();
    report(p.name, n, "pointer", measure(runs, null, &p.pointer));
    report(p.name, n, "one hit", measure(runs, null, &p.oneHit));
    report(p.name, n, "all hits", measure(runs, null, &p.allHits));
    report(p.name, n, "filter", measure(runs, null, &p.toggleFilter));
    if (B b = cast(B) p)
    {
        immediate.Drawn[] drawn;
        report("B", n, "repaint", measure(runs, () { drawn.length = 0; }, () {
            repaint(b.p.owner.root, drawn);
        }));
    }
    writefln("    GC collections: %d", GC.profileStats().numCollections - collections);
}

/// Path C: the hex view island from `hybrid` over 1 MiB, 30 visible rows.
void runHex(int runs)
{
    Signal!(ubyte[]) memory = signal(new ubyte[1 << 20]);
    Signal!double scrollY = signal(0.0);
    Island hex = new Island((mu_Context* ctx, Rect r) { hexView(ctx, r, memory, scrollY); });
    scope (exit)
    {
        hex.dispose();
    }
    Shell shell = new Shell(column(cross: CrossAlign.stretch)(new Text("Memory"), expanded(hex)),
        Size(640, 480));
    shell.frame();
    report("C", 30, "scroll", measure(runs, null, () {
        scrollY.set(scrollY.peek + 16);
        shell.frame();
    }));
    report("C", 30, "idle", measure(runs, null, () { shell.frame(); }));
}

/// Operation `i` of the mixed workload: pointer, one hit, all hits and filter in turn.
void mixed(Path p, size_t i)
{
    switch (i % 4)
    {
    case 0:
        p.pointer();
        break;
    case 1:
        p.oneHit();
        break;
    case 2:
        p.allHits();
        break;
    default:
        p.toggleFilter();
        break;
    }
}

/// Zeroes stack below the caller, so dead frames hold no pointers for the collector to find.
pragma(inline, false)
void wipeStack()
{
    size_t[16 * 1024] junk = void;
    foreach (ref size_t w; junk)
    {
        volatileStore(&w, 0);
    }
}

/// Live GC heap in bytes after a full collection, size-class rounding included.
long live()
{
    wipeStack();
    GC.collect();
    return GC.stats().usedSize;
}

/// Resident and peak resident size of this process in KiB. Leaves no GC garbage to skew a baseline.
size_t[2] resident()
{
    static char[4096] buf;
    size_t[2] r;
    File status = File("/proc/self/status");
    foreach (const(char)[] line; status.rawRead(buf[]).lineSplitter)
    {
        if (line.startsWith("VmRSS:"))
        {
            r[0] = to!size_t(line["VmRSS:".length .. $].strip.splitter(' ').front);
        }
        else if (line.startsWith("VmHWM:"))
        {
            r[1] = to!size_t(line["VmHWM:".length .. $].strip.splitter(' ').front);
        }
    }
    return r;
}

/// Prints the memory use of one path: model, retained UI, garbage per operation and peaks.
///
/// Retained figures are live bytes after a full collection. `ops` operations of
/// `step` run between the two retained readings, so growth shows as a difference.
void measureMemory(string name, size_t n, size_t ops, scope void delegate() setup,
    scope void delegate() first, scope void delegate(size_t) step)
{
    size_t[2] rss = resident();
    long base = live();
    setup();
    long model = live() - base;
    first();
    first();
    long ui = live() - base - model;
    size_t collections = GC.profileStats().numCollections;
    ulong allocated = GC.allocatedInCurrentThread;
    size_t heap;
    foreach (size_t i; 0 .. ops)
    {
        step(i);
        GC.Stats s = GC.stats();
        heap = max(heap, s.usedSize + s.freeSize);
    }
    ulong perOp = (GC.allocatedInCurrentThread - allocated) / ops;
    collections = GC.profileStats().numCollections - collections;
    long later = live() - base - model;
    writefln("%-3s %6d %10.1f %10.1f %10.1f %9.1f %5d %9.1f %8.1f %8.1f", name, n, model / 1024.0,
        ui / 1024.0, later / 1024.0, perOp / 1024.0, collections, heap / 1048576.0, rss[0] / 1024.0,
        resident()[1] / 1024.0);
    stdout.flush();
}

/// Memory use of the hex view island over 1 MiB, `ops` scroll steps.
void hexMemory(size_t ops)
{
    Signal!(ubyte[]) memory;
    Signal!double scrollY;
    Island hex;
    Shell shell;
    measureMemory("C", 30, ops, () {
        memory = signal(new ubyte[1 << 20]);
        scrollY = signal(0.0);
    }, () {
        if (shell is null)
        {
            hex = new Island((mu_Context* ctx, Rect r) { hexView(ctx, r, memory, scrollY); });
            shell = new Shell(column(cross: CrossAlign.stretch)(new Text("Memory"), expanded(hex)),
                Size(640, 480));
        }
        shell.frame();
    }, (size_t i) {
        scrollY.set(scrollY.peek + 16);
        shell.frame();
    });
    hex.dispose();
}

/// Path `name` in a fresh state, or null if there is none.
Path make(string name)
{
    switch (name)
    {
    case "A1":
        return new A1;
    case "A2":
        return new A2(false);
    case "D":
        return new A2(true);
    case "B":
        return new B;
    default:
        return null;
    }
}

/// Runs mode `mode` ("time" or "mem") for path `name` at size `n` in this process.
void child(string mode, string name, size_t n)
{
    if (name == "C")
    {
        if (mode == "time")
        {
            runHex(1000);
        }
        else
        {
            hexMemory(1000);
        }
        return;
    }
    Path p = make(name);
    enforce(p !is null, "unknown path " ~ name);
    if (mode == "time")
    {
        run(p, n, cast(int) max(30, 100_000 / n));
    }
    else
    {
        // NOTE: a multiple of 8 operations ends with the filter off, as it started
        size_t ops = (max(100, 200_000 / n) + 7) / 8 * 8;
        measureMemory(name, n, ops, () { p.setup(n); }, &p.first,
            (size_t i) { mixed(p, i); });
    }
}

/// Druntime options given to this process, to pass on to its children.
string[] runtimeOptions()
{
    string[] r;
    CArgs c = Runtime.cArgs;
    foreach (int i; 1 .. c.argc)
    {
        string a = fromStringz(c.argv[i]).idup;
        if (a.startsWith("--DRT-"))
        {
            r ~= a;
        }
    }
    return r;
}

/// Prints date, compiler and CPU, so saved output says where it came from.
void header()
{
    string cpu = "unknown CPU";
    if (exists("/proc/cpuinfo"))
    {
        foreach (string line; readText("/proc/cpuinfo").splitLines)
        {
            if (line.startsWith("model name"))
            {
                cpu = line.findSplitAfter(": ")[1];
                break;
            }
        }
    }
    version (assert)
    {
        enum string asserts = ", asserts on";
    }
    else
    {
        enum string asserts = "";
    }
    writefln("# %s, %s %d.%03d%s, %s", (cast(Date) Clock.currTime).toISOExtString, __VENDOR__,
        __VERSION__ / 1000, __VERSION__ % 1000, asserts, cpu);
}

/// All paths show the same summary after each operation, and D draws exactly what A2 draws.
unittest
{
    A1 a1 = new A1;
    A2 a2 = new A2(false);
    A2 d = new A2(true);
    B b = new B;
    Path[] paths = [cast(Path) a1, a2, d, b];
    foreach (Path p; paths)
    {
        p.setup(8);
        p.first();
        p.first();
    }

    /// Checks every path against A2.
    void agree(string what)
    {
        string want = a2.summary;
        foreach (Path p; paths)
        {
            enforce(p.summary == want, format("%s: %s shows %s, A2 %s", what, p.name, p.summary, want));
        }
        enforce(d.ui.drawn == a2.ui.drawn, what ~ ": D drew something else");
    }

    agree("first");
    assert(a2.summary == "8 of 8 shown");
    foreach (Path p; paths)
    {
        p.oneHit();
        p.oneHit();
    }
    agree("one hit");
    assert(d.ui.skipped == 7, "only the changed row re-ran");
    foreach (Path p; paths)
    {
        p.toggleFilter();
    }
    agree("filter on");
    assert(a2.summary == "2 of 8 shown");
    foreach (Path p; paths)
    {
        p.allHits();
        p.toggleFilter();
        p.pointer();
    }
    agree("all hits, filter off");
}

version (unittest)
{
}
else
{
    /// `bench [time|mem] [sizes]`: every path at each size, default 50 1000 10000, then the hex island.
    void main(string[] args)
    {
        if (args.length == 5 && args[1] == "--child")
        {
            child(args[2], args[3], to!size_t(args[4]));
            return;
        }
        string mode = "time";
        string[] rest = args[1 .. $];
        if (rest.length > 0 && (rest[0] == "time" || rest[0] == "mem"))
        {
            mode = rest[0];
            rest = rest[1 .. $];
        }
        size_t[] sizes = [50, 1000, 10_000];
        if (rest.length > 0)
        {
            sizes = rest.map!(to!size_t).array;
        }
        string[] drt = runtimeOptions();
        header();
        if (drt.length > 0)
        {
            writefln("# %-(%s %)", drt);
        }
        if (mode == "time")
        {
            writeln("path    n  op            median us     p99 us    KiB/op");
        }
        else
        {
            writeln("path    n  model KiB     UI KiB  UI later  KiB/op   GCs  heap MiB  RSS MiB  peak MiB");
        }
        stdout.flush();

        /// Runs one path and size in a new process.
        void spawn(string name, size_t n)
        {
            int status = wait(spawnProcess([thisExePath, "--child", mode, name, to!string(n)] ~ drt));
            enforce(status == 0, format("%s at %d exited with %d", name, n, status));
        }

        foreach (size_t n; sizes)
        {
            foreach (string name; ["A1", "A2", "D", "B"])
            {
                spawn(name, n);
            }
        }
        spawn("C", 30);
    }
}
