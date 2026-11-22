/// Buttons with a caption and optional icon, a themed look, and a click on release over the button.
module dentrite.widgets.button;

import dentrite.immediate;
import dentrite.node;
import dentrite.signals : effect;
import dentrite.text;
import dentrite.widgets.icons;
import std.algorithm.comparison : max;
import std.math : round;

/// Look of a button.
struct ButtonStyle
{
    enum section = "button"; /// section name in theme files

    /// Variants theme files can style as `[section.variant]`.
    enum Variants
    {
        primary, /// main action
        danger,  /// destructive action
        toolbar, /// flat, in tool bars
    }

    Color fill = Color(0x44, 0x44, 0x48, 0xff);        /// background
    Color fillHover = Color(0x50, 0x50, 0x55, 0xff);   /// background under the pointer
    Color fillPressed = Color(0x38, 0x38, 0x3c, 0xff); /// background while held
    Color fillDisabled = Color(0x30, 0x30, 0x33, 0xff); /// background when disabled
    Color text = Color(0xee, 0xee, 0xee, 0xff);        /// caption
    Color textDisabled = Color(0x80, 0x80, 0x80, 0xff); /// caption when disabled
    Color icon;                                        /// icon, caption color when transparent
    Color border;                                      /// outline
    Color focus = Color(0x4c, 0x8d, 0xf6, 0xff);       /// focus ring
    float radius = 4;   /// corner radius
    float padX = 10;    /// horizontal padding
    float padY = 4;     /// vertical padding
    float iconSize = 12; /// icon size
    float gap = 6;      /// space between the icon and the caption
    float minWidth = 0; /// narrowest button
    FontKind font = FontKind.ui; /// caption font
    float size = 13;    /// caption size

    /// Look of `variant` without a theme: blue, red, or flat.
    static void applyVariant(ref ButtonStyle s, string variant)
    {
        switch (variant)
        {
        case "primary":
            s.fill = Color(0x2f, 0x6b, 0xd6, 0xff);
            s.fillHover = Color(0x3b, 0x82, 0xf6, 0xff);
            s.fillPressed = Color(0x25, 0x58, 0xb0, 0xff);
            s.text = Color(0xff, 0xff, 0xff, 0xff);
            break;
        case "danger":
            s.fill = Color(0x3b, 0x22, 0x24, 0xff);
            s.fillHover = Color(0x4c, 0x29, 0x2c, 0xff);
            s.fillPressed = Color(0x3b, 0x22, 0x24, 0xff);
            s.text = Color(0xf4, 0x7a, 0x7a, 0xff);
            break;
        case "toolbar":
            s.fill = Color.init;
            s.fillHover = Color(0x33, 0x33, 0x38, 0xff);
            s.fillPressed = Color(0x3c, 0x3c, 0x42, 0xff);
            s.fillDisabled = Color.init;
            s.padX = 8;
            s.padY = 5;
            break;
        default:
            break;
        }
    }
}

/// Interaction state that picks the colors.
struct ButtonState
{
    bool hovered;  /// pointer over
    bool held;     /// pressed and not released
    bool enabled = true; /// accepts clicks
    bool focused;  /// keyboard focus
}

/// Size of a button with `caption` and `icon` in style `s`.
Size measureButton(TextSystem t, const ref ButtonStyle s, string caption, Icon icon)
{
    float w = s.padX * 2;
    float h = s.padY * 2 + max(t.lineHeight(s.font, s.size), s.iconSize);
    if (icon.empty == false)
    {
        w += s.iconSize + (caption.length > 0 ? s.gap : 0);
    }
    if (caption.length > 0)
    {
        w += t.measure(s.font, s.size, caption);
    }
    return Size(max(w, s.minWidth), h);
}

/// Paints a button in `r`. Shared by the retained node and the island function.
void paintButton(ref PaintContext ctx, Rect r, const ref ButtonStyle s, string caption, Icon icon, ButtonState st)
{
    Color fill = st.enabled == false ? s.fillDisabled : st.held ? s.fillPressed : st.hovered ? s.fillHover : s.fill;
    Color ink = st.enabled ? s.text : s.textDisabled;
    if (fill.a > 0 || s.border.a > 0)
    {
        ctx.list.rect(r, fill, s.radius, s.border, 1);
    }
    if (st.focused)
    {
        ctx.list.rect(r.inset(-2), Color.init, s.radius + 2, s.focus, 1);
    }
    TextSystem t = ctx.text;
    float textW = caption.length > 0 ? t.measure(s.font, s.size, caption) : 0;
    float contentW = textW + (icon.empty == false ? s.iconSize + (caption.length > 0 ? s.gap : 0) : 0);
    float x = r.x + round((r.w - contentW) / 2);
    if (icon.empty == false)
    {
        Color ic = st.enabled == false ? s.textDisabled : s.icon.a > 0 ? s.icon : ink;
        float iy = r.y + round((r.h - s.iconSize) / 2);
        paintIcon(*ctx.list, icon, Rect(x, iy, s.iconSize, s.iconSize), ic, st.enabled == false);
        x += s.iconSize + s.gap;
    }
    if (caption.length > 0)
    {
        float lineH = t.lineHeight(s.font, s.size);
        float top = r.y + round((r.h - lineH) / 2);
        ctx.list.text(t.shape(s.font, s.size, caption), Point(x, top + t.ascent(s.font, s.size)), ink);
    }
}

/// Pointer and keyboard handling shared by clickable nodes. Needs `bool enabled` and `void activate()`.
mixin template PressBehavior()
{
    /// Hover and press feedback, click on release over the node.
    override bool onPointer(ref const PointerEvent e)
    {
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
            markNeedsPaint();
            return true;
        case PointerKind.up:
            markNeedsPaint();
            if (enabled && e.button == 1 && hovered)
            {
                activate();
            }
            return true;
        default:
            return false;
        }
    }

    /// Click runs `activate` while enabled.
    override bool accessAction(ref const AccessRequest r)
    {
        if (r.action == AccessAction.click && enabled)
        {
            activate();
            return true;
        }
        return false;
    }

    /// Enter and space activate.
    override bool onKey(ref const KeyEvent e)
    {
        if (enabled && (e.key == Key.enter || e.key == ' '))
        {
            activate();
            return true;
        }
        return false;
    }

    /// Repaints to show or hide the focus ring.
    override void onFocus(bool gained)
    {
        markNeedsPaint();
    }
}

/// Retained button.
final class Button : Node
{
    string caption;          /// caption text
    Icon icon;               /// icon before the text
    string variant;          /// ButtonStyle variant
    void delegate() onClick; /// click handler
    bool enabled = true;     /// accepts clicks

    mixin PressBehavior;

    /// Creates a button.
    this(string caption, Icon icon, string variant, void delegate() onClick)
    {
        this.caption = caption;
        this.icon = icon;
        this.variant = variant;
        this.onClick = onClick;
        interactive = true;
        focusable = true;
        cursor = CursorShape.pointer;
    }

    /// Runs the handler.
    void activate()
    {
        if (onClick !is null)
        {
            onClick();
        }
    }

    /// Changes the caption.
    void setCaption(string s)
    {
        if (s != caption)
        {
            caption = s;
            markNeedsLayout();
        }
    }

    /// Changes the icon.
    void setIcon(Icon i)
    {
        if (i != icon)
        {
            icon = i;
            markNeedsLayout();
        }
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

    /// Button named by its caption.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.button;
        a.label = caption;
        a.disabled = enabled == false;
        a.allow(AccessAction.click);
    }

    /// Caption, icon and padding.
    protected override Size performLayout(Constraints c)
    {
        ButtonStyle s = tree.style!ButtonStyle(variant);
        return measureButton(tree.text, s, caption, icon);
    }

    /// The look for the current state.
    override void paint(ref PaintContext ctx, Point origin)
    {
        ButtonStyle s = ctx.style!ButtonStyle(variant);
        paintButton(ctx, Rect(origin.x, origin.y, size.w, size.h), s, caption, icon,
            ButtonState(hovered, pressed && hovered, enabled, focusRing));
    }
}

/// Retained button: `button("Remove disabled", onClick: &remove, variant: "danger")`.
Button button(string caption, void delegate() onClick = null, Icon icon = Icon.none, string variant = null,
    bool delegate() enabled = null, string tooltip = null, string accessName = null)
{
    Button b = new Button(caption, icon, variant, onClick);
    b.setTooltip(tooltip);
    b.accessName = accessName;
    if (enabled !is null)
    {
        effect(() { b.setEnabled(enabled()); });
    }
    return b;
}

/// Paint-only button declared by an island pass.
final class ButtonBox : Node
{
    string caption;    /// caption text
    Icon icon;         /// icon
    ButtonStyle style; /// resolved look, with the island's style edits
    ButtonState state; /// interaction state from last pass's rects

    /// Creates a box.
    this(string caption, Icon icon, ButtonStyle style, ButtonState state)
    {
        this.caption = caption;
        this.icon = icon;
        this.style = style;
        this.state = state;
    }

    /// Button named by its caption.
    override void describe(ref AccessInfo a)
    {
        a.role = Role.button;
        a.label = caption;
        a.disabled = state.enabled == false;
        a.allow(AccessAction.click);
    }

    /// Same size as the retained button.
    protected override Size performLayout(Constraints c)
    {
        return measureButton(tree.text, style, caption, icon);
    }

    /// Same look as the retained button.
    override void paint(ref PaintContext ctx, Point origin)
    {
        paintButton(ctx, Rect(origin.x, origin.y, size.w, size.h), style, caption, icon, state);
    }
}

/// Island button, true on the pass it is clicked, or Enter or Space is pressed while it has focus.
bool button(Ui ui, string caption, Icon icon = Icon.none, string variant = null, bool enabled = true,
    string accessName = null, string file = __FILE__, size_t line = __LINE__)
{
    Id i = ui.id(file, line);
    Press p = ui.clickable(i, enabled);
    if (ui.focusStop(i, enabled) && (ui.takeKey(Key.enter) || ui.takeKey(Key.space)))
    {
        p.clicked = true;
        ui.again = true;
    }
    ButtonBox n = new ButtonBox(caption, icon, ui.style!ButtonStyle(variant),
        ButtonState(p.hovered, p.held && p.hovered, enabled, ui.focusRing(i)));
    n.accessName = accessName;
    ui.put(n);
    ui.track(n, i);
    return p.clicked;
}

// The retained and island buttons have the same size for the same caption and style.
unittest
{
    import dentrite.containers : CrossAlign, column;

    TextSystem ts = testText();
    scope (exit)
    {
        ts.dispose();
    }
    int clicks;
    Button b = button("Remove disabled", onClick: () { ++clicks; });
    Tree t = new Tree(ts, null, null);
    t.viewport = Size(300, 100);
    t.setRoot(column(cross: CrossAlign.start)(b));
    t.flush();
    Ui ui = new Ui(t);
    ui.frame((Ui u) { u.row()({ u.button("Remove disabled"); }); }, Rect(0, 0, 300, 100));
    assert(ui.lastRect(ui.id(__FILE__, __LINE__ - 1)).w == b.size.w);
    b.hovered = true;
    PointerEvent up = PointerEvent(PointerKind.up, Point(1, 1), 1);
    b.onPointer(up);
    assert(clicks == 1);
}

// Variants differ without a theme. A theme's base section sets what a variant leaves, its variant section wins.
unittest
{
    import dentrite.theme : loadStyle, resolve;

    ButtonStyle base = resolve!ButtonStyle(null, null, null, null);
    ButtonStyle primary = resolve!ButtonStyle(null, null, "primary", null);
    assert(primary.fill != base.fill && primary.radius == base.radius);
    enum string text = "[button]\nradius = 9\nfill = #101010\n\n[button.primary]\ntext = #000000\n";
    enum ButtonStyle p = loadStyle!ButtonStyle(text, "t", "primary");
    static assert(p.radius == 9 && p.fill == Color(0x2f, 0x6b, 0xd6, 0xff) && p.text == Color(0, 0, 0, 0xff));
}
