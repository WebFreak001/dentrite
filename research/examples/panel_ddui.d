/// Breakpoints panel in immediate mode on ddui, headless.
///
/// The application owns all state. The panel function reads and writes it
/// directly every frame. Tests drive ddui with synthetic input and read the
/// command list back, the way a renderer would.
module panel_ddui;

import ddui;
import std.algorithm.iteration : filter;
import std.algorithm.searching : canFind;
import std.array : array;
import std.format : format;
import std.string : fromStringz;

/// Breakpoint as plain data. `enabled` is an int because `mu_checkbox` binds one.
struct Breakpoint
{
    uint id;         /// stable key
    string file;     /// source file
    uint line;       /// source line
    int enabled = 1; /// checkbox state
    uint hits;       /// hit count, written by the debugger
}

/// Application state shown by the panel.
struct PanelState
{
    Breakpoint[] items; /// every breakpoint
    /// Filter text box buffer.
    /// NOTE: explicit zero, `char.init` is 0xFF and mu_textbox wants a C string.
    char[64] filter = '\0';
}

/// Emits the panel. Called once per frame between mu_begin and mu_end.
void breakpointsPanel(mu_Context* ctx, ref PanelState st)
{
    if (mu_begin_window_ex(ctx, "Breakpoints", mu_Rect(0, 0, 400, 300), MU_OPT_NOCLOSE) == 0)
    {
        return;
    }
    scope (exit)
    {
        mu_end_window(ctx);
    }

    static immutable int[2] filterRow = [56, -1];
    mu_layout_row(ctx, 2, filterRow.ptr, 0);
    mu_label(ctx, "Filter");
    mu_textbox(ctx, st.filter.ptr, cast(int) st.filter.length);
    const(char)[] q = fromStringz(st.filter.ptr);

    static immutable int[3] cols = [24, -64, -1];
    size_t shown;
    foreach (ref Breakpoint bp; st.items)
    {
        if (q.length > 0 && canFind(bp.file, q) == false)
        {
            continue;
        }
        ++shown;
        mu_push_id(ctx, &bp.id, cast(int) bp.id.sizeof);
        mu_layout_row(ctx, 3, cols.ptr, 0);
        mu_checkbox(ctx, "", &bp.enabled);
        mu_label(ctx, format("%s:%d", bp.file, bp.line));
        mu_label(ctx, format("%d", bp.hits));
        mu_pop_id(ctx);
    }

    static immutable int[2] footer = [-130, -1];
    mu_layout_row(ctx, 2, footer.ptr, 0);
    mu_label(ctx, format("%d of %d shown", shown, st.items.length));
    if (mu_button(ctx, "Remove disabled"))
    {
        st.items = st.items.filter!((ref Breakpoint b) => b.enabled != 0).array;
    }
}

/// Fixed-pitch text width for tests: 8 px per byte.
private extern (C) int fakeWidth(mu_Font, const(char)* s, int len)
{
    return 8 * (len < 0 ? cast(int) fromStringz(s).length : len);
}

/// Fixed line height for tests.
private extern (C) int fakeHeight(mu_Font)
{
    return 16;
}

/// Context with test text metrics.
private mu_Context* makeContext()
{
    mu_Context* ctx = mu_create();
    ctx.text_width = &fakeWidth;
    ctx.text_height = &fakeHeight;
    return ctx;
}

/// Runs one frame.
private void frame(mu_Context* ctx, ref PanelState st)
{
    mu_begin(ctx);
    breakpointsPanel(ctx, st);
    mu_end(ctx);
}

/// Every string drawn this frame, in z order.
private string[] texts(mu_Context* ctx)
{
    string[] r;
    mu_Command* cmd = null;
    while (mu_get_next_command(ctx, &cmd))
    {
        if (cmd.type == MU_COMMAND_TEXT)
        {
            r ~= mu_command_text_slice(ctx, cmd).idup;
        }
    }
    return r;
}

/// Screen position of the first text equal to `s`.
private mu_Vec2 find(mu_Context* ctx, string s)
{
    mu_Command* cmd = null;
    while (mu_get_next_command(ctx, &cmd))
    {
        if (cmd.type == MU_COMMAND_TEXT && mu_command_text_slice(ctx, cmd) == s)
        {
            return cmd.text.pos;
        }
    }
    assert(false, "text not drawn: " ~ s);
}

/// Five breakpoints across three files.
private PanelState sample()
{
    PanelState st;
    st.items = [
        Breakpoint(1, "main.d", 10),
        Breakpoint(2, "main.d", 42),
        Breakpoint(3, "parser.d", 7),
        Breakpoint(4, "parser.d", 99),
        Breakpoint(5, "lexer.d", 3),
    ];
    return st;
}

/// Idle frames produce identical output, a hit count change does not.
unittest
{
    mu_Context* ctx = makeContext();
    scope (exit)
    {
        mu_destroy(ctx);
    }
    PanelState st = sample();
    frame(ctx, st);
    assert(mu_frame_dirty(ctx));
    assert(find(ctx, "Remove disabled") == mu_Vec2(260, 175));
    frame(ctx, st);
    assert(mu_frame_dirty(ctx), "settles: scrollbar check used last frame's zero body");
    assert(find(ctx, "Remove disabled") == mu_Vec2(272, 175));
    assert(canFind(texts(ctx), "5 of 5 shown"));
    frame(ctx, st);
    assert(mu_frame_dirty(ctx) == false, "nothing changed, skip rendering");
    st.items[2].hits = 7;
    frame(ctx, st);
    assert(mu_frame_dirty(ctx));
    assert(canFind(texts(ctx), "7"));
}

/// Filtering is plain code over plain data.
unittest
{
    mu_Context* ctx = makeContext();
    scope (exit)
    {
        mu_destroy(ctx);
    }
    PanelState st = sample();
    st.filter[0 .. 5] = "main\0";
    frame(ctx, st);
    string[] t = texts(ctx);
    assert(canFind(t, "2 of 5 shown"));
    assert(canFind(t, "lexer.d:3") == false);
}

/// Clicking "Remove disabled": hover in one frame, press in the next.
unittest
{
    mu_Context* ctx = makeContext();
    scope (exit)
    {
        mu_destroy(ctx);
    }
    PanelState st = sample();
    st.items[1].enabled = 0;
    frame(ctx, st);
    frame(ctx, st);
    mu_Vec2 p = find(ctx, "Remove disabled"); // after the settle frame, see above
    mu_input_mousemove(ctx, p.x + 2, p.y + 2);
    frame(ctx, st);
    frame(ctx, st);
    mu_input_mousedown(ctx, p.x + 2, p.y + 2, MU_MOUSE_LEFT);
    frame(ctx, st);
    mu_input_mouseup(ctx, p.x + 2, p.y + 2, MU_MOUSE_LEFT);
    frame(ctx, st);
    assert(st.items.length == 4);
    assert(canFind(texts(ctx), "4 of 4 shown"));
}
