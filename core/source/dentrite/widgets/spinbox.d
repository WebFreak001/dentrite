/// Spin box: a number in a text box with up and down buttons, bound to a numeric signal.
///
/// Typed text is taken on Enter, on leaving the box and before a step, then shown again in the box's format.
/// Escape puts back the value's text.
module dentrite.widgets.spinbox;

import core.time : msecs;
import dentrite.node;
import dentrite.signals : Signal, effect, signal;
import dentrite.text;
import dentrite.widgets.icons;
import dentrite.widgets.slider : NumberRange, describeRange;
import dentrite.widgets.textbox : TextBox, TextBoxStyle;
import std.algorithm.comparison : max;
import std.math : abs, ceil, isNaN, round;
import std.traits : isFloatingPoint, isIntegral, isNumeric;

/// Look and timing of a spin box. The field itself uses `TextBoxStyle`.
struct SpinBoxStyle
{
    enum section = "spinbox"; /// section name in theme files

    Color arrow;                                          /// arrows, the text box text color when transparent
    Color buttonHover = Color(0xff, 0xff, 0xff, 0x14);    /// button under the pointer
    Color buttonPressed = Color(0xff, 0xff, 0xff, 0x24);  /// button held
    Color divider;                                        /// line left of the buttons, the box border when transparent
    float buttonWidth = 18; /// width of the button column
    float arrowSize = 7;    /// size of each arrow
    float minWidth = 64;    /// narrowest box
    int repeatDelay = 400;  /// milliseconds a held button waits before repeating
    int repeatInterval = 50; /// milliseconds between repeats
}

/// Text box of a spin box. The spin box sees keys first, typing is limited to number characters.
private final class SpinEdit : TextBox
{
    private SpinBox spin; /// box holding it

    /// Text box over `text` inside `spin`.
    this(SpinBox spin, Signal!string text)
    {
        super(text, null);
        this.spin = spin;
    }

    /// Step and commit keys, then editing keys.
    override bool onKey(ref const KeyEvent e)
    {
        if (enabled && spin.key(e))
        {
            return true;
        }
        return super.onKey(e);
    }

    /// Typed digits, and a sign or point where the range and format allow them.
    override bool onText(string s)
    {
        string kept;
        foreach (char c; s)
        {
            if ((c >= '0' && c <= '9') || (c == '-' && spin.range.lo < 0) || (c == '.' && spin.decimals > 0))
            {
                kept ~= c;
            }
        }
        return kept.length == 0 || super.onText(kept);
    }

    /// Commits the text when focus leaves.
    override void onFocus(bool gained)
    {
        super.onFocus(gained);
        if (gained == false)
        {
            spin.commit();
        }
    }
}

/// Retained spin box. Build it with `spinBox`.
final class SpinBox : Node
{
    NumberRange range;  /// range and step
    int decimals;       /// digits after the point
    private double delegate() read;      /// bound value, tracked
    private void delegate(double) write; /// writes the bound value
    private double shown = 0;            /// value last read
    private Signal!string text;          /// text of `edit`
    private SpinEdit edit;               /// the field
    private int hot;                     /// button under the pointer: 1 up, -1 down, 0 none
    private int held;                    /// button held: 1 up, -1 down, 0 none

    /// Box over `range` with `decimals` digits, reading and writing through `read` and `write`. The binding
    /// effects belong to the current owner.
    this(NumberRange range, int decimals, double delegate() read, void delegate(double) write)
    {
        this.range = range;
        this.decimals = decimals;
        this.read = read;
        this.write = write;
        interactive = true;
        keepFocus = true;
        text = signal("");
        edit = new SpinEdit(this, text);
        add(edit);
        effect(() {
            shown = read();
            text.set(formatted(shown));
        });
    }

    /// Value shown.
    double value() const
    {
        return shown;
    }

    /// The text field, for focus.
    TextBox field()
    {
        return edit;
    }

    /// True while it takes input.
    bool enabled()
    {
        return edit.enabled;
    }

    /// Enables or disables.
    void setEnabled(bool on)
    {
        edit.setEnabled(on);
        if (on == false)
        {
            held = 0;
        }
        markNeedsPaint();
    }

    /// `v` in the box's format.
    string formatted(double v) const
    {
        import std.format : format;

        return format("%.*f", decimals, v);
    }

    /// Value of the typed text, or NaN when it is not a number.
    private double typed()
    {
        import std.conv : ConvException, to;
        import std.string : strip;

        try
        {
            return edit.text.strip.to!double;
        }
        catch (ConvException)
        {
            return double.nan;
        }
    }

    /// Spin button with its value and range. The field inside stays out.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.spinButton;
        describeRange(a, range, shown, enabled);
        a.value = edit.text;
        a.leaf = true;
        a.allow(AccessAction.focus);
    }

    /// Steps, sets a number, or focuses the field.
    override bool accessAction(ref const AccessRequest r)
    {
        if (enabled == false)
        {
            return false;
        }
        switch (r.action)
        {
        case AccessAction.increment:
            stepBy(1);
            return true;
        case AccessAction.decrement:
            stepBy(-1);
            return true;
        case AccessAction.setValue:
            if (isNaN(r.number))
            {
                return false;
            }
            set(r.number);
            return true;
        case AccessAction.focus:
            if (tree.services !is null)
            {
                tree.services.setFocus(edit);
            }
            return true;
        default:
            return false;
        }
    }

    /// Writes `v` snapped to the range, then shows the value's text with the caret at the end.
    private void set(double v)
    {
        v = range.snap(v);
        if (v != shown)
        {
            write(v);
        }
        text.set(formatted(shown));
        edit.caret = edit.anchor = edit.text.length;
    }

    /// Takes the typed text, or puts back the value's text when it is not a number.
    void commit()
    {
        double v = typed();
        set(isNaN(v) ? shown : v);
    }

    /// Moves `n` steps from the typed value, or from the value when the text is not a number.
    void stepBy(double n)
    {
        double v = typed();
        set((isNaN(v) ? shown : v) + n * range.keyStep);
    }

    /// Up and Down step, Page Up and Page Down step a tenth of the range, Enter commits, Escape puts back the
    /// value's text. True if it took `e`.
    private bool key(ref const KeyEvent e)
    {
        switch (e.key)
        {
        case Key.up:
            stepBy(1);
            return true;
        case Key.down:
            stepBy(-1);
            return true;
        case Key.pageUp:
            stepBy(range.pageStep / range.keyStep);
            return true;
        case Key.pageDown:
            stepBy(-range.pageStep / range.keyStep);
            return true;
        case Key.enter:
            commit();
            return true;
        case Key.escape:
            if (edit.text == formatted(shown))
            {
                return false;
            }
            text.set(formatted(shown));
            edit.caret = edit.anchor = edit.text.length;
            return true;
        default:
            return false;
        }
    }

    /// Button column in window coordinates.
    private Rect buttons()
    {
        SpinBoxStyle s = tree.style!SpinBoxStyle();
        Rect b = bounds;
        return Rect(b.right - s.buttonWidth, b.y, s.buttonWidth, b.h);
    }

    /// Button under window point `p`: 1 up, -1 down, 0 none.
    private int buttonAt(Point p)
    {
        Rect z = buttons;
        if (z.contains(p) == false)
        {
            return 0;
        }
        return p.y < z.y + z.h / 2 ? 1 : -1;
    }

    /// The buttons belong to the box, the rest to the text box.
    override Node hitTest(Point p, Point origin)
    {
        if (tree !is null)
        {
            SpinBoxStyle s = tree.style!SpinBoxStyle();
            if (Rect(origin.x + size.w - s.buttonWidth, origin.y, s.buttonWidth, size.h).contains(p))
            {
                return this;
            }
        }
        return super.hitTest(p, origin);
    }

    /// Hover on the buttons, a press steps, focuses the field and repeats while held.
    override bool onPointer(ref const PointerEvent e)
    {
        switch (e.kind)
        {
        case PointerKind.enter:
        case PointerKind.move:
        case PointerKind.leave:
            int at = e.kind == PointerKind.leave ? 0 : buttonAt(e.pos);
            if (at != hot)
            {
                hot = at;
                markNeedsPaint();
            }
            return true;
        case PointerKind.down:
            if (e.button != 1 || enabled == false)
            {
                return false;
            }
            held = buttonAt(e.pos);
            if (held == 0)
            {
                return false;
            }
            if (tree.services !is null)
            {
                tree.services.setFocus(edit);
                SpinBoxStyle s = tree.style!SpinBoxStyle();
                tree.callAt(this, tree.services.now + s.repeatDelay.msecs, &repeat);
            }
            stepBy(held);
            markNeedsPaint();
            return true;
        case PointerKind.cancel:
        case PointerKind.up:
            held = 0;
            if (tree !is null)
            {
                tree.cancelCall(this);
            }
            markNeedsPaint();
            return true;
        default:
            return false;
        }
    }

    /// Steps again while the button is held under the pointer, and schedules the next repeat.
    private void repeat()
    {
        if (held == 0 || tree is null || tree.services is null)
        {
            return;
        }
        if (hot == held)
        {
            stepBy(held);
        }
        SpinBoxStyle s = tree.style!SpinBoxStyle();
        tree.callAt(this, tree.services.now + s.repeatInterval.msecs, &repeat);
    }

    /// The wheel steps while the field has focus.
    override bool onWheel(ref const WheelEvent e)
    {
        if (enabled == false || edit.focused == false || e.dy == 0)
        {
            return false;
        }
        stepBy(e.dy > 0 ? -1 : 1);
        return true;
    }

    /// A width from the parent, else wide enough for the longest number of the range. As tall as a text box.
    protected override Size performLayout(Constraints c)
    {
        SpinBoxStyle s = tree.style!SpinBoxStyle();
        TextBoxStyle ts = tree.style!TextBoxStyle();
        TextSystem t = tree.text;
        float w = c.minW;
        if (c.minW != c.maxW)
        {
            float digits = max(t.measure(ts.font, ts.size, formatted(range.lo), ts.features),
                t.measure(ts.font, ts.size, formatted(range.hi), ts.features));
            w = max(c.minW, s.minWidth, ceil(digits + ts.padX * 2 + s.buttonWidth + 1));
        }
        Size sz = c.constrain(Size(w, t.lineHeight(ts.font, ts.size) + ts.padY * 2));
        edit.trailing = s.buttonWidth;
        edit.offset = Point.init;
        edit.layout(Constraints.tight(sz));
        return sz;
    }

    /// The field, then the button column with its divider and arrows.
    override void paint(ref PaintContext ctx, Point origin)
    {
        paintChildren(ctx, origin);
        SpinBoxStyle s = ctx.style!SpinBoxStyle();
        TextBoxStyle ts = ctx.style!TextBoxStyle();
        Rect z = Rect(origin.x + size.w - s.buttonWidth, origin.y, s.buttonWidth, size.h);
        float half = round(z.h / 2);
        Rect up = Rect(z.x + 1, z.y + 1, z.w - 2, half - 1);
        Rect down = Rect(z.x + 1, z.y + half, z.w - 2, z.h - half - 1);
        ctx.list.vline(z.x, z.y + 1, z.bottom - 1, s.divider.a > 0 ? s.divider : ts.border);
        foreach (int b; [1, -1])
        {
            Rect r = b > 0 ? up : down;
            if (enabled && held == b)
            {
                ctx.list.rect(r, s.buttonPressed, 2);
            }
            else if (enabled && hot == b)
            {
                ctx.list.rect(r, s.buttonHover, 2);
            }
            Color ac = enabled == false ? ts.textDisabled : s.arrow.a > 0 ? s.arrow : ts.text;
            float a = s.arrowSize;
            Rect icon = Rect(r.x + round((r.w - a) / 2), r.y + round((r.h - a) / 2) + (b > 0 ? 1 : -1), a, a);
            paintIcon(*ctx.list, b > 0 ? Icon.chevronUp : Icon.chevronDown, icon, ac);
        }
    }
}

/// Digits after the point needed to show multiples of `step`, at most 6.
private int decimalsOf(double step)
{
    int d;
    double x = abs(step);
    while (d < 6 && abs(x - round(x)) > 1e-9)
    {
        x *= 10;
        ++d;
    }
    return d;
}

/// Retained spin box choosing `value` between `min` and `max` in multiples of `step` from `min`:
/// `spinBox(port, 1, 65535)`. `decimals` defaults to what `step` needs. `enabled` greys it out and stops input
/// when false.
SpinBox spinBox(T)(Signal!T value, T min, T max, T step = 1, int decimals = -1, bool delegate() enabled = null,
    string tooltip = null, string accessName = null)
if (isNumeric!T)
{
    static if (isIntegral!T)
    {
        int digits = 0;
        NumberRange range = NumberRange(min, max, step > 0 ? step : 1);
    }
    else
    {
        int digits = decimals >= 0 ? decimals : decimalsOf(step);
        NumberRange range = NumberRange(min, max, step > 0 ? step : 0);
    }
    SpinBox b = new SpinBox(range, digits, () => cast(double) value.get, (double v) {
        static if (isIntegral!T)
        {
            value.set(cast(T) round(v));
        }
        else
        {
            value.set(cast(T) v);
        }
    });
    b.setTooltip(tooltip);
    b.field.setTooltip(tooltip);
    b.accessName = accessName;
    if (enabled !is null)
    {
        effect(() { b.setEnabled(enabled()); });
    }
    return b;
}

// Keys step and stop at the ends, typed text commits on Enter snapped to the step, Escape puts the text back,
// the up button steps once per press, the format follows the step, and a disabled box ignores input.
unittest
{
    import dentrite.containers : CrossAlign, column;
    import dentrite.host : Host;
    import dentrite.widgets.menu : menuHost;

    Host h = menuHost(300, 100);
    scope (exit)
    {
        h.close();
    }
    Signal!int n = signal(4);
    Signal!bool on = signal(true);
    Signal!double f = signal(0.25);
    SpinBox b = spinBox(n, 0, 10, 2, enabled: () => on.get);
    SpinBox fb = spinBox(f, 0.0, 1.0, 0.05);
    SpinBox wide = spinBox(n, -100_000, 100_000);
    h.setRoot(column(gap: 4, cross: CrossAlign.start)(b, fb, wide));
    h.frame();
    SpinBoxStyle s;
    assert(b.size.w == s.minWidth && b.field.text == "4" && fb.field.text == "0.25");
    assert(wide.size.w > s.minWidth, "wide enough for -100000");

    h.setFocus(b.field);
    h.injectKey(Key.up, 0);
    assert(n.peek == 6 && b.field.text == "6");
    h.injectKey(Key.pageUp, 0);
    h.injectKey(Key.up, 0);
    assert(n.peek == 10, "stops at the end");

    h.injectKey(Key.a, Mod.ctrl);
    h.injectText("7x-");
    assert(b.field.text == "7", "letters and a sign below zero are not typed");
    h.injectKey(Key.enter, 0);
    assert(n.peek == 8 && b.field.text == "8", "7 snaps to 8");
    h.injectText("1");
    h.injectKey(Key.escape, 0);
    assert(b.field.text == "8" && n.peek == 8);

    Rect z = b.bounds;
    Point upAt = Point(z.right - s.buttonWidth / 2, z.y + 3);
    h.inject(PointerKind.move, upAt);
    h.inject(PointerKind.down, upAt);
    h.inject(PointerKind.up, upAt);
    assert(n.peek == 10 && h.focused is b.field);

    h.injectKey(Key.a, Mod.ctrl);
    h.injectText("3");
    h.setFocus(fb.field);
    assert(n.peek == 4, "leaving the box commits");
    h.injectKey(Key.down, 0);
    assert(fb.field.text == "0.20" && abs(f.peek - 0.2) < 1e-9);

    on.set(false);
    assert(h.focused is fb.field);
    h.setFocus(b.field);
    h.injectKey(Key.up, 0);
    h.inject(PointerKind.move, upAt);
    h.inject(PointerKind.down, upAt);
    h.inject(PointerKind.up, upAt);
    assert(n.peek == 4, "disabled");
}
