/// Checkboxes, a box with a check mark and an optional caption, bound to a bool signal.
module dentrite.widgets.checkbox;

import dentrite.immediate;
import dentrite.node;
import dentrite.signals : Signal, effect;
import dentrite.text;
import dentrite.widgets.button : PressBehavior;
import std.algorithm.comparison : max;
import std.math : round;

/// Look of a checkbox.
struct CheckboxStyle
{
    enum section = "checkbox"; /// section name in theme files

    Color box = Color(0x2a, 0x2a, 0x2e, 0xff);       /// unchecked fill
    Color boxHover = Color(0x34, 0x34, 0x39, 0xff);  /// unchecked fill under the pointer
    Color border = Color(0x60, 0x60, 0x66, 0xff);    /// unchecked outline
    Color checked = Color(0x3a, 0x7b, 0xe8, 0xff);   /// checked fill
    Color checkedHover = Color(0x4c, 0x8d, 0xf6, 0xff); /// checked fill under the pointer
    Color mark = Color(0xff, 0xff, 0xff, 0xff);      /// check mark
    Color boxDisabled = Color(0x26, 0x26, 0x29, 0xff); /// fill when disabled
    Color text = Color(0xdd, 0xdd, 0xdd, 0xff);      /// caption
    Color textDisabled = Color(0x80, 0x80, 0x80, 0xff); /// caption and mark when disabled
    Color focus = Color(0x4c, 0x8d, 0xf6, 0xff);     /// focus ring
    float boxSize = 14; /// side length of the box
    float radius = 3;   /// box corner radius
    float gap = 6;      /// space between the box and the caption
    FontKind font = FontKind.ui; /// caption font
    float size = 13;    /// caption size
}

/// Size of a checkbox with `caption`.
Size measureCheckbox(TextSystem t, const ref CheckboxStyle s, string caption)
{
    if (caption.length == 0)
    {
        return Size(s.boxSize, s.boxSize);
    }
    return Size(s.boxSize + s.gap + t.measure(s.font, s.size, caption),
        max(s.boxSize, t.lineHeight(s.font, s.size)));
}

/// Paints a checkbox in `r`. Shared by the retained node and the island function.
void paintCheckbox(ref PaintContext ctx, Rect r, const ref CheckboxStyle s, string caption, bool on, bool hovered,
    bool focused, bool enabled = true)
{
    float by = r.y + round((r.h - s.boxSize) / 2);
    Rect box = Rect(r.x, by, s.boxSize, s.boxSize);
    if (enabled == false)
    {
        ctx.list.rect(box, s.boxDisabled, s.radius, s.border, 1);
    }
    else if (on)
    {
        ctx.list.rect(box, hovered ? s.checkedHover : s.checked, s.radius);
    }
    else
    {
        ctx.list.rect(box, hovered ? s.boxHover : s.box, s.radius, s.border, 1);
    }
    if (on)
    {
        float k = s.boxSize;
        ctx.list.polyline([Point(box.x + k * 0.24, box.y + k * 0.52), Point(box.x + k * 0.43, box.y + k * 0.7),
            Point(box.x + k * 0.77, box.y + k * 0.31)], k * 0.13, enabled ? s.mark : s.textDisabled);
    }
    if (focused)
    {
        ctx.list.rect(box.inset(-2), Color.init, s.radius + 2, s.focus, 1);
    }
    if (caption.length > 0)
    {
        TextSystem t = ctx.text;
        float lineH = t.lineHeight(s.font, s.size);
        float top = r.y + round((r.h - lineH) / 2);
        ctx.list.text(t.shape(s.font, s.size, caption), Point(box.right + s.gap, top + t.ascent(s.font, s.size)),
            enabled ? s.text : s.textDisabled);
    }
}

/// Retained checkbox bound to a signal.
final class Checkbox : Node
{
    Signal!bool delegate() value; /// bound state, a getter so pooled rows can switch signals
    string caption;      /// text after the box
    bool enabled = true; /// accepts clicks
    private bool shown;  /// state last read from `value`

    mixin PressBehavior;

    /// Creates a checkbox over the signal `value` returns. The binding effect belongs to the current owner.
    this(Signal!bool delegate() value, string caption)
    {
        this.value = value;
        this.caption = caption;
        interactive = true;
        focusable = true;
        cursor = CursorShape.pointer;
        effect(() {
            bool v = value().get;
            if (v != shown)
            {
                shown = v;
                markNeedsPaint();
            }
        });
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

    /// Flips the value.
    void activate()
    {
        Signal!bool s = value();
        s.set(s.peek == false);
    }

    /// Check box named by its caption.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.checkBox;
        a.label = caption;
        a.toggled = shown ? Toggle.on : Toggle.off;
        a.disabled = enabled == false;
        a.allow(AccessAction.click);
    }

    /// Box and caption.
    protected override Size performLayout(Constraints c)
    {
        CheckboxStyle s = tree.style!CheckboxStyle();
        return measureCheckbox(tree.text, s, caption);
    }

    /// The look for the current state.
    override void paint(ref PaintContext ctx, Point origin)
    {
        CheckboxStyle s = ctx.style!CheckboxStyle();
        paintCheckbox(ctx, Rect(origin.x, origin.y, size.w, size.h), s, caption, shown, hovered && enabled, focusRing,
            enabled);
    }
}

/// Retained checkbox: `checkbox(b.enabled)`. `enabled` greys it out and stops input when false.
Checkbox checkbox(Signal!bool value, string caption = null, bool delegate() enabled = null, string tooltip = null,
    string accessName = null)
{
    return checkbox(() => value, caption, enabled, tooltip, accessName);
}

/// The retained checkbox flips its signal and follows outside writes.
unittest
{
    import dentrite.signals : signal;

    Signal!bool on = signal(true);
    Checkbox c = checkbox(on, "enabled");
    c.activate();
    assert(on.peek == false);
    on.set(true);
    assert(c.shown);
    Signal!bool enabled = signal(true);
    Checkbox d = checkbox(on, "disabled", enabled: () => enabled.get);
    enabled.set(false);
    KeyEvent space = KeyEvent(Key.space, 0);
    assert(d.onKey(space) == false && on.peek, "a disabled box ignores keys");
}

/// Retained checkbox following whichever signal `value` returns: `checkbox(() => item().enabled)`.
Checkbox checkbox(Signal!bool delegate() value, string caption = null, bool delegate() enabled = null,
    string tooltip = null, string accessName = null)
{
    Checkbox c = new Checkbox(value, caption);
    c.setTooltip(tooltip);
    c.accessName = accessName;
    if (enabled !is null)
    {
        effect(() { c.setEnabled(enabled()); });
    }
    return c;
}

/// Paint-only checkbox declared by an island pass.
final class CheckboxBox : Node
{
    string caption;      /// caption text
    CheckboxStyle style; /// style in use, resolved from the theme
    bool on;             /// checked
    bool hot;            /// pointer over
    bool enabled;        /// takes clicks
    bool ring;           /// focused by keyboard

    /// Creates a box.
    this(string caption, CheckboxStyle style, bool on, bool hot, bool enabled)
    {
        this.enabled = enabled;
        this.caption = caption;
        this.style = style;
        this.on = on;
        this.hot = hot;
    }

    /// Check box named by its caption.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.checkBox;
        a.label = caption;
        a.toggled = on ? Toggle.on : Toggle.off;
        a.disabled = enabled == false;
        a.allow(AccessAction.click);
    }

    /// Same size as the retained checkbox.
    protected override Size performLayout(Constraints c)
    {
        return measureCheckbox(tree.text, style, caption);
    }

    /// Same look as the retained checkbox.
    override void paint(ref PaintContext ctx, Point origin)
    {
        paintCheckbox(ctx, Rect(origin.x, origin.y, size.w, size.h), style, caption, on, hot, ring, enabled);
    }
}

/// Island checkbox over `value`, toggled and true on the pass it is clicked, or Enter or Space is pressed while it
/// has focus.
bool checkbox(Ui ui, ref bool value, string caption = null, bool enabled = true, string accessName = null,
    string file = __FILE__, size_t line = __LINE__)
{
    Id i = ui.id(file, line);
    Press p = ui.clickable(i, enabled);
    if (ui.focusStop(i, enabled) && (ui.takeKey(Key.enter) || ui.takeKey(Key.space)))
    {
        p.clicked = true;
        ui.again = true;
    }
    if (p.clicked)
    {
        value = value == false;
    }
    CheckboxBox n = new CheckboxBox(caption, ui.style!CheckboxStyle(), value, p.hovered, enabled);
    n.ring = ui.focusRing(i);
    n.accessName = accessName;
    ui.put(n);
    ui.track(n, i);
    return p.clicked;
}
