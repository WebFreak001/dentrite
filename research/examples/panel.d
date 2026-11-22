/// Breakpoints panel on signals, headless: keyed rows, derived state, fine-grained updates.
///
/// Rows are `RowView` stand-ins for retained widgets. Each row lives in its own
/// owner scope under a long-lived list scope, so re-running the list effect
/// never disposes rows that are still shown.
module panel;

import signals;
import std.algorithm.iteration : filter;
import std.algorithm.searching : canFind;
import std.array : array;
import std.format : format;

/// Breakpoint. Identity fields are fixed, the rest are signals.
final class Breakpoint
{
    immutable uint id;      /// stable key
    immutable string file;  /// source file
    immutable uint line;    /// source line
    Signal!bool enabled;    /// checkbox state
    Signal!uint hits;       /// hit count, written by the debugger

    /// Creates an enabled breakpoint with no hits.
    this(uint id, string file, uint line)
    {
        this.id = id;
        this.file = file;
        this.line = line;
        enabled = signal(true);
        hits = signal(0u);
    }
}

/// Stand-in for a retained row widget. Counts property writes.
final class RowView
{
    string location; /// "file:line", set once
    bool checked;    /// checkbox
    string hitsText; /// hit count label
    int writes;      /// property writes since creation
}

/// Keyed reconciliation: one owner scope and row per key, reused while the key stays.
final class KeyedRows(K, T, R)
{
    R[] ordered;     /// rows in display order after the last update
    int created;     /// rows made so far
    int disposed;    /// rows dropped so far

    private Scope owner;           /// parent of all row scopes
    private K delegate(T) keyOf;   /// item key
    private R delegate(T) make;    /// builds a row and its effects
    private R[K] rows;             /// live rows by key
    private Scope[K] scopes;       /// live row scopes by key

    /// Creates an empty list whose rows are owned by `owner`.
    this(Scope owner, K delegate(T) keyOf, R delegate(T) make)
    {
        this.owner = owner;
        this.keyOf = keyOf;
        this.make = make;
    }

    /// Reuses rows whose key survives, builds new ones, disposes the rest.
    void update(T[] items)
    {
        R[] next;
        bool[K] keep;
        foreach (T item; items)
        {
            K k = keyOf(item);
            keep[k] = true;
            if (R* found = k in rows)
            {
                next ~= *found;
                continue;
            }
            R made;
            runWithOwner(owner, () {
                scopes[k] = effectScope(() { made = make(item); });
            });
            rows[k] = made;
            next ~= made;
            ++created;
        }
        foreach (K k; rows.keys)
        {
            if ((k in keep) is null)
            {
                scopes[k].dispose();
                scopes.remove(k);
                rows.remove(k);
                ++disposed;
            }
        }
        ordered = next;
    }

    /// Row for key `k`, or null.
    R opIndex(K k)
    {
        R* r = k in rows;
        return r is null ? null : *r;
    }
}

/// True if `b` matches the filter text `q`. Empty matches everything.
bool matches(Breakpoint b, string q)
{
    return q.length == 0 || canFind(b.file, q);
}

/// Panel state, derived values and the bindings that keep rows current.
final class BreakpointsPanel
{
    Signal!(Breakpoint[]) all;        /// every breakpoint
    Signal!string query;              /// filter text box
    Computed!(Breakpoint[]) shown;    /// breakpoints passing the filter
    Computed!string summary;          /// "N of M shown"
    KeyedRows!(uint, Breakpoint, RowView) rows; /// one row per shown breakpoint
    string summaryText;               /// summary label
    int summaryWrites;                /// summary label writes
    int filterRuns;                   /// recomputations of `shown`
    Scope root;                       /// owns everything above

    /// Builds the panel over `initial`.
    this(Breakpoint[] initial)
    {
        root = effectScope(() {
            all = signal(initial);
            query = signal("");
            shown = computed(() {
                ++filterRuns;
                string q = query.get;
                return all.get.filter!((Breakpoint b) => matches(b, q)).array;
            });
            summary = computed(() => format("%d of %d shown", shown.get.length, all.get.length));
            Scope listOwner = effectScope(() {});
            rows = new KeyedRows!(uint, Breakpoint, RowView)(listOwner,
                (Breakpoint b) => b.id, &makeRow);
            effect(() { rows.update(shown.get); });
            effect(() {
                summaryText = summary.get;
                ++summaryWrites;
            });
        });
    }

    /// Row widget for `b`, with one effect per changing property.
    private RowView makeRow(Breakpoint b)
    {
        RowView v = new RowView;
        v.location = format("%s:%d", b.file, b.line);
        effect(() {
            v.checked = b.enabled.get;
            ++v.writes;
        });
        effect(() {
            v.hitsText = format("%d", b.hits.get);
            ++v.writes;
        });
        return v;
    }

    /// "Remove disabled" button handler.
    void removeDisabled()
    {
        all.set(all.peek.filter!((Breakpoint b) => b.enabled.peek).array);
    }
}

/// Five breakpoints across three files.
private Breakpoint[] sample()
{
    return [
        new Breakpoint(1, "main.d", 10),
        new Breakpoint(2, "main.d", 42),
        new Breakpoint(3, "parser.d", 7),
        new Breakpoint(4, "parser.d", 99),
        new Breakpoint(5, "lexer.d", 3),
    ];
}

/// Initial build, then a hit count update that touches one row and nothing else.
unittest
{
    Breakpoint[] bps = sample();
    BreakpointsPanel p = new BreakpointsPanel(bps);
    assert(p.rows.ordered.length == 5 && p.rows.created == 5);
    assert(p.summaryText == "5 of 5 shown");
    RowView r3 = p.rows[3];
    assert(r3.location == "parser.d:7" && r3.hitsText == "0" && r3.writes == 2);

    bps[2].hits.set(7);
    assert(r3.hitsText == "7" && r3.writes == 3);
    assert(p.rows[1].writes == 2, "other rows untouched");
    assert(p.filterRuns == 1, "filter did not re-run");
    assert(p.summaryWrites == 1, "summary did not re-run");
}

/// Backend bursts: many writes in one batch, one write per affected row.
unittest
{
    Breakpoint[] bps = sample();
    BreakpointsPanel p = new BreakpointsPanel(bps);
    batch(() {
        foreach (uint i; 0 .. 1000)
        {
            bps[i % 2].hits.set(bps[i % 2].hits.peek + 1);
        }
    });
    assert(p.rows[1].hitsText == "500" && p.rows[1].writes == 3);
    assert(p.rows[2].hitsText == "500" && p.rows[2].writes == 3);
}

/// Filtering keeps surviving rows, disposes the rest, and the derived label follows.
unittest
{
    Breakpoint[] bps = sample();
    BreakpointsPanel p = new BreakpointsPanel(bps);
    RowView main10 = p.rows[1];
    RowView lexer = p.rows[5];
    p.query.set("main");
    assert(p.summaryText == "2 of 5 shown");
    assert(p.rows.ordered.length == 2 && p.rows.disposed == 3);
    assert(p.rows[1] is main10, "same row object, no rebuild");
    bps[4].hits.set(9);
    assert(lexer.writes == 2, "disposed row no longer updates");
    assert(subscriberCount(bps[4].hits) == 0);
    p.query.set("");
    assert(p.rows.ordered.length == 5 && p.rows.created == 8, "three rows rebuilt");
}

/// Toggle, then "Remove disabled".
unittest
{
    Breakpoint[] bps = sample();
    BreakpointsPanel p = new BreakpointsPanel(bps);
    bps[1].enabled.set(false);
    assert(p.rows[2].checked == false);
    p.removeDisabled();
    assert(p.summaryText == "4 of 4 shown");
    assert(p.rows[2] is null);
    p.root.dispose();
    bps[0].hits.set(5);
    assert(p.rows[1].hitsText == "0", "nothing runs after dispose");
    assert(subscriberCount(bps[0].hits) == 0);
}

/// D gotcha behind `makeRow`: delegates made in a loop body share one frame.
/// NOTE: dlang/dmd#19929. If a compiler fixes it, the first assert fails.
unittest
{
    int[] seen;
    void delegate()[] inLoop;
    foreach (int i; 0 .. 3)
    {
        int k = i;
        inLoop ~= () { seen ~= k; };
    }
    foreach (void delegate() dg; inLoop)
    {
        dg();
    }
    assert(seen == [2, 2, 2], "one shared k, even though it is declared in the loop body");

    /// Delegate appending `k` to `*into`, made in its own call frame.
    static void delegate() capture(int k, int[]* into)
    {
        return () { *into ~= k; };
    }

    seen = null;
    void delegate()[] viaCall;
    foreach (int i; 0 .. 3)
    {
        viaCall ~= capture(i, &seen);
    }
    foreach (void delegate() dg; viaCall)
    {
        dg();
    }
    assert(seen == [0, 1, 2], "a function call gives each delegate its own frame");
}
