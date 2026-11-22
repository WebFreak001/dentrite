/// Chapter 7: islands, immediate-mode code inside the retained tree.
module guide.islands;

import dentrite.containers;
import dentrite.draw;
import dentrite.immediate;
import dentrite.island : island, Island;
import dentrite.node;
import dentrite.signals;
import dentrite.widgets.button;
import dentrite.widgets.checkbox;
import dentrite.widgets.label;
import dentrite.widgets.slider;
import std.algorithm.comparison : max;
import std.algorithm.iteration : filter;
import std.array : array;
import std.format : format;

/// Look of the sensor chart, theme section `[chart]`.
struct ChartStyle
{
    enum section = "chart"; /// theme section

    /// Theme variants.
    enum Variants
    {
        alarm, /// a reading is past the limit
    }

    Color background = Color(0x17, 0x17, 0x1a, 0xff); /// behind the line
    Color line = Color(0x3b, 0x82, 0xf6, 0xff);       /// the readings
    float width = 1.5;                                /// line width
}

/// Sensor readings, written by the app, read by the island.
final class Sensors
{
    Signal!(string[]) names;   /// sensors shown
    Signal!(double[]) samples; /// last readings, 1 is the limit

    /// Sensors `names`, no readings yet.
    this(string[] names)
    {
        this.names = signal(names);
        samples = signal(cast(double[]) null);
    }
}

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

/// A pass runs again when a signal it read changes, and buttons in a loop act on their own row.
unittest
{
    import dentrite.host : Host;
    import guide.harness;

    Host h = testHost(500, 400);
    scope (exit)
    {
        h.close();
    }
    Sensors s = new Sensors(["Inlet", "Outlet", "Pump"]);
    s.samples = signal([0.2, 0.4, 0.3, 0.8]);
    Island isl;
    scope Scope root = effectScope(() {
        isl = cast(Island) sensorView(s);
        h.setRoot(isl);
    });
    h.frame();
    int passes = isl.passes;
    s.samples.set([0.5, 0.5]);
    h.frame();
    assert(isl.passes == passes + 1, "reading the signal subscribed the pass");
    h.frame();
    assert(isl.passes == passes + 1, "nothing changed, no pass");

    h.click(Role.button, "Remove");
    assert(s.names.peek == ["Outlet", "Pump"], "the first row's button");
    assert(shows(h, Role.label, "Inlet") == false);
}

/// Each call site of `counterButton` keeps its own count.
unittest
{
    import dentrite.host : Host;
    import guide.harness;

    Host h = testHost(300, 200);
    scope (exit)
    {
        h.close();
    }
    h.setRoot(island((Ui ui) {
        ui.column(gap: 4)({
            counterButton(ui, "Apples");
            counterButton(ui, "Pears");
        });
    }));
    h.frame();
    h.click(Role.button, "Apples (0)");
    h.click(Role.button, "Apples (1)");
    assert(shows(h, Role.button, "Apples (2)") && shows(h, Role.button, "Pears (0)"));
}
