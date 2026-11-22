/// Progress bar: a filled fraction of a track, or a moving segment while the amount of work is unknown.
module dentrite.widgets.progress;

import core.time : MonoTime, msecs;
import dentrite.immediate;
import dentrite.node;
import dentrite.signals : effect;
import std.algorithm.comparison : clamp, max, min;
import std.math : isInfinity, isNaN, round;

/// Look of a progress bar.
struct ProgressStyle
{
    enum section = "progress"; /// section name in theme files

    Color track = Color(0x3a, 0x3a, 0x40, 0xff); /// color of the unfilled part
    Color fill = Color(0x3a, 0x7b, 0xe8, 0xff);  /// done part and the busy segment
    float height = 6;     /// bar thickness
    float radius = 3;     /// corner radius
    float minWidth = 160; /// width when the parent leaves the width open
    float busyWidth = 0.3; /// busy segment as a fraction of the bar
    int busyPeriod = 1400; /// milliseconds for the busy segment to cross the bar
}

/// Size of a progress bar under `c`.
Size measureProgress(Constraints c, const ref ProgressStyle s)
{
    return c.constrain(Size(isInfinity(c.maxW) ? s.minWidth : c.maxW, s.height));
}

/// Position of the busy segment at time `t` since `start`, 0 to 1.
double busyPhase(const ref ProgressStyle s, MonoTime start, MonoTime t)
{
    long period = max(1, s.busyPeriod);
    return cast(double)((t - start).total!"msecs" % period) / period;
}

/// Paints a bar in `r` filled to `value`, 0 to 1, or the busy segment at `phase` when `value` is NaN. Shared by
/// the retained node and the island function.
void paintProgress(ref PaintContext ctx, Rect r, const ref ProgressStyle s, double value, double phase)
{
    ctx.list.rect(r, s.track, s.radius);
    if (isNaN(value))
    {
        float seg = round(r.w * s.busyWidth);
        float x = r.x - seg + cast(float)(phase * (r.w + seg));
        float a = max(x, r.x);
        float b = min(x + seg, r.right);
        if (b > a)
        {
            ctx.list.rect(Rect(a, r.y, b - a, r.h), s.fill, s.radius);
        }
        return;
    }
    float w = round(r.w * cast(float) clamp(value, 0, 1));
    if (w > 0)
    {
        ctx.list.rect(Rect(r.x, r.y, max(w, min(r.w, s.radius * 2)), r.h), s.fill, s.radius);
    }
}

/// Retained progress bar. Build it with `progressBar`.
final class ProgressBar : Node
{
    private double shown = 0; /// value last read, NaN while busy
    private MonoTime start;   /// busy animation start

    /// Creates a bar following `value`. The binding effect belongs to the current owner.
    this(double delegate() value)
    {
        repaintBoundary = true;
        effect(() {
            double v = value();
            if (isNaN(v) != isNaN(shown) || (isNaN(v) == false && v != shown))
            {
                if (isNaN(v) && tree !is null && tree.services !is null)
                {
                    start = tree.services.now;
                }
                shown = v;
                markNeedsPaint();
            }
        });
    }

    /// Value shown, NaN while busy.
    double value() const
    {
        return shown;
    }

    /// Progress from 0 to 1, no number while busy.
    override void describe(ref AccessInfo a)
    {
        describeProgress(a, shown);
    }

    /// Bounded width or the minimum, as tall as the style's bar.
    protected override Size performLayout(Constraints c)
    {
        ProgressStyle s = tree.style!ProgressStyle();
        return measureProgress(c, s);
    }

    /// Track and fill, or the busy segment with a repaint scheduled for the next frame.
    override void paint(ref PaintContext ctx, Point origin)
    {
        ProgressStyle s = ctx.style!ProgressStyle();
        double phase = 0;
        if (isNaN(shown) && tree.services !is null)
        {
            MonoTime now = tree.services.now;
            if (start == MonoTime.init)
            {
                start = now;
            }
            phase = busyPhase(s, start, now);
            markNeedsPaintAt(now + 16.msecs);
        }
        paintProgress(ctx, Rect(origin.x, origin.y, size.w, size.h), s, shown, phase);
    }
}

/// Retained progress bar filled to `value`, 0 to 1, or busy while it is NaN: `progressBar(() => done.get / 40.0)`.
ProgressBar progressBar(double delegate() value, string tooltip = null, string accessName = null)
{
    ProgressBar p = new ProgressBar(value);
    p.setTooltip(tooltip);
    p.accessName = accessName;
    return p;
}

/// Fills `a` for a bar at `value`, NaN while busy.
private void describeProgress(ref AccessInfo a, double value)
{
    a.role = Role.progressIndicator;
    a.number = value;
    a.min = 0;
    a.max = 1;
}

/// Paint-only progress bar declared by an island pass.
final class ProgressBox : Node
{
    ProgressStyle style; /// style in use, resolved from the theme
    double value;        /// 0 to 1, NaN while busy
    double phase;        /// busy segment position along the bar, 0 to 1

    /// Creates a box.
    this(ProgressStyle style, double value, double phase)
    {
        this.style = style;
        this.value = value;
        this.phase = phase;
    }

    /// Progress from 0 to 1, no number while busy.
    override void describe(ref AccessInfo a)
    {
        describeProgress(a, value);
    }

    /// Same size as the retained bar.
    protected override Size performLayout(Constraints c)
    {
        return measureProgress(c, style);
    }

    /// Same look as the retained bar.
    override void paint(ref PaintContext ctx, Point origin)
    {
        paintProgress(ctx, Rect(origin.x, origin.y, size.w, size.h), style, value, phase);
    }
}

/// Island progress bar filled to `value`, 0 to 1, or busy while it is NaN, which asks for a pass every frame.
void progressBar(Ui ui, double value)
{
    ProgressStyle s = ui.style!ProgressStyle();
    double phase = 0;
    if (isNaN(value))
    {
        phase = busyPhase(s, MonoTime.zero, MonoTime.currTime);
        ui.requestFrame();
    }
    ui.put(new ProgressBox(s, value, phase));
}

// The bar follows its value, the fill covers the done fraction, and the busy segment crosses once a period.
unittest
{
    import dentrite.containers : column;
    import dentrite.draw : DrawList;
    import dentrite.host : Host;
    import dentrite.signals : Signal, signal;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(300, 100);
    scope (exit)
    {
        h.close();
    }
    Signal!double v = signal(0.25);
    ProgressBar p = progressBar(() => v.get);
    h.setRoot(column()(p));
    h.frame();
    ProgressStyle s;
    assert(p.size == Size(300, s.height) && p.value == 0.25);

    PaintContext ctx;
    DrawList list;
    ctx.list = &list;
    paintProgress(ctx, Rect(0, 0, 200, 6), s, 0.25, 0);
    assert(list.cmds.length == 2 && list.cmds[1].r.w == 50);
    list.clear();
    paintProgress(ctx, Rect(0, 0, 200, 6), s, double.nan, 0.5);
    assert(list.cmds.length == 2 && list.cmds[1].r == Rect(70, 0, 60, 6), "busy segment centered at half");

    v.set(double.nan);
    assert(isNaN(p.value));
    MonoTime t0 = MonoTime.currTime;
    assert(busyPhase(s, t0, t0 + 700.msecs) == 0.5 && busyPhase(s, t0, t0 + 1400.msecs) == 0);
    h.frame();
    v.set(1);
    h.frame();
    assert(p.value == 1);
}
