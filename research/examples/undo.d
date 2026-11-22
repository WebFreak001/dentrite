/// Undo and redo: UI events become messages, messages become reversible commands.
///
/// Widgets only emit `Msg` values. `toCommand` turns them into `Command`
/// objects that `History` applies, merges and reverts. The same path serves an
/// immediate UI (emit on click) and a retained one (emit from a delegate).
module undo;

import std.algorithm.iteration : filter;
import std.algorithm.searching : countUntil;
import std.array : array;
import std.sumtype;

/// Breakpoint in the editable model.
struct Breakpoint
{
    uint id;            /// stable key
    string file;        /// source file
    uint line;          /// source line
    bool enabled = true; /// checkbox state
}

/// Data the commands edit.
final class Model
{
    Breakpoint[] items; /// breakpoints in display order
    string filter;      /// filter text

    /// Index of breakpoint `id`, or -1.
    ptrdiff_t indexOf(uint id)
    {
        foreach (size_t i, ref Breakpoint b; items)
        {
            if (b.id == id)
            {
                return i;
            }
        }
        return -1;
    }
}

/// Checkbox clicked.
struct ToggleMsg
{
    uint id; /// breakpoint
}

/// "Remove disabled" clicked.
struct RemoveDisabledMsg
{
}

/// Filter box edited.
struct FilterMsg
{
    string text; /// new filter text
}

/// Everything the breakpoints panel can ask for.
alias Msg = SumType!(ToggleMsg, RemoveDisabledMsg, FilterMsg);

/// Reversible edit.
interface Command
{
    /// Performs the edit.
    void apply();
    /// Undoes the edit.
    void revert();
    /// Name for the Edit menu.
    string label();
    /// Absorbs `next` if both belong to one gesture, true if merged.
    bool merge(Command next);
}

/// Flips one breakpoint.
final class Toggle : Command
{
    private Model m; /// edited model
    private uint id; /// breakpoint

    /// Creates the command.
    this(Model m, uint id)
    {
        this.m = m;
        this.id = id;
    }

    /// Flips the flag.
    void apply()
    {
        ptrdiff_t i = m.indexOf(id);
        m.items[i].enabled = m.items[i].enabled == false;
    }

    /// Flips it back.
    void revert()
    {
        apply();
    }

    /// Menu text.
    string label()
    {
        return "Toggle breakpoint";
    }

    /// Never merges.
    bool merge(Command next)
    {
        return false;
    }
}

/// Removes disabled breakpoints, remembering where they were.
final class RemoveDisabled : Command
{
    private Model m;             /// edited model
    private Breakpoint[] removed; /// removed items in original order
    private size_t[] at;          /// their original indices

    /// Creates the command.
    this(Model m)
    {
        this.m = m;
    }

    /// Removes and records.
    void apply()
    {
        removed = null;
        at = null;
        foreach (size_t i, ref Breakpoint b; m.items)
        {
            if (b.enabled == false)
            {
                removed ~= b;
                at ~= i;
            }
        }
        m.items = m.items.filter!((ref Breakpoint b) => b.enabled).array;
    }

    /// Reinserts at the recorded indices, lowest first.
    void revert()
    {
        foreach (size_t k, ref Breakpoint b; removed)
        {
            m.items = m.items[0 .. at[k]] ~ b ~ m.items[at[k] .. $];
        }
    }

    /// Menu text.
    string label()
    {
        return "Remove disabled";
    }

    /// Never merges.
    bool merge(Command next)
    {
        return false;
    }
}

/// Sets the filter text. Consecutive edits merge into one undo step.
final class SetFilter : Command
{
    private Model m;     /// edited model
    private string from; /// text before the first edit
    private string to;   /// text after the last edit

    /// Creates the command.
    this(Model m, string to)
    {
        this.m = m;
        this.to = to;
    }

    /// Sets the new text.
    void apply()
    {
        from = from is null ? m.filter : from;
        m.filter = to;
    }

    /// Restores the old text.
    void revert()
    {
        m.filter = from;
    }

    /// Menu text.
    string label()
    {
        return "Edit filter";
    }

    /// Takes over the target text of a following filter edit.
    bool merge(Command next)
    {
        if (SetFilter f = cast(SetFilter) next)
        {
            to = f.to;
            return true;
        }
        return false;
    }
}

/// Several commands undone as one.
final class Compound : Command
{
    private Command[] parts; /// in apply order
    private string name;     /// menu text

    /// Creates an empty group.
    this(string name)
    {
        this.name = name;
    }

    /// Applies parts in order.
    void apply()
    {
        foreach (Command c; parts)
        {
            c.apply();
        }
    }

    /// Reverts parts in reverse order.
    void revert()
    {
        foreach_reverse (Command c; parts)
        {
            c.revert();
        }
    }

    /// Menu text.
    string label()
    {
        return name;
    }

    /// Never merges.
    bool merge(Command next)
    {
        return false;
    }
}

/// Command for a UI message.
Command toCommand(Model m, Msg msg)
{
    return msg.match!(
        (ToggleMsg t) => cast(Command) new Toggle(m, t.id),
        (RemoveDisabledMsg r) => cast(Command) new RemoveDisabled(m),
        (FilterMsg f) => cast(Command) new SetFilter(m, f.text),
    );
}

/// Undo and redo stacks with merging and groups.
final class History
{
    private Command[] done;    /// applied, newest last
    private Command[] undone;  /// reverted, newest last
    private Compound group;    /// open group, or null
    private bool mergeOpen;    /// the top command may absorb the next one

    /// Applies `c` and records it, merging with the previous command when allowed.
    void run(Command c)
    {
        c.apply();
        undone = null;
        if (group !is null)
        {
            group.parts ~= c;
            return;
        }
        if (mergeOpen && done.length > 0 && done[$ - 1].merge(c))
        {
            return;
        }
        done ~= c;
        mergeOpen = true;
    }

    /// Ends the current gesture so the next command starts a new undo step.
    void seal()
    {
        mergeOpen = false;
    }

    /// Starts grouping commands under `label`.
    void begin(string label)
    {
        group = new Compound(label);
    }

    /// Closes the group as one undo step.
    void end()
    {
        Compound g = group;
        group = null;
        if (g.parts.length > 0)
        {
            done ~= g;
            mergeOpen = false;
        }
    }

    /// Reverts the newest step, false if there is none.
    bool undo()
    {
        if (done.length == 0)
        {
            return false;
        }
        Command c = done[$ - 1];
        done.length -= 1;
        c.revert();
        undone ~= c;
        mergeOpen = false;
        return true;
    }

    /// Re-applies the newest undone step, false if there is none.
    bool redo()
    {
        if (undone.length == 0)
        {
            return false;
        }
        Command c = undone[$ - 1];
        undone.length -= 1;
        c.apply();
        done ~= c;
        mergeOpen = false;
        return true;
    }

    /// "Undo ..." menu text, or null.
    string undoLabel()
    {
        return done.length > 0 ? "Undo " ~ done[$ - 1].label : null;
    }
}

/// Three breakpoints.
private Model sample()
{
    Model m = new Model;
    m.items = [
        Breakpoint(1, "main.d", 10),
        Breakpoint(2, "main.d", 42),
        Breakpoint(3, "lexer.d", 3),
    ];
    return m;
}

/// Toggle and remove, undone and redone in order.
unittest
{
    Model m = sample();
    History h = new History;
    h.run(toCommand(m, Msg(ToggleMsg(2))));
    h.seal();
    h.run(toCommand(m, Msg(RemoveDisabledMsg())));
    h.seal();
    assert(m.items.length == 2);
    assert(h.undoLabel == "Undo Remove disabled");
    assert(h.undo());
    assert(m.items.length == 3 && m.items[1].id == 2, "back in place");
    assert(h.undo());
    assert(m.items[1].enabled);
    assert(h.undo() == false);
    assert(h.redo() && h.redo());
    assert(m.items.length == 2);
}

/// Typing merges into one step until the gesture is sealed.
unittest
{
    Model m = sample();
    History h = new History;
    foreach (string s; ["m", "ma", "mai", "main"])
    {
        h.run(toCommand(m, Msg(FilterMsg(s))));
    }
    h.seal();
    h.run(toCommand(m, Msg(FilterMsg("main.d"))));
    assert(m.filter == "main.d");
    assert(h.undo() && m.filter == "main");
    assert(h.undo() && m.filter == "");
}

/// A new command after undo drops the redo stack. Groups undo as one.
unittest
{
    Model m = sample();
    History h = new History;
    h.begin("Disable all");
    foreach (ref Breakpoint b; m.items.dup)
    {
        h.run(toCommand(m, Msg(ToggleMsg(b.id))));
    }
    h.end();
    assert(m.items[0].enabled == false && m.items[2].enabled == false);
    assert(h.undoLabel == "Undo Disable all");
    assert(h.undo());
    assert(m.items[0].enabled && m.items[2].enabled);
    h.run(toCommand(m, Msg(ToggleMsg(1))));
    assert(h.redo() == false);
}
