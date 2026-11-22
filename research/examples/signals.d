/// Fine-grained reactive core: signals, computed values, effects and owner scopes.
///
/// Port of the alien-signals 3.2 push-pull algorithm (stackblitz/alien-signals,
/// src/system.ts). One difference: tracking and ownership are separate, as in
/// SolidJS. `activeSub` collects dependencies, `currentOwner` adopts new effects
/// and scopes. Scope bodies and `untracked` blocks own without tracking.
/// Graph state is thread-local: only the creating thread may touch a node.
module signals;

import std.algorithm.mutation : reverse;

/// Node state bits.
enum Flag : uint
{
    none = 0,
    mutable = 1,        /// signal, computed or scope
    watching = 2,       /// effect that is not queued
    recursedCheck = 4,  /// currently running
    recursed = 8,       /// written to while running
    dirty = 16,         /// known stale
    pending = 32,       /// maybe stale, needs a check
    hasChildEffect = 64, /// owns nested effects or scopes
}

/// Edge between a dependency and a subscriber, threaded through both nodes' lists.
struct Link
{
    uint cycle;          /// run counter when last confirmed
    ReactiveNode dep;    /// node being read
    ReactiveNode sub;    /// node reading it
    Link* prevSub;       /// previous subscriber of `dep`
    Link* nextSub;       /// next subscriber of `dep`
    Link* prevDep;       /// previous dependency of `sub`
    Link* nextDep;       /// next dependency of `sub`
}

/// Base of every node in the graph.
abstract class ReactiveNode
{
    Link* deps;      /// first dependency
    Link* depsTail;  /// last dependency confirmed in the current run
    Link* subs;      /// first subscriber
    Link* subsTail;  /// last subscriber
    uint flags;      /// Flag bits

    /// Re-evaluates the node, true if its value changed.
    protected bool refresh()
    {
        flags = Flag.mutable;
        return true;
    }

    /// Called when the last subscriber unlinks.
    protected void unwatched()
    {
    }
}

private uint cycle;                /// Run counter used to dedupe links
private int runDepth;              /// Nesting of running effects
private int batchDepth;            /// Nesting of batch calls
private ReactiveNode activeSub;    /// Node collecting dependencies, or null
private ReactiveNode currentOwner; /// Node adopting new effects and scopes, or null
private Effect[] queue;            /// Effects waiting for flush
private size_t notifyIndex;        /// Next queued effect to run

/// Writable reactive value.
final class Signal(T) : ReactiveNode
{
    private T current; /// value seen by readers
    private T pending; /// last written value

    /// Creates a signal holding `value`.
    this(T value)
    {
        current = value;
        pending = value;
        flags = Flag.mutable;
    }

    /// Value, tracked by the running effect or computed.
    T get()
    {
        if ((flags & Flag.dirty) != 0)
        {
            if (refresh() && subs !is null)
            {
                shallowPropagate(subs);
            }
        }
        if (activeSub !is null)
        {
            link(this, activeSub, cycle);
        }
        return current;
    }

    /// Latest written value, untracked.
    T peek()
    {
        return pending;
    }

    /// Writes `value` and runs affected effects unless batching.
    void set(T value)
    {
        if (changed(pending, value) == false)
        {
            return;
        }
        pending = value;
        flags = Flag.mutable | Flag.dirty;
        if (subs !is null)
        {
            propagate(subs, runDepth > 0);
            if (batchDepth == 0)
            {
                flush();
            }
        }
    }

    /// Commits the pending value, true if it differs from the committed one.
    protected override bool refresh()
    {
        flags = Flag.mutable;
        T old = current;
        current = pending;
        return changed(old, current);
    }
}

/// Lazily evaluated value derived from other signals.
final class Computed(T) : ReactiveNode
{
    private T value;               /// cached result
    private T delegate() getter;   /// derivation

    /// Creates a computed value. Nothing runs until the first read.
    this(T delegate() getter)
    {
        this.getter = getter;
    }

    /// Value, recomputed first if a dependency changed.
    T get()
    {
        uint f = flags;
        if ((f & Flag.dirty) != 0
            || ((f & Flag.pending) != 0 && checkDirty(deps, this)))
        {
            if (refresh() && subs !is null)
            {
                shallowPropagate(subs);
            }
        }
        else if ((f & Flag.pending) != 0)
        {
            flags = f & ~Flag.pending;
        }
        else if (f == 0)
        {
            refresh();
        }
        if (activeSub !is null)
        {
            link(this, activeSub, cycle);
        }
        return value;
    }

    /// Runs the getter with this node tracking, true if the result changed.
    protected override bool refresh()
    {
        if ((flags & Flag.hasChildEffect) != 0)
        {
            disposeChildren(this);
        }
        depsTail = null;
        flags = Flag.mutable | Flag.recursedCheck;
        ReactiveNode prevSub = activeSub;
        ReactiveNode prevOwner = currentOwner;
        activeSub = this;
        currentOwner = this;
        ++cycle;
        scope (exit)
        {
            activeSub = prevSub;
            currentOwner = prevOwner;
            flags &= ~Flag.recursedCheck;
            purgeDeps(this);
        }
        T old = value;
        value = getter();
        return changed(old, value);
    }

    /// Drops dependencies once nothing reads this value.
    protected override void unwatched()
    {
        if (depsTail !is null)
        {
            flags = Flag.mutable | Flag.dirty;
            disposeAllDepsInReverse(this);
        }
    }
}

/// Side effect that re-runs when anything it read changes.
final class Effect : ReactiveNode
{
    private void delegate() fn;          /// body
    private void delegate()[] cleanups;  /// run before re-run and on dispose
    private bool disposed;               /// set once by dispose

    /// Wraps `fn`. Use `effect` to create and start one.
    private this(void delegate() fn)
    {
        this.fn = fn;
    }

    /// Stops the effect, disposes owned children and runs cleanups.
    void dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        flags = Flag.none;
        disposeAllDepsInReverse(this);
        runCleanups(cleanups);
        if (subs !is null)
        {
            unlink(subs);
        }
    }

    /// Runs the body with this node tracking and owning.
    private void execute()
    {
        depsTail = null;
        flags = Flag.watching | Flag.recursedCheck;
        ReactiveNode prevSub = activeSub;
        ReactiveNode prevOwner = currentOwner;
        activeSub = this;
        currentOwner = this;
        ++cycle;
        ++runDepth;
        scope (exit)
        {
            --runDepth;
            activeSub = prevSub;
            currentOwner = prevOwner;
            flags &= ~Flag.recursedCheck;
            purgeDeps(this);
        }
        fn();
    }

    /// Disposes the effect when its owner drops it.
    protected override void unwatched()
    {
        dispose();
    }
}

/// Owner of effects and nested scopes with no reactive body of its own.
final class Scope : ReactiveNode
{
    private void delegate()[] cleanups; /// run on dispose
    private bool disposed;              /// set once by dispose

    /// Disposes owned effects and scopes, then runs cleanups.
    void dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        flags = Flag.none;
        disposeAllDepsInReverse(this);
        runCleanups(cleanups);
        if (subs !is null)
        {
            unlink(subs);
        }
    }

    /// Disposes the scope when its owner drops it.
    protected override void unwatched()
    {
        dispose();
    }
}

/// New signal holding `value`.
Signal!T signal(T)(T value)
{
    return new Signal!T(value);
}

/// New computed value from `getter`.
Computed!T computed(T)(T delegate() getter)
{
    return new Computed!T(getter);
}

/// Creates an effect owned by the current owner and runs it once.
Effect effect(void delegate() fn)
{
    Effect e = new Effect(fn);
    adopt(e);
    e.execute();
    return e;
}

/// Runs `fn` untracked inside a new scope that owns what `fn` creates.
Scope effectScope(void delegate() fn)
{
    Scope s = new Scope;
    s.flags = Flag.mutable;
    adopt(s);
    ReactiveNode prevSub = activeSub;
    ReactiveNode prevOwner = currentOwner;
    activeSub = null;
    currentOwner = s;
    scope (exit)
    {
        activeSub = prevSub;
        currentOwner = prevOwner;
    }
    fn();
    return s;
}

/// Runs `fn` untracked with `owner` adopting what it creates.
void runWithOwner(ReactiveNode owner, void delegate() fn)
{
    ReactiveNode prevSub = activeSub;
    ReactiveNode prevOwner = currentOwner;
    activeSub = null;
    currentOwner = owner;
    scope (exit)
    {
        activeSub = prevSub;
        currentOwner = prevOwner;
    }
    fn();
}

/// Registers `fn` to run when the current effect re-runs or its owner is disposed.
void onCleanup(void delegate() fn)
{
    if (Effect e = cast(Effect) currentOwner)
    {
        e.cleanups ~= fn;
    }
    else if (Scope s = cast(Scope) currentOwner)
    {
        s.cleanups ~= fn;
    }
    else
    {
        assert(false, "onCleanup needs an effect or scope owner");
    }
}

/// Runs `fn` with effects deferred until the outermost batch ends.
void batch(void delegate() fn)
{
    ++batchDepth;
    scope (exit)
    {
        if (--batchDepth == 0)
        {
            flush();
        }
    }
    fn();
}

/// Result of `fn`, with its reads not tracked. Ownership is kept.
T untracked(T)(T delegate() fn)
{
    ReactiveNode prev = activeSub;
    activeSub = null;
    scope (exit)
    {
        activeSub = prev;
    }
    return fn();
}

/// True if `a` and `b` differ. Classes compare by identity, the rest by `!=`.
private bool changed(T)(ref T a, ref T b)
{
    static if (is(T == class) || is(T == interface))
    {
        return a !is b;
    }
    else
    {
        return a != b;
    }
}

/// Links a new effect or scope to the current owner.
private void adopt(ReactiveNode child)
{
    ReactiveNode owner = currentOwner;
    if (owner !is null)
    {
        link(child, owner, 0);
        owner.flags |= Flag.hasChildEffect;
    }
}

/// Runs and clears cleanups, last registered first, untracked.
private void runCleanups(ref void delegate()[] list)
{
    void delegate()[] todo = list;
    list = null;
    ReactiveNode prev = activeSub;
    activeSub = null;
    scope (exit)
    {
        activeSub = prev;
    }
    foreach_reverse (void delegate() fn; todo)
    {
        fn();
    }
}

/// Records that `sub` read `dep`, reusing the existing link when the order is unchanged.
private void link(ReactiveNode dep, ReactiveNode sub, uint version_)
{
    Link* prevDep = sub.depsTail;
    if (prevDep !is null && prevDep.dep is dep)
    {
        return;
    }
    Link* nextDep = prevDep !is null ? prevDep.nextDep : sub.deps;
    if (nextDep !is null && nextDep.dep is dep)
    {
        nextDep.cycle = version_;
        sub.depsTail = nextDep;
        return;
    }
    Link* prevSub = dep.subsTail;
    if (prevSub !is null && prevSub.cycle == version_ && prevSub.sub is sub)
    {
        return;
    }
    Link* l = new Link(version_, dep, sub, prevSub, null, prevDep, nextDep);
    sub.depsTail = l;
    dep.subsTail = l;
    if (nextDep !is null)
    {
        nextDep.prevDep = l;
    }
    if (prevDep !is null)
    {
        prevDep.nextDep = l;
    }
    else
    {
        sub.deps = l;
    }
    if (prevSub !is null)
    {
        prevSub.nextSub = l;
    }
    else
    {
        dep.subs = l;
    }
}

/// Removes `l` from both lists and returns the next dependency of `l.sub`.
private Link* unlink(Link* l)
{
    ReactiveNode dep = l.dep;
    ReactiveNode sub = l.sub;
    Link* prevDep = l.prevDep;
    Link* nextDep = l.nextDep;
    Link* prevSub = l.prevSub;
    Link* nextSub = l.nextSub;
    if (nextDep !is null)
    {
        nextDep.prevDep = prevDep;
    }
    else
    {
        sub.depsTail = prevDep;
    }
    if (prevDep !is null)
    {
        prevDep.nextDep = nextDep;
    }
    else
    {
        sub.deps = nextDep;
    }
    if (nextSub !is null)
    {
        nextSub.prevSub = prevSub;
    }
    else
    {
        dep.subsTail = prevSub;
    }
    if (prevSub !is null)
    {
        prevSub.nextSub = nextSub;
    }
    else
    {
        dep.subs = nextSub;
        if (nextSub is null)
        {
            dep.unwatched();
        }
    }
    return nextDep;
}

/// Marks everything downstream of `l` pending and queues reached effects.
private void propagate(Link* l, bool innerWrite)
{
    Link* next = l.nextSub;
    Link*[] stack;
    top: while (true)
    {
        ReactiveNode sub = l.sub;
        uint f = sub.flags;
        if ((f & (Flag.recursedCheck | Flag.recursed | Flag.dirty | Flag.pending)) == 0)
        {
            sub.flags = f | Flag.pending;
            if (innerWrite)
            {
                sub.flags |= Flag.recursed;
            }
        }
        else if ((f & (Flag.recursedCheck | Flag.recursed)) == 0)
        {
            f = Flag.none;
        }
        else if ((f & Flag.recursedCheck) == 0)
        {
            sub.flags = (f & ~Flag.recursed) | Flag.pending;
        }
        else if ((f & (Flag.dirty | Flag.pending)) == 0 && isValidLink(l, sub))
        {
            sub.flags = f | Flag.recursed | Flag.pending;
            f &= Flag.mutable;
        }
        else
        {
            f = Flag.none;
        }

        if ((f & Flag.watching) != 0)
        {
            notify(sub);
        }

        if ((f & Flag.mutable) != 0 && sub.subs !is null)
        {
            l = sub.subs;
            if (l.nextSub !is null)
            {
                stack ~= next;
                next = l.nextSub;
            }
            continue;
        }

        if (next !is null)
        {
            l = next;
            next = l.nextSub;
            continue;
        }

        while (stack.length > 0)
        {
            l = stack[$ - 1];
            stack.length -= 1;
            if (l !is null)
            {
                next = l.nextSub;
                continue top;
            }
        }
        break;
    }
}

/// Walks pending dependencies of `sub`, recomputing as needed, true if `sub` must re-run.
private bool checkDirty(Link* l, ReactiveNode sub)
{
    Link*[] stack;
    int depth;
    bool dirty;
    top: while (true)
    {
        ReactiveNode dep = l.dep;
        uint f = dep.flags;
        if ((sub.flags & Flag.dirty) != 0)
        {
            dirty = true;
        }
        else if ((f & (Flag.mutable | Flag.dirty)) == (Flag.mutable | Flag.dirty))
        {
            Link* depSubs = dep.subs;
            if (dep.refresh())
            {
                if (depSubs.nextSub !is null)
                {
                    shallowPropagate(depSubs);
                }
                dirty = true;
            }
        }
        else if ((f & (Flag.mutable | Flag.pending)) == (Flag.mutable | Flag.pending))
        {
            stack ~= l;
            l = dep.deps;
            sub = dep;
            ++depth;
            continue;
        }

        if (dirty == false && l.nextDep !is null)
        {
            l = l.nextDep;
            continue;
        }

        while (depth-- > 0)
        {
            l = stack[$ - 1];
            stack.length -= 1;
            if (dirty)
            {
                Link* subSubs = sub.subs;
                if (sub.refresh())
                {
                    if (subSubs.nextSub !is null)
                    {
                        shallowPropagate(subSubs);
                    }
                    sub = l.sub;
                    continue;
                }
                dirty = false;
            }
            else
            {
                sub.flags &= ~Flag.pending;
            }
            sub = l.sub;
            if (l.nextDep !is null)
            {
                l = l.nextDep;
                continue top;
            }
        }
        break;
    }
    return dirty && sub.flags != 0;
}

/// Promotes direct pending subscribers of a changed node to dirty.
private void shallowPropagate(Link* l)
{
    do
    {
        ReactiveNode sub = l.sub;
        uint f = sub.flags;
        if ((f & (Flag.pending | Flag.dirty)) == Flag.pending)
        {
            sub.flags = f | Flag.dirty;
            if ((f & (Flag.watching | Flag.recursedCheck)) == Flag.watching)
            {
                notify(sub);
            }
        }
        l = l.nextSub;
    }
    while (l !is null);
}

/// True if `check` is among the links `sub` confirmed so far in its current run.
private bool isValidLink(Link* check, ReactiveNode sub)
{
    for (Link* l = sub.depsTail; l !is null; l = l.prevDep)
    {
        if (l is check)
        {
            return true;
        }
    }
    return false;
}

/// Queues an effect and any watching parent effects, outermost first.
private void notify(ReactiveNode node)
{
    size_t first = queue.length;
    Effect e = cast(Effect) node;
    while (e !is null)
    {
        queue ~= e;
        e.flags &= ~Flag.watching;
        if (e.subs is null)
        {
            break;
        }
        Effect parent = cast(Effect) e.subs.sub;
        if (parent is null || (parent.flags & Flag.watching) == 0)
        {
            break;
        }
        e = parent;
    }
    reverse(queue[first .. $]);
}

/// Runs `e` if it is dirty, or if a pending check finds a changed dependency.
private void run(Effect e)
{
    uint f = e.flags;
    if ((f & Flag.dirty) != 0
        || ((f & Flag.pending) != 0 && checkDirty(e.deps, e)))
    {
        if ((f & Flag.hasChildEffect) != 0)
        {
            disposeChildren(e);
        }
        if (e.cleanups.length > 0)
        {
            runCleanups(e.cleanups);
            if (e.disposed)
            {
                return;
            }
        }
        e.execute();
    }
    else if (e.deps !is null)
    {
        e.flags = Flag.watching | (f & Flag.hasChildEffect);
    }
}

/// Runs queued effects in order. Effects queued meanwhile run in the same flush.
private void flush()
{
    scope (exit)
    {
        while (notifyIndex < queue.length)
        {
            queue[notifyIndex++].flags |= Flag.watching | Flag.recursed;
        }
        notifyIndex = 0;
        queue.length = 0;
        queue.assumeSafeAppend();
    }
    while (notifyIndex < queue.length)
    {
        Effect e = queue[notifyIndex];
        queue[notifyIndex++] = null;
        run(e);
    }
}

/// Unlinks owned effects and scopes of `node`, which disposes them.
private void disposeChildren(ReactiveNode node)
{
    Link* l = node.depsTail;
    while (l !is null)
    {
        Link* prev = l.prevDep;
        if (cast(Effect) l.dep !is null || cast(Scope) l.dep !is null)
        {
            unlink(l);
        }
        l = prev;
    }
}

/// Unlinks every dependency of `sub`, last first.
private void disposeAllDepsInReverse(ReactiveNode sub)
{
    Link* l = sub.depsTail;
    while (l !is null)
    {
        Link* prev = l.prevDep;
        unlink(l);
        l = prev;
    }
}

/// Unlinks dependencies not confirmed in the run that just ended.
private void purgeDeps(ReactiveNode sub)
{
    Link* l = sub.depsTail !is null ? sub.depsTail.nextDep : sub.deps;
    while (l !is null)
    {
        l = unlink(l);
    }
}

/// Number of subscribers of `node`.
size_t subscriberCount(ReactiveNode node)
{
    size_t n;
    for (Link* l = node.subs; l !is null; l = l.nextSub)
    {
        ++n;
    }
    return n;
}

/// Signal, computed and effect basics.
unittest
{
    Signal!int count = signal(1);
    Computed!int doubled = computed(() => count.get * 2);
    int[] seen;
    Effect e = effect(() { seen ~= doubled.get; });
    assert(seen == [2]);
    count.set(2);
    assert(seen == [2, 4]);
    count.set(2);
    assert(seen == [2, 4], "equal write must not re-run");
    e.dispose();
    count.set(3);
    assert(seen == [2, 4]);
}

/// Diamond: a feeds b and c, d reads both. One write, one run of d, no torn reads.
unittest
{
    Signal!int a = signal(1);
    int bRuns, cRuns, dRuns;
    Computed!int b = computed(() { ++bRuns; return a.get + 1; });
    Computed!int c = computed(() { ++cRuns; return a.get * 10; });
    Computed!int d = computed(() { ++dRuns; return b.get + c.get; });
    int[] seen;
    effect(() { seen ~= d.get; });
    assert(seen == [12]);
    a.set(2);
    assert(seen == [12, 23]);
    assert(bRuns == 2 && cRuns == 2 && dRuns == 2);
}

/// Glitch freedom: an effect reading a source and its derivation never sees a mix.
unittest
{
    Signal!int a = signal(1);
    Computed!int twice = computed(() => a.get * 2);
    bool torn;
    effect(() {
        int x = a.get;
        int y = twice.get;
        if (y != x * 2)
        {
            torn = true;
        }
    });
    foreach (int i; 2 .. 50)
    {
        a.set(i);
    }
    assert(torn == false);
}

/// A computed that recomputes to an equal value stops propagation.
unittest
{
    Signal!int n = signal(3);
    Computed!bool odd = computed(() => n.get % 2 == 1);
    int runs;
    effect(() { odd.get; ++runs; });
    n.set(5);
    assert(runs == 1, "odd stayed true");
    n.set(6);
    assert(runs == 2);
}

/// Batching: several writes, one run. Write then revert inside a batch, no run.
unittest
{
    Signal!int x = signal(0);
    Signal!int y = signal(0);
    int runs;
    effect(() { x.get; y.get; ++runs; });
    batch(() {
        x.set(1);
        y.set(1);
        assert(runs == 1, "deferred until batch end");
    });
    assert(runs == 2);
    batch(() {
        x.set(5);
        x.set(1);
    });
    assert(runs == 2, "net change is zero");
}

/// Conditional dependencies: the untaken branch is not tracked.
unittest
{
    Signal!bool useA = signal(true);
    Signal!int a = signal(1);
    Signal!int b = signal(2);
    int runs;
    effect(() {
        ++runs;
        if (useA.get)
        {
            a.get;
        }
        else
        {
            b.get;
        }
    });
    b.set(20);
    assert(runs == 1, "b not read yet");
    useA.set(false);
    assert(runs == 2);
    a.set(10);
    assert(runs == 2, "a dropped after the branch flipped");
    assert(subscriberCount(a) == 0);
    b.set(30);
    assert(runs == 3);
}

/// Untracked reads do not subscribe.
unittest
{
    Signal!int tracked = signal(1);
    Signal!int quiet = signal(1);
    int runs;
    effect(() {
        tracked.get;
        untracked(() => quiet.get);
        ++runs;
    });
    quiet.set(2);
    assert(runs == 1);
    tracked.set(2);
    assert(runs == 2);
    assert(quiet.peek == 2);
}

/// Disposal: scopes own effects, nested effects are replaced on re-run, cleanups run last first.
unittest
{
    Signal!int s = signal(0);
    Signal!bool show = signal(true);
    string[] log;
    int innerRuns;
    Scope root = effectScope(() {
        onCleanup(() { log ~= "root"; });
        effect(() {
            if (show.get)
            {
                effect(() {
                    s.get;
                    ++innerRuns;
                    onCleanup(() { log ~= "inner"; });
                });
            }
            onCleanup(() { log ~= "outer"; });
        });
    });
    assert(innerRuns == 1);
    s.set(1);
    assert(innerRuns == 2);
    assert(log == ["inner"]);
    show.set(false);
    assert(log == ["inner", "inner", "outer"], "children before the parent's cleanup");
    s.set(2);
    assert(innerRuns == 2, "inner effect is gone");
    root.dispose();
    assert(log == ["inner", "inner", "outer", "outer", "root"]);
    show.set(true);
    assert(innerRuns == 2, "nothing runs after dispose");
    assert(subscriberCount(show) == 0);
    assert(subscriberCount(s) == 0);
}

/// Memory: a computed drops its sources once its last reader is gone.
unittest
{
    Signal!int src = signal(1);
    Computed!int mid = computed(() => src.get + 1);
    Effect e = effect(() { mid.get; });
    assert(subscriberCount(src) == 1);
    e.dispose();
    assert(subscriberCount(mid) == 0);
    assert(subscriberCount(src) == 0, "mid unsubscribed from src");
    assert(mid.get == 2, "still readable, recomputed on demand");
}

/// Outer effects run before inner ones in the same flush.
unittest
{
    Signal!int s = signal(0);
    string[] order;
    effect(() {
        s.get;
        order ~= "outer";
        effect(() {
            s.get;
            order ~= "inner";
        });
    });
    order = null;
    s.set(1);
    assert(order == ["outer", "inner"]);
}

/// An effect writing a signal read by another effect settles in one flush.
unittest
{
    Signal!int input = signal(1);
    Signal!int mirror = signal(0);
    int[] seen;
    effect(() { mirror.set(input.get * 3); });
    effect(() { seen ~= mirror.get; });
    assert(seen == [3]);
    input.set(2);
    assert(seen == [3, 6]);
}
