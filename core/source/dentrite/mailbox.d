/// Hand-off from a debugger backend thread to the UI thread.
///
/// The backend never touches UI state. It posts into a mailbox and wakes the UI
/// loop. The UI thread drains once per frame and applies everything in one
/// batch. Values that only matter as "latest" (hit counts, registers) coalesce
/// by key. Ordered streams (log lines) keep every entry.
/// NOTE: the boxes are not typed `shared`. Every field access is under `lock`.
module dentrite.mailbox;

import core.sync.mutex : Mutex;
import dentrite.platform : wakeUi;
import std.functional : toDelegate;

/// Latest-value-wins updates keyed by `K`.
final class Mailbox(K, V)
{
    private Mutex lock;               /// guards `pending`
    private V[K] pending;             /// newest value per key since the last drain
    private void delegate() nothrow wake; /// called when the box goes from empty to non-empty

    /// Creates a box that calls `wake` from the posting thread, `wakeUi` by default.
    this(void delegate() nothrow wake = null)
    {
        lock = new Mutex;
        this.wake = wake !is null ? wake : toDelegate(&wakeUi);
    }

    /// Records `value` for `key`, replacing any undrained value. Any thread.
    void post(K key, V value)
    {
        bool first;
        lock.lock();
        first = pending.length == 0;
        pending[key] = value;
        lock.unlock();
        if (first)
        {
            wake();
        }
    }

    /// Takes everything posted since the last drain. UI thread.
    V[K] drain()
    {
        lock.lock();
        V[K] taken = pending;
        pending = null;
        lock.unlock();
        return taken;
    }
}

/// Ordered stream that keeps every entry, such as log lines.
final class Queue(T)
{
    private Mutex lock;    /// guards `items`
    private T[] items;     /// entries since the last drain
    private void delegate() nothrow wake; /// called when the queue goes from empty to non-empty

    /// Creates a queue that calls `wake` from the posting thread, `wakeUi` by default.
    this(void delegate() nothrow wake = null)
    {
        lock = new Mutex;
        this.wake = wake !is null ? wake : toDelegate(&wakeUi);
    }

    /// Appends `item`. Any thread.
    void post(T item)
    {
        bool first;
        lock.lock();
        first = items.length == 0;
        items ~= item;
        lock.unlock();
        if (first)
        {
            wake();
        }
    }

    /// Takes all entries in order. UI thread.
    T[] drain()
    {
        lock.lock();
        T[] taken = items;
        items = null;
        lock.unlock();
        return taken;
    }
}

// 100k hit updates from a backend thread become one batch and one effect run per breakpoint.
unittest
{
    import core.atomic : atomicLoad, atomicOp;
    import core.thread : Thread;
    import dentrite.signals;

    shared int wakes;
    Mailbox!(uint, uint) hits = new Mailbox!(uint, uint)(() nothrow { atomicOp!"+="(wakes, 1); });
    Queue!string log = new Queue!string(() nothrow { atomicOp!"+="(wakes, 1); });

    /// Effect counting runs of `s` into `runs[key]`.
    /// NOTE: closures made directly in a loop body share one frame, so each
    /// effect is created in its own call.
    static void watch(Signal!uint s, int[] runs, uint key)
    {
        effect(() {
            s.get;
            ++runs[key];
        });
    }

    Signal!uint[uint] hitSignals;
    int[] runs = new int[5];
    foreach (uint id; 1 .. 5)
    {
        hitSignals[id] = signal(0u);
        watch(hitSignals[id], runs, id);
    }

    Thread backend = new Thread(() {
        foreach (uint n; 1 .. 100_001)
        {
            hits.post(n % 4 + 1, n);
            if (n % 25_000 == 0)
            {
                log.post("stopped at checkpoint");
            }
        }
    });
    backend.start();
    backend.join();

    assert(atomicLoad(wakes) == 2, "one wake per box, the UI had not drained yet");
    uint[uint] latest = hits.drain();
    batch(() {
        foreach (uint id, uint value; latest)
        {
            hitSignals[id].set(value);
        }
    });
    assert(hitSignals[1].peek == 100_000);
    assert(hitSignals[2].peek == 99_997);
    foreach (uint id; 1 .. 5)
    {
        assert(runs[id] == 2, "initial run plus one");
    }
    assert(log.drain().length == 4);
    assert(hits.drain().length == 0);
}
