/// Chapter 9: work on other threads, handed to the UI through mailboxes.
module guide.threads;

import core.thread : Thread;
import core.time : msecs;
import dentrite.containers;
import dentrite.host : Host;
import dentrite.mailbox;
import dentrite.node;
import dentrite.signals;
import dentrite.widgets.label;
import dentrite.widgets.list : keyedColumn;
import dentrite.widgets.progress;
import std.format : format;

/// Worker side: boxes the worker posts into. Nothing here is a signal, since signals belong to the UI thread.
final class Inbox
{
    Mailbox!(string, double) progress; /// latest fraction done per file, coalesced
    Queue!string log;                  /// every line, in order

    /// Boxes that wake the UI loop when they get their first entry.
    this()
    {
        progress = new Mailbox!(string, double);
        log = new Queue!string;
    }
}

/// UI side: signals the views read, filled from the inbox once per frame.
final class Downloads
{
    string[] files;                 /// in order
    Signal!double[string] progress; /// fraction done per file
    Signal!(string[]) log;          /// lines so far

    /// Signals for `files`, nothing done.
    this(string[] files)
    {
        this.files = files;
        foreach (string f; files)
        {
            progress[f] = signal(0.0);
        }
        log = signal(cast(string[]) null);
    }

    /// Applies what the worker posted since the last frame, in one batch.
    void drain(Inbox box)
    {
        double[string] done = box.progress.drain();
        string[] lines = box.log.drain();
        batch(() {
            foreach (string f, double d; done)
            {
                progress[f].set(d);
            }
            if (lines.length > 0)
            {
                log.set(log.peek ~ lines);
            }
        });
    }
}

/// Worker: fetches `files` in `steps` steps each, posting as it goes.
void fetch(Inbox box, immutable string[] files, int steps)
{
    foreach (string f; files)
    {
        box.log.post("Fetching " ~ f);
        foreach (int i; 1 .. steps + 1)
        {
            Thread.sleep(1.msecs);
            box.progress.post(f, cast(double) i / steps);
        }
        box.log.post("Done " ~ f);
    }
}

/// Bars per file and the log.
Node downloadsView(Downloads d)
{
    Node[] bars;
    foreach (string f; d.files)
    {
        bars ~= fileBar(f, d.progress[f]);
    }
    return pad(all: 12)(column(gap: 8)(
        column(gap: 6)(bars),
        keyedColumn(() => indices(d.log.get.length), (size_t i) => i, (size_t i) => label(d.log.peek[i], "muted")),
    ));
}

/// `0 .. n` as an array.
size_t[] indices(size_t n)
{
    size_t[] r = new size_t[n];
    foreach (size_t i; 0 .. n)
    {
        r[i] = i;
    }
    return r;
}

/// Name, bar and percentage of file `f`.
Node fileBar(string f, Signal!double done)
{
    return row(gap: 8)(sized(w: 90)(label(f)), expanded(progressBar(&done.get)),
        sized(w: 40)(label(() => format("%.0f%%", done.get * 100), "mono")));
}

/// Starts the worker and drains its boxes before every frame of `h`.
void startDownloads(Host h, Downloads d, immutable string[] files)
{
    Inbox box = new Inbox;
    h.beforeFrame ~= () { d.drain(box); };
    Thread t = new Thread(() { fetch(box, files, 20); });
    t.isDaemon = true;
    t.start();
}

/// The worker's posts reach the signals on the UI thread, and the views follow.
unittest
{
    import core.time : MonoTime, seconds;
    import dentrite.script : settle;
    import guide.harness;

    Host h = testHost(400, 300);
    scope (exit)
    {
        h.close();
    }
    static immutable string[] files = ["a.tar", "b.tar"];
    Downloads d = new Downloads(files.dup);
    scope Scope root = effectScope(() { h.setRoot(downloadsView(d)); });
    startDownloads(h, d, files);
    MonoTime until = MonoTime.currTime + 10.seconds;
    while (d.progress["b.tar"].peek < 1 && MonoTime.currTime < until)
    {
        settle(h, 1);
    }
    settle(h, 2);
    assert(d.progress["a.tar"].peek == 1 && d.progress["b.tar"].peek == 1);
    assert(d.log.peek == ["Fetching a.tar", "Done a.tar", "Fetching b.tar", "Done b.tar"]);
    assert(shows(h, Role.label, "Done b.tar") && shows(h, Role.label, "100%"));
}
