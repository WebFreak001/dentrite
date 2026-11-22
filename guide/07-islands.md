# 7. Islands

An island is a node whose content is plain immediate-mode code. Each pass
declares its widgets again, from whatever data it reads. The widgets are
the same node classes as the retained ones, so islands share the layout,
theme and renderer, and look the same.

Use islands for views drawn from data that changes as a whole, such as a
disassembly, a memory view, a chart or a debug panel. Keep forms and long
lived controls retained.

<!-- src="examples/source/guide/islands.d" from="Node sensorView(" -->
```d
/// Island over `s`: a row per sensor, a toggle and a slider kept in locals, and a chart drawn on a canvas.
Node sensorView(Sensors s)
{
    bool smooth = true;
    float scale = 1;
    return island((Ui ui) {
        ui.padded(12, 10, {
            ui.column(gap: 8)({
                ui.row(gap: 12)({
                    ui.checkbox(smooth, "Smooth");
                    ui.label("Scale", "muted");
                    ui.slider(scale, 0.5f, 2f, 0.25f);
                    ui.label(format("%gx", scale), "monoMuted");
                });
                foreach (string name; s.names.get)
                {
                    ui.pushId(hashOf(name));
                    sensorRow(ui, s, name);
                    ui.popId();
                }
                double[] v = s.samples.get;
                ui.canvas((ref PaintContext ctx, Rect r) { paintChart(ctx, r, v, smooth, scale); }, h: 80);
            });
        });
    });
}
```

## When a pass runs

A pass runs on the first frame, after input inside the island, and when a
signal it read with `get` changes. The pass above reads `s.names` and
`s.samples`, so setting either runs it again. Nothing else does: an island
over plain fields shows stale data until something else wakes it.

A pass that handled input runs again before painting, so a click shows its
result in the same frame.

## State

Island widgets take their value by `ref` and return true when the user
changed it or clicked: `ui.checkbox(smooth, "Smooth")`, `if
(ui.button("Remove"))`. Values that belong to the view live in locals the
closure captures, such as `smooth` and `scale` above.

Widgets are told apart by an ID made from the file and line of the call.
Calls in a loop share a line, so give each iteration a key of its own with
`pushId` and `popId`:

<!-- src="examples/source/guide/islands.d" from="void sensorRow(" -->
```d
/// Row of sensor `name`: its name and a remove button. Called in a loop, inside `pushId`.
void sensorRow(Ui ui, Sensors s, string name)
{
    ui.row(gap: 8)({
        ui.expand({ ui.label(name); });
        if (ui.button("Remove", variant: "toolbar"))
        {
            s.names.set(s.names.peek.filter!(n => n != name).array);
        }
    });
}
```

A function of your own that holds state takes the caller's file and line,
and keeps the state with `memoryFor`. Each call site gets its own:

<!-- src="examples/source/guide/islands.d" from="bool counterButton(" -->
```d
/// Island function with state of its own, kept in the island's memory under its call site.
bool counterButton(Ui ui, string caption, string file = __FILE__, size_t line = __LINE__)
{
    int* n = ui.memoryFor(0, file, line);
    bool clicked = ui.button(format("%s (%d)", caption, *n), file: file, line: line);
    if (clicked)
    {
        ++*n;
    }
    return clicked;
}
```

## Canvases

`ui.canvas(painter, w:, h:)` reserves a box and paints it with draw calls
on `ctx.list`: `rect`, `hline`, `vline`, `polyline`, `polygon`, `text`,
`image` and clipping. It returns a `CanvasState` with the rect from the
last pass and the pointer state, for hit testing: `if (c.press.clicked)`
with `ui.mouse` gives a click position. `ui.takeKey(Key.left)` takes a key
press while the island has focus.

<!-- src="examples/source/guide/islands.d" from="void paintChart(" -->
```d
/// Line through `v` across `r`, each point averaged with its neighbors when `smooth`, scaled by `scale`. The
/// alarm look shows once a scaled reading passes 1.
void paintChart(ref PaintContext ctx, Rect r, const double[] v, bool smooth, float scale)
{
    bool alarm;
    foreach (double x; v)
    {
        alarm = alarm || x * scale > 1;
    }
    ChartStyle s = ctx.style!ChartStyle(alarm ? "alarm" : null);
    ctx.list.rect(r, s.background, 4);
    if (v.length < 2)
    {
        return;
    }
    Point[] pts;
    foreach (size_t i, double x; v)
    {
        double y = smooth && i > 0 && i + 1 < v.length ? (v[i - 1] + x + v[i + 1]) / 3 : x;
        pts ~= Point(r.x + r.w * i / (v.length - 1), r.bottom - cast(float)(r.h * y * scale));
    }
    ctx.list.pushClip(r);
    ctx.list.polyline(pts, s.width, s.line);
    ctx.list.popClip();
}
```

`ctx.style!ChartStyle(variant)` reads a style from the theme, see
[chapter 8](08-themes.md).

## Layout and popups

`ui.row`, `ui.column`, `ui.padded`, `ui.expand`, `ui.spacer` and
`ui.panel` mirror the retained containers, with children in a delegate.
`ui.comboBox` and `ui.menuButton` open popups, and
`ui.contextMenu(menu)({ ... })` gives an area a context menu, using the
retained `Menu` of chapter 6.

The island itself fills the space it is offered. Where the parent leaves
an axis open, as a column does for height, it takes `island(content, h:
200)`, and a debug build asserts when it would be 0. Placing it in
`expanded` or `sized` works too.

NOTE: `import dentrite.containers : column;` makes `column` a symbol of
your module, which hides the island `column` of `dentrite.immediate`, so
`ui.column(...)` fails to compile. Import `dentrite.containers` whole.

## Raw views

`new RawView(&draw, animating)` (`dentrite.island`) hands its rect to a
callback that draws with the renderer's API, such as GL, for 3D views. The
debugger example's viewport is one. The software renderer leaves the area
empty.
