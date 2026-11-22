/// Platform without a window, for tests and offscreen frames. Pair it with the software renderer.
module dentrite.headless;

import core.sync.semaphore : Semaphore;
import core.time : Duration;
import dentrite.access : AccessAdapter, AccessDemand, AccessUpdate;
import dentrite.geom : Rect;
import dentrite.node : CursorShape;
import dentrite.platform;

/// Fixed size framebuffer with events queued by the app.
final class HeadlessPlatform : Platform, FileDialogs, AccessAdapter
{
    Metrics size;        /// framebuffer size and scale
    Event[] queue;       /// events `wait` hands out, oldest first
    string[][] fileAnswers; /// paths the next file dialogs return, oldest first, none once used up
    FileDialogKind[] fileAsks; /// kinds of the file dialogs shown
    string clip;         /// clipboard contents
    CursorShape cursor;  /// last cursor set
    bool textOn;         /// true while text input is on
    Rect inputArea;      /// last caret for an input method
    int presented;       /// frames presented
    AccessDemand listening; /// what `demand` answers, `full` turns into `changes` once read
    AccessUpdate[] accessUpdates; /// updates sent while listening, oldest first

    /// Platform `w` by `h` logical pixels at `scale`.
    this(int w, int h, float scale = 1)
    {
        size = Metrics(cast(int)(w * scale), cast(int)(h * scale), scale);
        wakes = new Semaphore;
        setWaker(&wakeHeadless);
    }

    /// Framebuffer size and scale.
    Metrics metrics()
    {
        return size;
    }

    /// Next queued event, or a wake from `wakeUi`, waiting up to `timeout`.
    bool wait(ref Event e, Duration timeout)
    {
        if (queue.length > 0)
        {
            e = queue[0];
            queue = queue[1 .. $];
            return true;
        }
        if (timeout == Duration.max)
        {
            wakes.wait();
        }
        else if (wakes.wait(timeout) == false)
        {
            return false;
        }
        e = Event(EventKind.wake);
        return true;
    }

    /// Queues the next of `fileAnswers` for `done`, as a `call` event.
    void fileDialog(FileDialogKind kind, const(FileFilter)[] filters, string start, void delegate(string[]) done)
    {
        string[] paths;
        if (fileAnswers.length > 0)
        {
            paths = fileAnswers[0];
            fileAnswers = fileAnswers[1 .. $];
        }
        fileAsks ~= kind;
        Event e = { kind: EventKind.call, call: () { done(paths); } };
        queue ~= e;
    }

    /// `listening`, which drops from `full` to `changes` once read.
    AccessDemand demand()
    {
        AccessDemand d = listening;
        if (d == AccessDemand.full)
        {
            listening = AccessDemand.changes;
        }
        return d;
    }

    /// Records `u`.
    void update(ref const AccessUpdate u, float scale)
    {
        accessUpdates ~= cast(AccessUpdate) u;
    }

    /// Counts the frame.
    void present()
    {
        ++presented;
    }

    /// Records the cursor.
    void setCursor(CursorShape shape)
    {
        cursor = shape;
    }

    /// Records whether text input is on.
    void textInput(bool on)
    {
        textOn = on;
    }

    /// Records the input method caret.
    void textInputArea(Rect caret)
    {
        inputArea = caret;
    }

    /// Clipboard contents.
    string clipboard()
    {
        return clip;
    }

    /// Sets the clipboard contents.
    void setClipboard(string s)
    {
        clip = s;
    }

    /// Stops `wakeUi` from reaching this platform.
    void close()
    {
        setWaker(null);
    }
}

/// Signalled by `wakeUi` while a headless platform is open.
private __gshared Semaphore wakes;

/// Releases a waiting `HeadlessPlatform.wait`. A failed post means the count is at its limit, so a wake is
/// pending anyway.
private void wakeHeadless() nothrow
{
    try
    {
        wakes.notify();
    }
    catch (Exception e)
    {
        return;
    }
}
