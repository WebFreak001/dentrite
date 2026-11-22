/// Sliders, a thumb on a horizontal track choosing a number in a range, bound to a numeric signal.
module dentrite.widgets.slider;

import dentrite.immediate;
import dentrite.node;
import dentrite.signals : Signal, effect;
import std.algorithm.comparison : clamp, max;
import std.math : abs, isInfinity, isNaN, round;
import std.traits : isIntegral, isNumeric;

/// Look of a slider.
struct SliderStyle
{
    enum section = "slider"; /// section name in theme files

    Color track = Color(0x3a, 0x3a, 0x40, 0xff);      /// rail
    Color fill = Color(0x3a, 0x7b, 0xe8, 0xff);       /// rail left of the thumb
    Color thumb = Color(0xe4, 0xe4, 0xe8, 0xff);      /// knob
    Color thumbHover = Color(0xff, 0xff, 0xff, 0xff); /// knob under the pointer or dragged
    Color thumbBorder;                                /// knob outline, none when transparent
    Color trackDisabled = Color(0x2e, 0x2e, 0x33, 0xff); /// rail when disabled
    Color fillDisabled = Color(0x4a, 0x4a, 0x52, 0xff);  /// rail left of the thumb when disabled
    Color thumbDisabled = Color(0x60, 0x60, 0x68, 0xff); /// knob when disabled
    Color focus = Color(0x4c, 0x8d, 0xf6, 0xff);      /// focus ring around the knob
    float trackHeight = 4; /// rail thickness
    float thumbSize = 14;  /// knob diameter
    float minWidth = 160;  /// width when the parent leaves the width open
}

/// Range and step of a number, for sliders and spin boxes.
struct NumberRange
{
    double lo;   /// smallest value
    double hi;   /// largest value
    double step; /// values are `lo` plus a multiple of it, any value when 0

    /// `v` clamped to the range and moved to the nearest step.
    double snap(double v) const
    {
        v = clamp(v, lo, hi);
        if (step > 0)
        {
            v = clamp(lo + round((v - lo) / step) * step, lo, hi);
        }
        return v;
    }

    /// Position of `v` in the range, 0 to 1.
    double fraction(double v) const
    {
        return hi > lo ? clamp((v - lo) / (hi - lo), 0, 1) : 0;
    }

    /// Step of the arrow keys: `step`, or a hundredth of the range.
    double keyStep() const
    {
        return step > 0 ? step : (hi - lo) / 100;
    }

    /// Step of Page Up and Page Down: a tenth of the range, at least one key step.
    double pageStep() const
    {
        return max(keyStep, step > 0 ? round((hi - lo) / 10 / step) * step : (hi - lo) / 10);
    }
}

/// Snapping keeps values on the steps and inside the range.
unittest
{
    NumberRange r = NumberRange(0, 10, 4);
    assert(r.snap(5) == 4 && r.snap(7) == 8 && r.snap(11) == 10 && r.snap(-1) == 0);
    assert(r.keyStep == 4 && r.pageStep == 4);
    NumberRange f = NumberRange(0, 1, 0);
    assert(f.snap(0.3) == 0.3 && f.keyStep == 0.01 && f.pageStep == 0.1);
    assert(NumberRange(0, 100, 1).pageStep == 10);
}

/// Size of a slider under `c`.
Size measureSlider(Constraints c, const ref SliderStyle s)
{
    return c.constrain(Size(isInfinity(c.maxW) ? s.minWidth : c.maxW, s.thumbSize));
}

/// Center x of the thumb at `fraction` of a slider in `r`.
float thumbCenter(Rect r, const ref SliderStyle s, double fraction)
{
    return r.x + s.thumbSize / 2 + cast(float)(fraction * max(0f, r.w - s.thumbSize));
}

/// Fraction of the range under window x `wx` in a slider in `r`.
double fractionAt(Rect r, const ref SliderStyle s, float wx)
{
    float span = r.w - s.thumbSize;
    return span > 0 ? clamp((wx - r.x - s.thumbSize / 2) / span, 0, 1) : 0;
}

/// Paints a slider in `r` with the thumb at `fraction`. Shared by the retained node and the island function.
void paintSlider(ref PaintContext ctx, Rect r, const ref SliderStyle s, double fraction, bool hot, bool focused,
    bool enabled)
{
    float th = s.trackHeight;
    float ty = r.y + round((r.h - th) / 2);
    float cx = round(thumbCenter(r, s, fraction));
    ctx.list.rect(Rect(r.x, ty, r.w, th), enabled ? s.track : s.trackDisabled, th / 2);
    if (cx > r.x)
    {
        ctx.list.rect(Rect(r.x, ty, cx - r.x, th), enabled ? s.fill : s.fillDisabled, th / 2);
    }
    float d = s.thumbSize;
    Rect knob = Rect(cx - d / 2, r.y + round((r.h - d) / 2), d, d);
    Color k = enabled == false ? s.thumbDisabled : hot ? s.thumbHover : s.thumb;
    ctx.list.rect(knob, k, d / 2, s.thumbBorder, s.thumbBorder.a > 0 ? 1 : 0);
    if (focused)
    {
        ctx.list.rect(knob.inset(-2), Color.init, d / 2 + 2, s.focus, 1);
    }
}

/// Retained slider. Build it with `slider`.
final class Slider : Node
{
    NumberRange range;   /// range and step
    bool enabled = true; /// accepts input
    private double delegate() read;     /// bound value, tracked
    private void delegate(double) write; /// writes the bound value
    private double shown = 0; /// value last read
    private double before = 0; /// value at the press, put back by Escape
    private float grab = 0;   /// pointer x minus thumb center at the press
    private bool dragging;    /// thumb follows the pointer

    /// Creates a slider over `range`, reading and writing through `read` and `write`. The binding effect belongs
    /// to the current owner.
    this(NumberRange range, double delegate() read, void delegate(double) write)
    {
        this.range = range;
        this.read = read;
        this.write = write;
        interactive = true;
        focusable = true;
        cursor = CursorShape.pointer;
        effect(() {
            double v = read();
            if (v != shown)
            {
                shown = v;
                markNeedsPaint();
            }
        });
    }

    /// Value shown.
    double value() const
    {
        return shown;
    }

    /// Enables or disables.
    void setEnabled(bool on)
    {
        if (on != enabled)
        {
            enabled = on;
            dragging = false;
            markNeedsPaint();
        }
    }

    /// Writes `v` snapped to the range, if it differs from the shown value.
    void set(double v)
    {
        v = range.snap(v);
        if (v != shown)
        {
            write(v);
        }
    }

    /// Slider with its value and range.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.slider;
        describeRange(a, range, shown, enabled);
    }

    /// Steps by the arrow key step, or sets a number.
    override bool accessAction(ref const AccessRequest r)
    {
        if (enabled == false)
        {
            return false;
        }
        switch (r.action)
        {
        case AccessAction.increment:
            set(shown + range.keyStep);
            return true;
        case AccessAction.decrement:
            set(shown - range.keyStep);
            return true;
        case AccessAction.setValue:
            if (isNaN(r.number))
            {
                return false;
            }
            set(r.number);
            return true;
        default:
            return false;
        }
    }

    /// Press on the thumb drags it from where it was taken, a press on the track jumps there first. Moves while
    /// held follow the pointer.
    override bool onPointer(ref const PointerEvent e)
    {
        SliderStyle s = tree.style!SliderStyle();
        Rect r = bounds;
        switch (e.kind)
        {
        case PointerKind.enter:
        case PointerKind.leave:
            markNeedsPaint();
            return true;
        case PointerKind.down:
            if (e.button != 1 || enabled == false)
            {
                return false;
            }
            before = shown;
            float cx = thumbCenter(r, s, range.fraction(shown));
            grab = abs(e.pos.x - cx) <= s.thumbSize / 2 ? e.pos.x - cx : 0;
            dragging = true;
            follow(r, s, e.pos.x);
            markNeedsPaint();
            return true;
        case PointerKind.move:
            if (dragging)
            {
                follow(r, s, e.pos.x);
            }
            return dragging;
        case PointerKind.up:
            dragging = false;
            markNeedsPaint();
            return true;
        default:
            return false;
        }
    }

    /// Sets the value under window x `wx`, less the grab offset.
    private void follow(Rect r, const ref SliderStyle s, float wx)
    {
        set(range.lo + fractionAt(r, s, wx - grab) * (range.hi - range.lo));
    }

    /// Arrows step, Page Up and Page Down move a tenth, Home and End go to the ends, Escape while dragging puts
    /// back the value from before the press.
    override bool onKey(ref const KeyEvent e)
    {
        if (enabled == false)
        {
            return false;
        }
        switch (e.key)
        {
        case Key.left:
        case Key.down:
            set(shown - range.keyStep);
            return true;
        case Key.right:
        case Key.up:
            set(shown + range.keyStep);
            return true;
        case Key.pageDown:
            set(shown - range.pageStep);
            return true;
        case Key.pageUp:
            set(shown + range.pageStep);
            return true;
        case Key.home:
            set(range.lo);
            return true;
        case Key.end:
            set(range.hi);
            return true;
        case Key.escape:
            if (dragging == false)
            {
                return false;
            }
            dragging = false;
            set(before);
            markNeedsPaint();
            return true;
        default:
            return false;
        }
    }

    /// The wheel steps while the slider has focus, so an unfocused one lets the page scroll.
    override bool onWheel(ref const WheelEvent e)
    {
        if (enabled == false || focused == false || e.dy == 0)
        {
            return false;
        }
        set(shown + (e.dy > 0 ? -range.keyStep : range.keyStep));
        return true;
    }

    /// Repaints to show or hide the focus ring.
    override void onFocus(bool gained)
    {
        markNeedsPaint();
    }

    /// Bounded width or the minimum, as tall as the thumb.
    protected override Size performLayout(Constraints c)
    {
        SliderStyle s = tree.style!SliderStyle();
        return measureSlider(c, s);
    }

    /// Track, fill and thumb.
    override void paint(ref PaintContext ctx, Point origin)
    {
        SliderStyle s = ctx.style!SliderStyle();
        paintSlider(ctx, Rect(origin.x, origin.y, size.w, size.h), s, range.fraction(shown),
            enabled && (hovered || dragging), focusRing, enabled);
    }
}

/// Range of a slider over `T`: integers step by at least 1.
private NumberRange rangeOf(T)(T min, T max, T step)
{
    static if (isIntegral!T)
    {
        return NumberRange(min, max, step > 0 ? step : 1);
    }
    else
    {
        return NumberRange(min, max, step > 0 ? step : 0);
    }
}

/// Retained slider choosing `value` between `min` and `max`: `slider(volume, 0, 100)`. Values snap to multiples
/// of `step` from `min`, integers to whole numbers at least. `enabled` greys it out and stops input when false.
Slider slider(T)(Signal!T value, T min, T max, T step = 0, bool delegate() enabled = null,
    string tooltip = null, string accessName = null)
if (isNumeric!T)
{
    Slider n = new Slider(rangeOf(min, max, step), () => cast(double) value.get, (double v) {
        static if (isIntegral!T)
        {
            value.set(cast(T) round(v));
        }
        else
        {
            value.set(cast(T) v);
        }
    });
    n.setTooltip(tooltip);
    n.accessName = accessName;
    if (enabled !is null)
    {
        effect(() { n.setEnabled(enabled()); });
    }
    return n;
}

/// Fills the number, range and step actions of `a`.
void describeRange(ref AccessInfo a, NumberRange range, double value, bool enabled)
{
    a.number = value;
    a.min = range.lo;
    a.max = range.hi;
    a.step = range.keyStep;
    a.disabled = enabled == false;
    a.allow(AccessAction.increment);
    a.allow(AccessAction.decrement);
    a.allow(AccessAction.setValue);
}

/// Paint-only slider declared by an island pass.
final class SliderBox : Node
{
    SliderStyle style; /// style in use, resolved from the theme
    double fraction;   /// thumb position, 0 to 1
    bool hot;          /// pointer over or dragging
    bool enabled;      /// takes input
    bool ring;         /// focused by keyboard

    NumberRange range; /// range, for assistive technologies
    double value;      /// value, for assistive technologies

    /// Creates a box.
    this(SliderStyle style, double fraction, bool hot, bool enabled)
    {
        this.style = style;
        this.fraction = fraction;
        this.hot = hot;
        this.enabled = enabled;
    }

    /// Slider with its value and range.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.slider;
        describeRange(a, range, value, enabled);
    }

    /// Same size as the retained slider.
    protected override Size performLayout(Constraints c)
    {
        return measureSlider(c, style);
    }

    /// Same look as the retained slider.
    override void paint(ref PaintContext ctx, Point origin)
    {
        paintSlider(ctx, Rect(origin.x, origin.y, size.w, size.h), style, fraction, hot, ring, enabled);
    }
}

/// Island slider over `value`, following the pointer while held. With focus, arrows and the wheel step, Page Up
/// and Page Down move a tenth, Home and End go to the ends. True on the passes it changes `value`.
bool slider(T)(Ui ui, ref T value, T min, T max, T step = 0, bool enabled = true, string accessName = null,
    string file = __FILE__, size_t line = __LINE__)
if (isNumeric!T)
{
    Id i = ui.id(file, line);
    Press p = ui.clickable(i, enabled);
    NumberRange range = rangeOf(min, max, step);
    SliderStyle s = ui.style!SliderStyle();
    bool changed;
    double keyed = double.nan;
    if (ui.focusStop(i, enabled))
    {
        double at = range.snap(value);
        if (ui.takeKey(Key.left) || ui.takeKey(Key.down))
        {
            keyed = at - range.keyStep;
        }
        else if (ui.takeKey(Key.right) || ui.takeKey(Key.up))
        {
            keyed = at + range.keyStep;
        }
        else if (ui.takeKey(Key.pageDown))
        {
            keyed = at - range.pageStep;
        }
        else if (ui.takeKey(Key.pageUp))
        {
            keyed = at + range.pageStep;
        }
        else if (ui.takeKey(Key.home))
        {
            keyed = range.lo;
        }
        else if (ui.takeKey(Key.end))
        {
            keyed = range.hi;
        }
        else if (ui.wheelY != 0 && ui.hovered(i))
        {
            keyed = at + (ui.wheelY > 0 ? -range.keyStep : range.keyStep);
            ui.wheelY = 0;
        }
    }
    if (p.held || isNaN(keyed) == false)
    {
        double v = range.snap(isNaN(keyed) ? range.lo + fractionAt(ui.lastRect(i), s, ui.mouse.x)
            * (range.hi - range.lo) : keyed);
        static if (isIntegral!T)
        {
            T t = cast(T) round(v);
        }
        else
        {
            T t = cast(T) v;
        }
        changed = t != value;
        value = t;
        ui.again = ui.again || changed;
    }
    SliderBox n = new SliderBox(s, range.fraction(value), p.hovered || p.held, enabled);
    n.range = range;
    n.value = value;
    n.ring = ui.focusRing(i);
    n.accessName = accessName;
    ui.put(n);
    ui.track(n, i);
    return changed;
}

// A press on the track jumps there, a drag on the thumb keeps the grab offset, keys step and stop at the ends, the
// wheel steps only with focus, Escape during a drag puts the value back, and a disabled slider ignores input.
unittest
{
    import dentrite.containers : column, row;
    import dentrite.host : Host;
    import dentrite.signals : signal;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(300, 100);
    scope (exit)
    {
        h.close();
    }
    Signal!int v = signal(0);
    Signal!bool on = signal(true);
    Slider sl = slider(v, 0, 100, enabled: () => on.get);
    h.setRoot(column()(row()(sl)));
    h.frame();
    SliderStyle s;
    assert(sl.size.w == s.minWidth && sl.size.h == s.thumbSize);
    float span = s.minWidth - s.thumbSize;
    float y = sl.bounds.y + 7;
    float x50 = sl.bounds.x + s.thumbSize / 2 + span / 2;

    h.injectWheel(Point(x50, y), -48);
    assert(v.peek == 0, "the wheel passes an unfocused slider by");
    h.inject(PointerKind.move, Point(x50, y));
    h.inject(PointerKind.down, Point(x50, y));
    assert(v.peek == 50 && h.focused is sl, "the press jumps to the middle");
    h.inject(PointerKind.up, Point(x50, y));
    h.inject(PointerKind.move, Point(x50 + 3, y));
    h.inject(PointerKind.down, Point(x50 + 3, y));
    h.inject(PointerKind.up, Point(x50 + 3, y));
    assert(v.peek == 50, "a press on the thumb does not jump");
    h.inject(PointerKind.down, Point(x50 + 3, y));
    h.inject(PointerKind.move, Point(x50 + 3 + span / 4, y));
    assert(v.peek == 75, "the drag keeps the grab offset");
    h.inject(PointerKind.move, Point(1000, y));
    assert(v.peek == 100, "the drag stops at the end outside the slider");
    h.injectKey(Key.escape, 0);
    assert(v.peek == 50, "Escape puts back the value from before the press");
    h.inject(PointerKind.up, Point(1000, y));

    h.injectKey(Key.right, 0);
    h.injectKey(Key.pageUp, 0);
    assert(v.peek == 61);
    h.injectKey(Key.end, 0);
    h.injectKey(Key.up, 0);
    assert(v.peek == 100);
    h.injectKey(Key.home, 0);
    assert(v.peek == 0);
    h.injectWheel(Point(x50, y), -48);
    h.injectWheel(Point(x50, y), -48);
    h.injectWheel(Point(x50, y), 48);
    assert(v.peek == 1, "the wheel steps a focused slider");
    on.set(false);
    h.injectKey(Key.end, 0);
    h.inject(PointerKind.move, Point(x50, y));
    h.inject(PointerKind.down, Point(x50, y));
    h.inject(PointerKind.up, Point(x50, y));
    assert(v.peek == 1, "disabled");
}
