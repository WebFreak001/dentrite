/// Retained shell with immediate islands: layout nodes running a ddui pass in their rect.
///
/// An island's pass runs inside an effect, so signals it reads invalidate it.
/// A change only marks the island dirty. The pass waits for the next frame.
/// Each island owns a ddui context, which gives it a private ID space and focus.
module hybrid;

import ddui;
import layout;
import signals;
import virtual;
import std.algorithm.comparison : max, min;
import std.format : format;

/// Draw command in the shell's shared list.
struct Cmd
{
    /// Command type.
    enum Kind
    {
        clip, /// set the clip rect
        rect, /// filled rect
        text, /// text at r.x, r.y
    }

    Kind kind;   /// what to draw
    Rect r;      /// clip, fill or text origin
    string text; /// text content
}

/// Layout node whose content is an immediate-mode function.
final class Island : Node
{
    mu_Context* ctx;                           /// private ddui context
    void delegate(mu_Context*, Rect) content;  /// body, runs inside a window covering the island
    bool dirty = true;                         /// needs a pass before the next paint
    int passes;                                /// passes run so far
    private Effect tracker;                    /// fires when a signal read by the last pass changes
    private Rect lastRect;                     /// bounds used by the last pass
    private bool wasDown;                      /// pointer button state last forwarded

    /// Creates an island with its own ddui context.
    this(void delegate(mu_Context*, Rect) content)
    {
        this.content = content;
        ctx = mu_create();
        ctx.text_width = &fixedWidth;
        ctx.text_height = &fixedHeight;
    }

    /// Frees the ddui context and stops tracking.
    void dispose()
    {
        if (tracker !is null)
        {
            tracker.dispose();
        }
        mu_destroy(ctx);
        ctx = null;
    }

    /// Fills whatever space the parent offers.
    protected override Size performLayout(Constraints c)
    {
        return Size(c.maxW == float.infinity ? c.minW : c.maxW,
            c.maxH == float.infinity ? c.minH : c.maxH);
    }

    /// Runs the immediate pass if dirty or moved, re-tracking the signals it reads.
    void update()
    {
        Rect r = bounds;
        if (r != lastRect)
        {
            dirty = true;
        }
        if (dirty == false)
        {
            return;
        }
        dirty = false;
        lastRect = r;
        ++passes;
        if (tracker !is null)
        {
            tracker.dispose();
        }
        bool first = true;
        tracker = effect(() {
            if (first == false)
            {
                dirty = true;
                return;
            }
            first = false;
            pass(r);
        });
    }

    /// One ddui frame with a borderless window pinned to `r`.
    private void pass(Rect r)
    {
        mu_Rect mr = mu_Rect(cast(int) r.x, cast(int) r.y, cast(int) r.w, cast(int) r.h);
        mu_begin(ctx);
        mu_get_container(ctx, "island").rect = mr;
        enum int opt = MU_OPT_NOTITLE | MU_OPT_NORESIZE | MU_OPT_NOFRAME
            | MU_OPT_NOSCROLL | MU_OPT_NOCLOSE;
        if (mu_begin_window_ex(ctx, "island", mr, opt))
        {
            content(ctx, r);
            mu_end_window(ctx);
        }
        mu_end(ctx);
    }

    /// Forwards pointer state in window coordinates and schedules a pass.
    void pointer(Point p, bool down)
    {
        mu_input_mousemove(ctx, cast(int) p.x, cast(int) p.y);
        if (down && wasDown == false)
        {
            mu_input_mousedown(ctx, cast(int) p.x, cast(int) p.y, MU_MOUSE_LEFT);
        }
        else if (down == false && wasDown)
        {
            mu_input_mouseup(ctx, cast(int) p.x, cast(int) p.y, MU_MOUSE_LEFT);
        }
        wasDown = down;
        dirty = true;
    }

    /// Appends the last pass's output to `list`, clipped to the island.
    void paint(ref Cmd[] list)
    {
        Rect box = bounds;
        list ~= Cmd(Cmd.Kind.clip, box);
        mu_Command* c = null;
        while (mu_get_next_command(ctx, &c))
        {
            switch (c.type)
            {
            case MU_COMMAND_CLIP:
                list ~= Cmd(Cmd.Kind.clip, intersect(box, fromMu(c.clip.rect)));
                break;
            case MU_COMMAND_RECT:
                list ~= Cmd(Cmd.Kind.rect, fromMu(c.rect.rect));
                break;
            case MU_COMMAND_TEXT:
                list ~= Cmd(Cmd.Kind.text, Rect(c.text.pos.x, c.text.pos.y),
                    mu_command_text_slice(ctx, c).idup);
                break;
            default:
                break;
            }
        }
    }
}

/// Window-level owner of the tree, routing input and producing one command list per frame.
final class Shell
{
    LayoutOwner layout; /// retained tree and relayout queue
    Island[] islands;   /// immediate nodes in the tree
    Cmd[] commands;     /// output of the last painted frame
    Island capture;     /// island that saw the press, keeps the pointer until release
    private bool layoutChanged = true; /// window or tree geometry changed

    /// Creates a shell for `root` in a window of `size`.
    this(Node root, Size size)
    {
        layout = new LayoutOwner(root, size);
        collect(root);
    }

    /// Finds islands under `n`.
    private void collect(Node n)
    {
        if (Island i = cast(Island) n)
        {
            islands ~= i;
        }
        foreach (Node c; n.children)
        {
            collect(c);
        }
    }

    /// New window size.
    void resize(Size s)
    {
        layout.viewport = s;
        layoutChanged = true;
    }

    /// Routes a pointer event to the captured island, else to the island under `p`.
    void pointer(Point p, bool down)
    {
        Island target = capture;
        if (target is null)
        {
            for (Node n = layout.root.hitTest(p); n !is null; n = n.parent)
            {
                if (Island i = cast(Island) n)
                {
                    target = i;
                    break;
                }
            }
        }
        if (target !is null)
        {
            target.pointer(p, down);
        }
        capture = down ? target : null;
    }

    /// Relayout, island passes, paint. False when nothing changed, so the app can skip rendering.
    bool frame()
    {
        bool relaid = layoutChanged || layout.dirty.length > 0;
        layout.flush();
        layoutChanged = false;
        bool ran;
        foreach (Island i; islands)
        {
            int before = i.passes;
            i.update();
            ran = ran || i.passes != before;
        }
        if (relaid == false && ran == false)
        {
            return false;
        }
        commands.length = 0;
        paint(layout.root);
        return true;
    }

    /// Paints retained nodes directly and islands from their last pass.
    private void paint(Node n)
    {
        if (Island i = cast(Island) n)
        {
            i.paint(commands);
            commands ~= Cmd(Cmd.Kind.clip, Rect(0, 0, layout.viewport.w, layout.viewport.h));
            return;
        }
        if (Text t = cast(Text) n)
        {
            Rect b = t.bounds;
            commands ~= Cmd(Cmd.Kind.text, Rect(b.x, b.y), t.content);
        }
        foreach (Node c; n.children)
        {
            paint(c);
        }
    }
}

/// Hex dump of `memory` from `scrollY`, building only the visible rows.
void hexView(mu_Context* ctx, Rect r, Signal!(ubyte[]) memory, Signal!double scrollY)
{
    enum double rowH = 16;
    ubyte[] mem = memory.get;
    double y = scrollY.get;
    size_t rowCount = (mem.length + 15) / 16;
    RowRange vis = visibleFixed(y, r.h, rowH, rowCount, 0);
    mu_Color fg = ctx.style.colors[MU_COLOR_TEXT];
    foreach (size_t i; vis.first .. vis.last)
    {
        ubyte[] bytes = mem[i * 16 .. min(mem.length, i * 16 + 16)];
        string line = format("%08X  %(%02X %)", i * 16, bytes);
        int top = cast(int)(r.y + i * rowH - y);
        mu_draw_text(ctx, null, line, mu_Vec2(cast(int) r.x + 4, top), fg);
    }
}

/// Intersection of two rects, empty if they do not overlap.
Rect intersect(Rect a, Rect b)
{
    float x0 = max(a.x, b.x);
    float y0 = max(a.y, b.y);
    float x1 = min(a.x + a.w, b.x + b.w);
    float y1 = min(a.y + a.h, b.y + b.h);
    return Rect(x0, y0, max(0f, x1 - x0), max(0f, y1 - y0));
}

/// Layout rect from a ddui rect.
private Rect fromMu(mu_Rect r)
{
    return Rect(r.x, r.y, r.w, r.h);
}

/// Fixed-pitch text width: 8 px per byte.
private extern (C) int fixedWidth(mu_Font, const(char)* s, int len)
{
    import core.stdc.string : strlen;

    return 8 * (len < 0 ? cast(int) strlen(s) : len);
}

/// Fixed line height.
private extern (C) int fixedHeight(mu_Font)
{
    return 16;
}

/// Number of hex rows in `cmds`.
private size_t hexRows(Cmd[] cmds)
{
    size_t n;
    foreach (Cmd c; cmds)
    {
        if (c.kind == Cmd.Kind.text && c.text.length > 10 && c.text[8 .. 10] == "  ")
        {
            ++n;
        }
    }
    return n;
}

/// A memory view island under a header, driven by signals and pointer input.
unittest
{
    Signal!(ubyte[]) memory = signal(new ubyte[1 << 20]);
    Signal!double scrollY = signal(0.0);
    Signal!int unrelated = signal(0);
    Island hex = new Island((mu_Context* ctx, Rect r) { hexView(ctx, r, memory, scrollY); });
    scope (exit)
    {
        hex.dispose();
    }
    Text header = new Text("Memory");
    Shell shell = new Shell(column(cross: CrossAlign.stretch)(header, expanded(hex)), Size(640, 480));

    assert(shell.frame());
    assert(hex.bounds == Rect(0, 16, 640, 464));
    assert(hex.passes == 1);
    assert(shell.commands[1] == Cmd(Cmd.Kind.clip, Rect(0, 16, 640, 464)));
    assert(hexRows(shell.commands) == 30, "464 px of 16 px rows, not 65536 rows");

    assert(shell.frame() == false, "idle");
    unrelated.set(1);
    assert(hex.dirty == false && shell.frame() == false, "signal not read by the island");

    scrollY.set(160_000.0);
    assert(hex.dirty, "read by the last pass");
    assert(hex.passes == 1, "pass deferred to the frame");
    assert(shell.frame() && hex.passes == 2);
    bool found;
    foreach (Cmd c; shell.commands)
    {
        found = found || (c.kind == Cmd.Kind.text && c.text.length > 8
            && c.text[0 .. 8] == "00027100");
    }
    assert(found, "row 10000 at the top");

    shell.pointer(Point(10, 5), true);
    assert(hex.dirty == false, "press on the header, not routed");
    shell.pointer(Point(10, 5), false);
    shell.pointer(Point(100, 100), true);
    assert(hex.dirty && shell.capture is hex);
    shell.pointer(Point(100, 2), true);
    assert(shell.capture is hex, "drag keeps going to the island");
    shell.pointer(Point(100, 2), false);
    assert(shell.capture is null);
    assert(shell.frame());

    shell.resize(Size(640, 240));
    assert(shell.frame() && hex.bounds.h == 224);
    assert(hexRows(shell.commands) == 15);
}
