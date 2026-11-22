/// Button component: content from a slot, look from the theme, pointer handling from `Ui.clickable`.
///
/// Uses only the public API of `immediate`, as a third-party component would.
/// NOTE: the module sits in a package because a module named `button` would
/// hide the function `button` from its importers.
module widgets.button;

import immediate;
import layout : Axis, CrossAlign, Flex, Insets;
import std.conv : to;
import theme : Color;

/// Button look.
enum Variant
{
    normal,  /// neutral action
    primary, /// the dialog's main action
    danger,  /// kills or deletes something
}

/// Look of one variant, read from theme sections `[button]` then `[button.<variant>]`.
struct ButtonStyle
{
    enum section = "button";  /// theme file section
    alias Variants = Variant; /// variant sections the theme may add

    Color fill;         /// background at rest
    Color fillHover;    /// background under the pointer
    Color fillPressed;  /// background while held
    Color fillDisabled; /// background when disabled
    Color text;         /// ink of the content
    Color textDisabled; /// ink of the content when disabled
    float padX = 8;     /// space left and right of the content
    float padY = 4;     /// space above and below the content
}

/// Button options from `button`, waiting for the content.
struct ButtonSpec
{
    private Ui ui;           /// context
    private Variant variant; /// look
    private bool enabled;    /// reacts to the pointer
    private Id id;           /// widget ID

    /// Stores the options. Needed because `opCall` hides the struct literal.
    this(Ui ui, Variant variant, bool enabled, Id id)
    {
        this.ui = ui;
        this.variant = variant;
        this.enabled = enabled;
        this.id = id;
    }

    /// Declares the button around `content`, which inherits the button's ink. Returns its pointer state.
    Press opCall(scope void delegate() content)
    {
        ButtonStyle s = ui.style!ButtonStyle(to!string(variant));
        Press p = ui.clickable(id, enabled);
        Surface box = new Surface(Insets(s.padX, s.padY, s.padX, s.padY));
        box.ink = enabled ? s.text : s.textDisabled;
        if (enabled == false)
        {
            box.fill = s.fillDisabled;
        }
        else if (p.held)
        {
            box.fill = s.fillPressed;
        }
        else if (p.hovered)
        {
            box.fill = s.fillHover;
        }
        else
        {
            box.fill = s.fill;
        }
        Flex row = new Flex(Axis.horizontal, 4, CrossAlign.center, null);
        box.add(row);
        ui.put(box);
        ui.track(box, id);
        ui.inside(row, content);
        return p;
    }
}

/// Button options by name, then the content: `ui.button(variant: Variant.danger)({ ui.label("Kill"); })`.
/// The ID comes from the caller's file and line.
ButtonSpec button(Ui ui, Variant variant = Variant.normal, bool enabled = true,
    string file = __FILE__, size_t line = __LINE__)
{
    return ButtonSpec(ui, variant, enabled, ui.id(file, line));
}

/// Button with a text caption: `ui.button("Step", enabled: paused).clicked`.
Press button(Ui ui, string caption, Variant variant = Variant.normal, bool enabled = true,
    string file = __FILE__, size_t line = __LINE__)
{
    return button(ui, variant, enabled, file, line)({ ui.label(caption); });
}

version (unittest)
{
    import layout : Point, Rect, Size;
    import theme : checkTheme, loadStyle, Theme;

    /// Shipped light theme, checked against every style it holds.
    private Theme light()
    {
        Theme t = new Theme(import("light.theme"), "light.theme");
        t.check!(TextStyle, ButtonStyle)();
        return t;
    }

    /// Drawn text `s`.
    private Drawn text(Ui ui, string s)
    {
        foreach (Drawn d; ui.drawn)
        {
            if (d.text == s)
            {
                return d;
            }
        }
        assert(false, "not drawn: " ~ s);
    }

    /// Innermost box drawn under the text `s`.
    private Drawn boxOf(Ui ui, string s)
    {
        Rect r = ui.find(s);
        Drawn found;
        foreach (Drawn d; ui.drawn)
        {
            if (d.text.length == 0 && d.r.contains(Point(r.x, r.y)))
            {
                found = d;
            }
        }
        return found;
    }
}

/// Both call forms. Each variant takes its look from the theme, the content its ink from the button.
unittest
{
    Ui ui = new Ui;
    ui.theme = light();
    ui.frame({
        ui.row(gap: 4)({
            ui.button("Step");
            ui.button(variant: Variant.danger)({
                ui.label("Kill");
                ui.label("process");
            });
        });
        ui.label("Ready");
    }, Size(400, 100));

    ButtonStyle normal = ui.theme.style!ButtonStyle("normal");
    ButtonStyle danger = ui.theme.style!ButtonStyle("danger");
    assert(boxOf(ui, "Step").r == Rect(8, 8, 4 * 8 + 16, 24));
    assert(boxOf(ui, "Step").color == normal.fill);
    assert(boxOf(ui, "Kill").color == danger.fill);
    assert(boxOf(ui, "process").r.w == 4 * 8 + 4 + 7 * 8 + 16, "two labels in a row");
    assert(text(ui, "Kill").color == Color(0xff, 0xff, 0xff, 0xff), "white, from [button.danger]");
    assert(text(ui, "Ready").color == ui.style!TextStyle().color, "outside the button");
    assert(danger.padX == 8 && danger.fillDisabled == normal.fillDisabled, "inherited from [button]");
}

/// Hover, hold and click come from last frame's rect. A disabled button ignores them.
unittest
{
    Ui ui = new Ui;
    ui.theme = light();
    ButtonStyle s = ui.theme.style!ButtonStyle("primary");
    Press run, stop;
    int clicks;
    void frame()
    {
        ui.frame({
            run = ui.button("Run", variant: Variant.primary);
            stop = ui.button("Stop", enabled: false);
            clicks += run.clicked;
        }, Size(200, 100));
    }

    frame();
    assert(boxOf(ui, "Run").color == s.fill);
    Rect r = ui.find("Run");
    ui.mouse = Point(r.x + 1, r.y + 1);
    frame();
    assert(run == Press(hovered: true));
    assert(boxOf(ui, "Run").color == s.fillHover);
    ui.pressed = true;
    ui.down = true;
    frame();
    assert(clicks == 1, "clicked in the first pass only");
    assert(run == Press(hovered: true, held: true), "the last pass, with the press spent");
    assert(boxOf(ui, "Run").color == s.fillPressed);

    Rect o = ui.find("Stop");
    ui.mouse = Point(o.x + 1, o.y + 1);
    ui.pressed = true;
    frame();
    assert(stop == Press.init);
    assert(boxOf(ui, "Stop").color == s.fillDisabled);
    assert(text(ui, "Stop").color == s.textDisabled);
}

/// `withStyle` edits every button inside on top of its variant's look, and ends with its scope.
unittest
{
    Ui ui = new Ui;
    ui.theme = light();
    ui.frame({
        ui.row(gap: 4)({
            ui.withStyle((ref ButtonStyle s) { s.padX = 2; })({
                ui.button("Kill", variant: Variant.danger);
            });
            ui.button("Step");
        });
    }, Size(400, 100));
    assert(boxOf(ui, "Kill").r.w == 4 * 8 + 4);
    assert(boxOf(ui, "Kill").color == ui.theme.style!ButtonStyle("danger").fill, "variant kept");
    assert(boxOf(ui, "Step").r.w == 4 * 8 + 16);
}

/// A reloaded theme shows on the next frame. `check` it before swapping it in.
unittest
{
    Ui ui = new Ui;
    ui.theme = light();
    void frame()
    {
        ui.frame({ ui.button("Step"); }, Size(200, 100));
    }

    frame();
    assert(boxOf(ui, "Step").color == Color(0xe4, 0xe5, 0xe9, 0xff));
    Theme edited = new Theme(import("light.theme") ~ "[button]\nfill = #102030\n", "light.theme");
    edited.check!(TextStyle, ButtonStyle)();
    ui.theme = edited;
    frame();
    assert(boxOf(ui, "Step").color == Color(0x10, 0x20, 0x30, 0xff));
}

/// The shipped theme is also checked and loaded at compile time, so a mistake in it fails the build.
unittest
{
    static assert(checkTheme!(TextStyle, ButtonStyle)(import("light.theme"), "light.theme"));
    enum ButtonStyle danger = loadStyle!ButtonStyle(import("light.theme"), "light.theme", "danger");
    static assert(danger.fill == Color(0xc6, 0x2f, 0x2f, 0xff) && danger.padY == 4);
}
