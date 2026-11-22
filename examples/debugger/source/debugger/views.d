/// Island views of the debugger: disassembly, memory and console.
///
/// Each is plain immediate code over the session. Rows are virtualized: only the
/// visible ones are shaped and drawn. View state (scroll, selection, follow)
/// lives in per-ID memory. Input is tested against last pass's canvas rect.
module debugger.views;

import core.time : MonoTime;
import debugger.model;
import dentrite.draw;
import dentrite.immediate;
import dentrite.node;
import dentrite.text;
import dentrite.virtual : RowRange, visibleFixed;
import dentrite.widgets.button;
import dentrite.widgets.checkbox;
import dentrite.widgets.icons;
import dentrite.widgets.label;
import std.algorithm.comparison : clamp, max, min;
import std.format : format;
import std.math : floor, round;

/// Look of code, memory and log views.
struct CodeStyle
{
    enum section = "code"; /// theme section

    Color background = Color(0x1c, 0x1c, 0x20, 0xff); /// view background
    Color gutter = Color(0x22, 0x22, 0x27, 0xff);     /// breakpoint gutter
    Color address = Color(0x7d, 0x7d, 0x88, 0xff);    /// addresses
    Color bytes = Color(0x5a, 0x5a, 0x64, 0xff);      /// encoded bytes
    Color mnemonic = Color(0x6a, 0xa5, 0xff, 0xff);   /// operation
    Color operand = Color(0xd2, 0xd2, 0xd8, 0xff);    /// operands, hex bytes
    Color pcRow = Color(0xf2, 0xb9, 0x50, 0x1f);      /// row of the current instruction
    Color pcArrow = Color(0xf2, 0xb9, 0x50, 0xff);    /// current instruction marker
    Color hoverRow = Color(0xff, 0xff, 0xff, 0x0a);   /// row under the pointer
    Color selectedRow = Color(0x3b, 0x82, 0xf6, 0x2e); /// selected row or byte
    Color breakpoint = Color(0xe5, 0x48, 0x4d, 0xff); /// enabled breakpoint dot
    Color breakpointOff = Color(0x5a, 0x5a, 0x64, 0xff); /// disabled breakpoint dot
    Color changed = Color(0xf2, 0xb9, 0x50, 0xff);    /// recently written bytes
    Color ascii = Color(0xa3, 0xa3, 0xad, 0xff);      /// printable bytes
    Color info = Color(0xd2, 0xd2, 0xd8, 0xff);       /// log text
    Color warn = Color(0xf2, 0xb9, 0x50, 0xff);       /// log warnings
    Color error = Color(0xf4, 0x7a, 0x7a, 0xff);      /// log errors
    Color time = Color(0x5a, 0x5a, 0x64, 0xff);       /// log timestamps
    float rowHeight = 18;  /// row pitch
    float gutterWidth = 22; /// breakpoint gutter
    FontKind font = FontKind.mono; /// code font
    float size = 12.5;     /// code size
}

/// Scroll state shared by the row views.
private struct RowView
{
    double scrollY = 0; /// distance scrolled
    long selected = -1; /// selected row, -1 for none
    bool follow = true; /// keep the interesting row in view
}

/// Moves `v` so row `i` is visible, centered when it was far.
private void reveal(ref RowView v, size_t i, float rowH, float viewH, bool center)
{
    double top = i * rowH;
    if (center && (top < v.scrollY || top + rowH > v.scrollY + viewH))
    {
        v.scrollY = top - viewH / 3;
    }
    else if (top < v.scrollY)
    {
        v.scrollY = top;
    }
    else if (top + rowH > v.scrollY + viewH)
    {
        v.scrollY = top + rowH - viewH;
    }
}

/// Clamps the scroll of `v` to `count` rows in a `viewH` tall view.
private void clampScroll(ref RowView v, size_t count, float rowH, float viewH)
{
    v.scrollY = clamp(v.scrollY, 0.0, max(0.0, count * rowH - viewH));
}

/// Arrow, page, home and end keys moving the selection of `v`. True if any moved it.
private bool navigate(Ui ui, ref RowView v, size_t count, float rowH, float viewH)
{
    if (count == 0)
    {
        return false;
    }
    long page = max(1, cast(long)(viewH / rowH) - 1);
    long sel = v.selected < 0 ? cast(long)(v.scrollY / rowH) : v.selected;
    bool moved;
    if (ui.takeKey(Key.down))
    {
        sel += 1;
        moved = true;
    }
    if (ui.takeKey(Key.up))
    {
        sel -= 1;
        moved = true;
    }
    if (ui.takeKey(Key.pageDown))
    {
        sel += page;
        moved = true;
    }
    if (ui.takeKey(Key.pageUp))
    {
        sel -= page;
        moved = true;
    }
    if (ui.takeKey(Key.home, Mod.ctrl))
    {
        sel = 0;
        moved = true;
    }
    if (ui.takeKey(Key.end, Mod.ctrl))
    {
        sel = count - 1;
        moved = true;
    }
    if (moved)
    {
        v.selected = clamp(sel, 0, cast(long) count - 1);
        reveal(v, cast(size_t) v.selected, rowH, viewH, false);
        v.follow = false;
    }
    return moved;
}

/// Disassembly: breakpoint gutter, PC marker, address, bytes and text. Click the gutter or press F9
/// to toggle a breakpoint. Follows the PC, and jumps to the breakpoint selected in the panel.
void disassembly(Ui ui, Session s)
{
    CodeStyle cs = ui.style!CodeStyle();
    RowView* v = ui.memoryFor!RowView(ui.id(__FILE__, __LINE__), RowView.init);
    uint* seenSelection = ui.memoryFor!uint(ui.id(__FILE__, __LINE__), 0);
    ulong pc = s.pc.get;
    size_t pcIndex = s.program.indexOf(pc);
    Breakpoint[] bps = s.breakpoints.get;
    uint sel = s.selected.get;
    bool[ulong] armed;
    foreach (Breakpoint b; bps)
    {
        armed[b.addr] = b.enabled.get;
    }
    const(Instr)[] code = s.program.code;

    ui.panel("header", {
        ui.row(gap: 10)({
            ui.checkbox(v.follow, "Follow PC");
            ui.spacer();
            ui.label(format("PC %016X", pc), "mono");
        });
    });
    ui.expand({
        float rowH = cs.rowHeight;
        Point mouse = ui.mouse;
        CanvasState c = ui.canvas((ref PaintContext ctx, Rect r) {
            paintDisassembly(ctx, r, cs, *v, code, pcIndex, armed, mouse);
        });
        Rect r = c.rect;
        if (r.empty)
        {
            ui.requestFrame();
            return;
        }
        if (sel != *seenSelection)
        {
            *seenSelection = sel;
            foreach (Breakpoint b; bps)
            {
                if (b.id == sel)
                {
                    v.selected = s.program.indexOf(b.addr);
                    v.follow = false;
                    reveal(*v, cast(size_t) v.selected, rowH, r.h, true);
                }
            }
        }
        if (r.contains(ui.mouse) && ui.wheelY != 0)
        {
            v.scrollY += ui.wheelY;
            v.follow = false;
        }
        if (c.press.pressedNow)
        {
            size_t row = cast(size_t)((ui.mouse.y - r.y + v.scrollY) / rowH);
            if (row < code.length)
            {
                if (ui.mouse.x < r.x + cs.gutterWidth)
                {
                    s.toggleAt(code[row].addr);
                }
                else
                {
                    v.selected = row;
                }
            }
        }
        if (ui.focused)
        {
            navigate(ui, *v, code.length, rowH, r.h);
            if (ui.takeKey(0x40000042) && v.selected >= 0)
            {
                s.toggleAt(code[cast(size_t) v.selected].addr);
            }
        }
        if (v.follow)
        {
            reveal(*v, pcIndex, rowH, r.h, true);
        }
        clampScroll(*v, code.length, rowH, r.h);
    });
}

/// Paints the visible disassembly rows.
private void paintDisassembly(ref PaintContext ctx, Rect r, const ref CodeStyle cs, const ref RowView v,
    const(Instr)[] code, size_t pcIndex, bool[ulong] armed, Point mouse)
{
    TextSystem t = ctx.text;
    float rowH = cs.rowHeight;
    float adv = t.measure(cs.font, cs.size, "0");
    float ascent = t.ascent(cs.font, cs.size);
    float textTop = round((rowH - t.lineHeight(cs.font, cs.size)) / 2);
    ctx.list.rect(r, cs.background);
    ctx.list.rect(Rect(r.x, r.y, cs.gutterWidth, r.h), cs.gutter);
    RowRange vis = visibleFixed(v.scrollY, r.h, rowH, code.length, 0);
    float xAddr = r.x + cs.gutterWidth + 8;
    float xBytes = xAddr + adv * 10;
    float xText = xBytes + adv * 22;
    foreach (size_t i; vis.first .. vis.last)
    {
        const Instr ins = code[i];
        float y = round(r.y + i * rowH - v.scrollY);
        Rect row = Rect(r.x + cs.gutterWidth, y, r.w - cs.gutterWidth, rowH);
        if (i == pcIndex)
        {
            ctx.list.rect(row, cs.pcRow);
        }
        if (i == v.selected)
        {
            ctx.list.rect(row, cs.selectedRow);
        }
        else if (Rect(r.x, y, r.w, rowH).contains(mouse))
        {
            ctx.list.rect(row, cs.hoverRow);
        }
        if (bool* on = ins.addr in armed)
        {
            float d = rowH * 0.55f;
            paintIcon(*ctx.list, Icon.breakpoint, Rect(r.x + (cs.gutterWidth - d) / 2, y + (rowH - d) / 2, d, d),
                *on ? cs.breakpoint : cs.breakpointOff);
        }
        if (i == pcIndex)
        {
            float d = rowH * 0.5f;
            float ax = r.x + cs.gutterWidth - 2;
            float ay = y + rowH / 2;
            ctx.list.polygon([Point(ax - d, ay - d / 2), Point(ax, ay), Point(ax - d, ay + d / 2)], cs.pcArrow);
        }
        float base = y + textTop + ascent;
        ctx.list.text(t.shape(cs.font, cs.size, format("%08X", ins.addr)), Point(xAddr, base), cs.address);
        ctx.list.text(t.shape(cs.font, cs.size, ins.bytes), Point(xBytes, base), cs.bytes);
        ctx.list.text(t.shape(cs.font, cs.size, ins.mnemonic), Point(xText, base), cs.mnemonic);
        if (ins.operands.length > 0)
        {
            ctx.list.text(t.shape(cs.font, cs.size, ins.operands), Point(xText + adv * 7, base), cs.operand);
        }
    }
}

/// Per-byte write heat of the memory view, decaying after each snapshot.
private final class Heat
{
    immutable(ubyte)[] last; /// previous snapshot
    float[] level;           /// 1 just written, 0 cold
    MonoTime at;             /// time of the last decay
}

/// Memory view: 16 bytes per row with ASCII, recently written bytes glow and fade.
/// Click selects a byte, arrows move it while focused.
void memoryView(Ui ui, Session s)
{
    CodeStyle cs = ui.style!CodeStyle();
    RowView* v = ui.memoryFor!RowView(ui.id(__FILE__, __LINE__), RowView(0, -1, false));
    Heat* heatSlot = ui.memoryFor!Heat(ui.id(__FILE__, __LINE__), null);
    if (*heatSlot is null)
    {
        *heatSlot = new Heat;
    }
    Heat heat = *heatSlot;
    immutable(ubyte)[] mem = s.memory.get;
    if (heat.level.length != mem.length)
    {
        heat.level = new float[mem.length];
        heat.level[] = 0;
        heat.last = mem;
        heat.at = ui.now;
    }
    double dt = (ui.now - heat.at).total!"usecs" / 1e6;
    heat.at = ui.now;
    bool warm;
    foreach (size_t i, ref float h; heat.level)
    {
        if (heat.last !is mem && heat.last[i] != mem[i])
        {
            h = 1;
        }
        else if (h > 0)
        {
            h = max(0f, h - cast(float) dt / 1.5f);
        }
        warm = warm || h > 0;
    }
    heat.last = mem;
    if (warm)
    {
        ui.requestFrame();
    }
    size_t rows = (mem.length + 15) / 16;
    long* selByte = ui.memoryFor!long(ui.id(__FILE__, __LINE__), -1);

    ui.panel("header", {
        ui.row(gap: 10)({
            ui.label("Stack", "strong");
            ui.label(format("%016X", s.memoryBase), "monoMuted");
            ui.spacer();
            if (*selByte >= 0 && *selByte < mem.length)
            {
                ubyte b = mem[cast(size_t) *selByte];
                ui.label(format("%016X = %02X  %d", s.memoryBase + *selByte, b, b), "mono");
            }
        });
    });
    ui.expand({
        float rowH = cs.rowHeight;
        Point mouse = ui.mouse;
        CanvasState c = ui.canvas((ref PaintContext ctx, Rect r) {
            paintMemory(ctx, r, cs, *v, mem, heat.level, s.memoryBase, *selByte, mouse);
        });
        Rect r = c.rect;
        if (r.empty)
        {
            ui.requestFrame();
            return;
        }
        if (r.contains(ui.mouse) && ui.wheelY != 0)
        {
            v.scrollY += ui.wheelY;
        }
        if (c.press.pressedNow)
        {
            long hit = byteAt(ui, r, cs, *v, ui.mouse);
            if (hit >= 0 && hit < mem.length)
            {
                *selByte = hit;
            }
        }
        if (ui.focused && *selByte >= 0)
        {
            long b = *selByte;
            b += ui.takeKey(Key.right) ? 1 : 0;
            b -= ui.takeKey(Key.left) ? 1 : 0;
            b += ui.takeKey(Key.down) ? 16 : 0;
            b -= ui.takeKey(Key.up) ? 16 : 0;
            if (b != *selByte)
            {
                *selByte = clamp(b, 0, cast(long) mem.length - 1);
                reveal(*v, cast(size_t)(*selByte / 16), rowH, r.h, false);
            }
        }
        clampScroll(*v, rows, rowH, r.h);
    });
}

/// Column of the first hex digit of byte `col` in a row, in characters from the address.
private size_t hexColumn(size_t col)
{
    return 18 + col * 3 + (col >= 8 ? 1 : 0);
}

/// Byte under window point `p`, or -1.
private long byteAt(Ui ui, Rect r, const ref CodeStyle cs, const ref RowView v, Point p)
{
    float adv = ui.tree.text.measure(cs.font, cs.size, "0");
    long row = cast(long) floor((p.y - r.y + v.scrollY) / cs.rowHeight);
    float x = p.x - r.x - 8;
    foreach (size_t col; 0 .. 16)
    {
        float cx = hexColumn(col) * adv;
        if (x >= cx - adv * 0.5f && x < cx + adv * 2.5f)
        {
            return row * 16 + col;
        }
    }
    return -1;
}

/// Paints the visible memory rows.
private void paintMemory(ref PaintContext ctx, Rect r, const ref CodeStyle cs, const ref RowView v,
    immutable(ubyte)[] mem, const float[] heat, ulong base, long selected, Point mouse)
{
    TextSystem t = ctx.text;
    float rowH = cs.rowHeight;
    float adv = t.measure(cs.font, cs.size, "0");
    float ascent = t.ascent(cs.font, cs.size);
    float textTop = round((rowH - t.lineHeight(cs.font, cs.size)) / 2);
    ctx.list.rect(r, cs.background);
    size_t rows = (mem.length + 15) / 16;
    RowRange vis = visibleFixed(v.scrollY, r.h, rowH, rows, 0);
    float x0 = r.x + 8;
    foreach (size_t i; vis.first .. vis.last)
    {
        float y = round(r.y + i * rowH - v.scrollY);
        float baseLine = y + textTop + ascent;
        size_t from = i * 16;
        size_t to = min(mem.length, from + 16);
        char[] hex;
        char[] ascii;
        foreach (size_t k; from .. to)
        {
            if (k == from + 8)
            {
                hex ~= ' ';
            }
            hex ~= format("%02X ", mem[k]);
            ubyte b = mem[k];
            ascii ~= b >= 0x20 && b < 0x7f ? cast(char) b : '.';
        }
        foreach (size_t k; from .. to)
        {
            Rect cell = Rect(x0 + hexColumn(k - from) * adv - 2, y + 1, adv * 2 + 4, rowH - 2);
            if (heat[k] > 0)
            {
                ctx.list.rect(cell, cs.changed.fade(0.35f * heat[k]), 3);
            }
            if (k == selected)
            {
                ctx.list.rect(cell, cs.selectedRow, 3, cs.mnemonic, 1);
            }
            else if (cell.contains(mouse))
            {
                ctx.list.rect(cell, cs.hoverRow, 3);
            }
        }
        ctx.list.text(t.shape(cs.font, cs.size, format("%016X", base + from)), Point(x0, baseLine), cs.address);
        ctx.list.text(t.shape(cs.font, cs.size, hex.idup), Point(x0 + hexColumn(0) * adv, baseLine), cs.operand);
        ctx.list.text(t.shape(cs.font, cs.size, ascii.idup), Point(x0 + (hexColumn(15) + 4) * adv, baseLine),
            cs.ascii);
    }
}

/// Console: the log with timestamps, colored by level, following new lines while at the bottom.
void console(Ui ui, Session s)
{
    CodeStyle cs = ui.style!CodeStyle();
    RowView* v = ui.memoryFor!RowView(ui.id(__FILE__, __LINE__), RowView.init);
    size_t n = s.logCount.get;
    LogLine[] lines = s.log;

    ui.panel("header", {
        ui.row(gap: 10)({
            ui.label(format("%,d lines", n), "muted");
            ui.spacer();
            ui.checkbox(v.follow, "Follow");
            if (ui.button("Clear", variant: "toolbar"))
            {
                s.log = null;
                s.logCount.set(0);
            }
        });
    });
    ui.expand({
        float rowH = cs.rowHeight;
        CanvasState c = ui.canvas((ref PaintContext ctx, Rect r) { paintConsole(ctx, r, cs, *v, lines); });
        Rect r = c.rect;
        if (r.empty)
        {
            ui.requestFrame();
            return;
        }
        if (r.contains(ui.mouse) && ui.wheelY != 0)
        {
            v.scrollY += ui.wheelY;
            v.follow = v.scrollY >= lines.length * rowH - r.h - 1;
        }
        if (ui.focused)
        {
            navigate(ui, *v, lines.length, rowH, r.h);
        }
        if (v.follow)
        {
            v.scrollY = lines.length * rowH - r.h;
        }
        clampScroll(*v, lines.length, rowH, r.h);
    });
}

/// Paints the visible log lines.
private void paintConsole(ref PaintContext ctx, Rect r, const ref CodeStyle cs, const ref RowView v,
    const(LogLine)[] lines)
{
    TextSystem t = ctx.text;
    float rowH = cs.rowHeight;
    float adv = t.measure(cs.font, cs.size, "0");
    float ascent = t.ascent(cs.font, cs.size);
    float textTop = round((rowH - t.lineHeight(cs.font, cs.size)) / 2);
    ctx.list.rect(r, cs.background);
    RowRange vis = visibleFixed(v.scrollY, r.h, rowH, lines.length, 0);
    foreach (size_t i; vis.first .. vis.last)
    {
        float y = round(r.y + i * rowH - v.scrollY);
        if (i == v.selected)
        {
            ctx.list.rect(Rect(r.x, y, r.w, rowH), cs.selectedRow);
        }
        float base = y + textTop + ascent;
        const LogLine l = lines[i];
        Color c = l.level == Level.error ? cs.error : l.level == Level.warn ? cs.warn : cs.info;
        ctx.list.text(t.shape(cs.font, cs.size, format("%9.3f", l.time)), Point(r.x + 8, base), cs.time);
        ctx.list.text(t.shape(cs.font, cs.size, l.text), Point(r.x + 8 + adv * 11, base), c);
    }
}
