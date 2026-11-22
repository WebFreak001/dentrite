/// Radio buttons: one choice among options, bound to a signal the group shares.
///
/// A group is the sibling radios bound to the same signal. Arrow keys move the choice inside it, and Tab stops
/// only at the chosen radio, or at the first one when none is chosen.
module dentrite.widgets.radio;

import dentrite.containers : CrossAlign, Flex, column, row;
import dentrite.immediate;
import dentrite.node;
import dentrite.signals : Signal, effect;
import dentrite.text;
import dentrite.widgets.button : PressBehavior;
import std.algorithm.comparison : max;
import std.math : round;

/// Look of a radio button.
struct RadioStyle
{
    enum section = "radio"; /// section name in theme files

    Color box = Color(0x2a, 0x2a, 0x2e, 0xff);       /// unchosen fill
    Color boxHover = Color(0x34, 0x34, 0x39, 0xff);  /// unchosen fill under the pointer
    Color border = Color(0x60, 0x60, 0x66, 0xff);    /// unchosen outline
    Color checked = Color(0x3a, 0x7b, 0xe8, 0xff);   /// chosen fill
    Color checkedHover = Color(0x4c, 0x8d, 0xf6, 0xff); /// chosen fill under the pointer
    Color dot = Color(0xff, 0xff, 0xff, 0xff);       /// dot of the chosen radio
    Color boxDisabled = Color(0x26, 0x26, 0x29, 0xff); /// fill when disabled
    Color text = Color(0xdd, 0xdd, 0xdd, 0xff);      /// caption
    Color textDisabled = Color(0x80, 0x80, 0x80, 0xff); /// caption and dot when disabled
    Color focus = Color(0x4c, 0x8d, 0xf6, 0xff);     /// focus ring
    float boxSize = 14; /// circle diameter
    float dotSize = 6;  /// dot diameter
    float gap = 6;      /// space between the circle and the caption
    FontKind font = FontKind.ui; /// caption font
    float size = 13;    /// caption size
}

/// Size of a radio with `caption`.
Size measureRadio(TextSystem t, const ref RadioStyle s, string caption)
{
    if (caption.length == 0)
    {
        return Size(s.boxSize, s.boxSize);
    }
    return Size(s.boxSize + s.gap + t.measure(s.font, s.size, caption),
        max(s.boxSize, t.lineHeight(s.font, s.size)));
}

/// Paints a radio in `r`. Shared by the retained node and the island function.
void paintRadio(ref PaintContext ctx, Rect r, const ref RadioStyle s, string caption, bool on, bool hovered,
    bool focused, bool enabled)
{
    float by = r.y + round((r.h - s.boxSize) / 2);
    Rect box = Rect(r.x, by, s.boxSize, s.boxSize);
    float half = s.boxSize / 2;
    if (enabled == false)
    {
        ctx.list.rect(box, s.boxDisabled, half, s.border, 1);
    }
    else if (on)
    {
        ctx.list.rect(box, hovered ? s.checkedHover : s.checked, half);
    }
    else
    {
        ctx.list.rect(box, hovered ? s.boxHover : s.box, half, s.border, 1);
    }
    if (on)
    {
        float d = s.dotSize;
        Rect dot = Rect(box.x + (s.boxSize - d) / 2, box.y + (s.boxSize - d) / 2, d, d);
        ctx.list.rect(dot, enabled ? s.dot : s.textDisabled, d / 2);
    }
    if (focused)
    {
        ctx.list.rect(box.inset(-2), Color.init, half + 2, s.focus, 1);
    }
    if (caption.length > 0)
    {
        TextSystem t = ctx.text;
        float top = r.y + round((r.h - t.lineHeight(s.font, s.size)) / 2);
        ctx.list.text(t.shape(s.font, s.size, caption), Point(box.right + s.gap, top + t.ascent(s.font, s.size)),
            enabled ? s.text : s.textDisabled);
    }
}

/// Retained radio button. Build it with `radio` or `radioGroup`.
final class Radio : Node
{
    string caption;      /// text after the circle
    bool enabled = true; /// accepts clicks and keys
    private Object group;           /// signal the group shares
    private bool delegate() isOn;   /// true when the signal holds this radio's option, tracked
    private void delegate() choose; /// writes this radio's option
    private bool shown;             /// state last read from `isOn`

    mixin PressBehavior;

    /// Creates a radio. Radios given the same `group` object form one group. The binding effect belongs to the
    /// current owner.
    this(Object group, bool delegate() isOn, void delegate() choose, string caption)
    {
        this.group = group;
        this.isOn = isOn;
        this.choose = choose;
        this.caption = caption;
        interactive = true;
        focusable = true;
        cursor = CursorShape.pointer;
        effect(() {
            bool v = isOn();
            if (v != shown)
            {
                shown = v;
                markNeedsPaint();
            }
        });
    }

    /// True while the signal holds this radio's option.
    bool chosen() const
    {
        return shown;
    }

    /// Chooses this radio's option.
    void activate()
    {
        choose();
    }

    /// Enables or disables.
    void setEnabled(bool on)
    {
        if (on != enabled)
        {
            enabled = on;
            markNeedsPaint();
        }
    }

    /// Radio button named by its caption, with its place in the group.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.radioButton;
        a.label = caption;
        a.toggled = shown ? Toggle.on : Toggle.off;
        a.disabled = enabled == false;
        a.allow(AccessAction.click);
        Radio[] g = members();
        foreach (size_t i, Radio r; g)
        {
            if (r is this)
            {
                a.position = cast(uint) i + 1;
            }
        }
        a.setSize = cast(uint) g.length;
    }

    /// Radios of the group, in sibling order.
    Radio[] members()
    {
        if (parent is null)
        {
            return [this];
        }
        Radio[] g;
        foreach (Node c; parent.children)
        {
            Radio r = cast(Radio) c;
            if (r !is null && r.group is group)
            {
                g ~= r;
            }
        }
        return g;
    }

    /// The chosen radio, or the first when none of the group is chosen.
    override bool tabStop()
    {
        if (focusable == false)
        {
            return false;
        }
        if (shown)
        {
            return true;
        }
        Radio[] g = members();
        foreach (Radio r; g)
        {
            if (r.shown)
            {
                return false;
            }
        }
        return g[0] is this;
    }

    /// Arrows choose and focus the previous or next enabled radio of the group, wrapping around. Enter and space
    /// choose this one.
    override bool onKey(ref const KeyEvent e)
    {
        if (enabled == false)
        {
            return false;
        }
        int dir;
        switch (e.key)
        {
        case Key.left:
        case Key.up:
            dir = -1;
            break;
        case Key.right:
        case Key.down:
            dir = 1;
            break;
        case Key.enter:
        case Key.space:
            activate();
            return true;
        default:
            return false;
        }
        Radio[] g = members();
        size_t at;
        foreach (size_t i, Radio r; g)
        {
            if (r is this)
            {
                at = i;
            }
        }
        size_t step = dir > 0 ? 1 : g.length - 1;
        size_t i = at;
        foreach (size_t k; 1 .. g.length)
        {
            i = (i + step) % g.length;
            Radio r = g[i];
            if (r.enabled)
            {
                r.activate();
                if (tree !is null && tree.services !is null)
                {
                    tree.services.setFocus(r);
                }
                break;
            }
        }
        return true;
    }

    /// Circle and caption.
    protected override Size performLayout(Constraints c)
    {
        RadioStyle s = tree.style!RadioStyle();
        return measureRadio(tree.text, s, caption);
    }

    /// The look for the current state.
    override void paint(ref PaintContext ctx, Point origin)
    {
        RadioStyle s = ctx.style!RadioStyle();
        paintRadio(ctx, Rect(origin.x, origin.y, size.w, size.h), s, caption, shown, hovered && enabled, focusRing,
            enabled);
    }
}

/// Retained radio choosing `option` for `value`: `radio(level, Level.high, "High")`. Radios next to each other
/// on one signal form a group. `enabled` greys it out and stops input when false.
Radio radio(T)(Signal!T value, T option, string caption = null, bool delegate() enabled = null,
    string tooltip = null, string accessName = null)
{
    Radio r = new Radio(value, () => value.get == option, () { value.set(option); }, caption);
    r.setTooltip(tooltip);
    r.accessName = accessName;
    if (enabled !is null)
    {
        effect(() { r.setEnabled(enabled()); });
    }
    return r;
}

/// Group of radios for `options` in a column, or a row when `horizontal`: `radioGroup(["Low", "High"], level)`.
/// `label` defaults to `to!string`.
Flex radioGroup(T)(T[] options, Signal!T value, string delegate(T) label = null, bool horizontal = false,
    bool delegate() enabled = null)
{
    import std.conv : to;

    Node[] kids;
    foreach (T o; options)
    {
        kids ~= radio(value, o, label !is null ? label(o) : o.to!string, enabled);
    }
    return horizontal ? row(gap: 16)(kids) : column(gap: 6, cross: CrossAlign.start)(kids);
}

/// Group of radios over the members of enum `E`: `radioGroup(renderer)`.
Flex radioGroup(E)(Signal!E value, string delegate(E) label = null, bool horizontal = false,
    bool delegate() enabled = null)
if (is(E == enum))
{
    import std.traits : EnumMembers;

    return radioGroup!E([EnumMembers!E], value, label, horizontal, enabled);
}

/// Paint-only radio declared by an island pass.
final class RadioBox : Node
{
    string caption;   /// caption text
    RadioStyle style; /// style in use, resolved from the theme
    bool on;          /// chosen
    bool hot;         /// pointer over
    bool enabled;     /// takes clicks
    bool ring;        /// focused by keyboard

    /// Creates a box.
    this(string caption, RadioStyle style, bool on, bool hot, bool enabled)
    {
        this.caption = caption;
        this.style = style;
        this.on = on;
        this.hot = hot;
        this.enabled = enabled;
    }

    /// Radio button named by its caption.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.radioButton;
        a.label = caption;
        a.toggled = on ? Toggle.on : Toggle.off;
        a.disabled = enabled == false;
        a.allow(AccessAction.click);
    }

    /// Same size as the retained radio.
    protected override Size performLayout(Constraints c)
    {
        return measureRadio(tree.text, style, caption);
    }

    /// Same look as the retained radio.
    override void paint(ref PaintContext ctx, Point origin)
    {
        paintRadio(ctx, Rect(origin.x, origin.y, size.w, size.h), style, caption, on, hot, ring, enabled);
    }
}

/// Island radio setting `value` to `option` when clicked, or Enter or Space is pressed while it has focus, true on
/// that pass. Radios over the same `value` are a group: Tab stops at the chosen one, and arrows choose the
/// previous or next enabled one, wrapping around. Push an ID when calling it in a loop.
bool radio(T)(Ui ui, ref T value, T option, string caption = null, bool enabled = true, string file = __FILE__,
    size_t line = __LINE__)
{
    Id i = ui.id(file, line);
    Press p = ui.clickable(i, enabled);
    if (ui.focusStop(i, enabled, cast(size_t) &value, value == option))
    {
        if (ui.takeKey(Key.enter) || ui.takeKey(Key.space))
        {
            p.clicked = true;
            ui.again = true;
        }
        if (ui.takeKey(Key.left) || ui.takeKey(Key.up))
        {
            ui.stepGroup(i, -1);
        }
        else if (ui.takeKey(Key.right) || ui.takeKey(Key.down))
        {
            ui.stepGroup(i, 1);
        }
    }
    if (ui.picked(i))
    {
        p.clicked = true;
        ui.again = true;
    }
    if (p.clicked)
    {
        value = option;
    }
    RadioBox n = new RadioBox(caption, ui.style!RadioStyle(), value == option, p.hovered, enabled);
    n.ring = ui.focusRing(i);
    ui.put(n);
    ui.track(n, i);
    return p.clicked;
}

version (unittest)
{
    /// Choices for the tests.
    private enum Speed
    {
        slow,   /// first
        medium, /// second
        fast,   /// third
    }
}

// A click chooses, outside writes show, arrows move the choice past disabled radios and wrap, and Tab stops at
// the chosen radio only.
unittest
{
    import dentrite.host : Host;
    import dentrite.signals : signal;
    import dentrite.widgets.button : Button, button;
    import dentrite.widgets.menu : clickOn, menuHost;

    Host h = menuHost(300, 200);
    scope (exit)
    {
        h.close();
    }
    Signal!Speed speed = signal(Speed.slow);
    Signal!bool fastOk = signal(true);
    assert(radioGroup(speed).children.length == 3);
    Radio[] rs = [radio(speed, Speed.slow, "slow"), radio(speed, Speed.medium, "medium"),
        radio(speed, Speed.fast, "fast", enabled: () => fastOk.get)];
    Button before = button("Before");
    h.setRoot(column()(before, column()(rs[0], rs[1], rs[2])));
    h.frame();
    assert(rs[0].chosen && rs[0].tabStop && rs[1].tabStop == false);

    clickOn(h, rs[1]);
    assert(speed.peek == Speed.medium && h.focused is rs[1] && rs[0].chosen == false);
    speed.set(Speed.fast);
    assert(rs[2].chosen && rs[1].chosen == false);
    h.setFocus(rs[2]);

    h.injectKey(Key.down, 0);
    assert(speed.peek == Speed.slow && h.focused is rs[0], "down from the last wraps to the first");
    fastOk.set(false);
    h.injectKey(Key.up, 0);
    assert(speed.peek == Speed.medium && h.focused is rs[1], "up from the first skips the disabled last");
    h.injectKey(Key.right, 0);
    assert(speed.peek == Speed.slow);

    h.setFocus(before);
    h.injectKey(Key.tab, 0);
    assert(h.focused is rs[0], "Tab lands on the chosen radio");
    h.injectKey(Key.tab, 0);
    assert(h.focused is before, "and leaves the group with the next Tab");
}
