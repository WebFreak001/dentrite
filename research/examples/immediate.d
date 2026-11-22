/// Immediate-mode API with deferred layout, as in Clay and gpui.
///
/// Each frame the application declares a fresh tree through `Ui` calls. `frame`
/// lays it out with the box constraints of `layout`, then records each node's
/// rect by ID. Interaction tests the pointer against the previous frame's
/// rects, which is what the user saw. Layout is exact on the first frame, there
/// is no settle frame. A pass that handled input is built again before layout,
/// as nanoui does. IDs come from the call site plus a pushed key.
///
/// `Ui` members are the primitives a widget is written with. Widgets are free
/// functions over `Ui`, called through UFCS, so a widget module written
/// elsewhere looks the same at the call site. NOTE: a `Ui` member named like a
/// widget hides that widget from UFCS everywhere.
module immediate;

import layout;
import std.format : format;
import theme : Color, Theme;

/// Widget identity, stable across frames.
alias Id = ulong;

/// Text leaf, drawn in the color of the nearest surface that sets one.
private final class Label : Node
{
    Text text; /// wrapped text node

    /// Creates a label for `s`.
    this(string s)
    {
        text = new Text(s);
        add(text);
    }

    /// Same size as the text.
    protected override Size performLayout(Constraints c)
    {
        text.offset = Point.init;
        return text.layout(c);
    }
}

/// Clickable leaf: text with 4 px of vertical padding.
private final class ButtonNode : Node
{
    string caption; /// button text

    /// Creates a button node.
    this(string caption)
    {
        this.caption = caption;
    }

    /// Text width by 24 px.
    protected override Size performLayout(Constraints c)
    {
        return Size(caption.length * 8, 24);
    }
}

/// Filled box around one child, inset by `padding`. Painted under the child.
final class Surface : Node
{
    Color fill;     /// background
    Color ink;      /// text color inside, transparent keeps the outer one
    Insets padding; /// space around the child

    /// Creates an empty box. Add exactly one child before layout.
    this(Insets padding)
    {
        this.padding = padding;
    }

    /// Lays out the child in the deflated space and offsets it.
    protected override Size performLayout(Constraints c)
    {
        Node child = children[0];
        Size s = child.layout(c.deflate(padding));
        child.offset = Point(padding.left, padding.top);
        return Size(s.w + padding.left + padding.right, s.h + padding.top + padding.bottom);
    }
}

/// Command produced by painting the laid-out tree.
struct Drawn
{
    Rect r;      /// bounds
    string text; /// caption or label text, empty for boxes
    Color color; /// ink of text, fill of boxes
}

/// Look of text outside surfaces that set their own ink.
struct TextStyle
{
    enum section = "text";                      /// theme file section
    Color color = Color(0x1d, 0x1d, 0x20, 0xff); /// ink of the root, read when painting
}

/// Pointer state of a widget this frame, from `Ui.clickable`.
struct Press
{
    bool hovered; /// pointer over it as laid out last frame
    bool held;    /// primary button held over it
    bool clicked; /// primary button went down over it this frame
}

/// Node whose rect is recorded under `id` at the end of the frame.
private struct Tracked
{
    Node node; /// declared node
    Id id;     /// its widget ID
}

/// Subtree kept by `Ui.memo`, with the inputs it was declared from.
private final class Memo(T)
{
    T inputs;          /// inputs of the last declaration
    Node[] nodes;      /// declared top-level nodes
    Tracked[] tracked; /// rect-recorded nodes inside
    Id[] touched;      /// per-ID memory used inside
    bool stale;        /// handled input, its next build pass must re-run
}

/// Row or column options from `row` and `column`, waiting for the children.
struct Group
{
    private Ui ui;            /// context to declare into
    private Axis axis;        /// main axis
    private float gap;        /// space between children
    private CrossAlign cross; /// cross-axis placement

    /// Stores the options. Needed because `opCall` hides the struct literal.
    this(Ui ui, Axis axis, float gap, CrossAlign cross)
    {
        this.ui = ui;
        this.axis = axis;
        this.gap = gap;
        this.cross = cross;
    }

    /// Declares the container with `children` inside.
    void opCall(scope void delegate() children)
    {
        Flex n = new Flex(axis, gap, cross, null);
        ui.put(n);
        ui.inside(n, children);
    }
}

/// Style edit from `Ui.withStyle`, waiting for the children.
struct StyleScope(T)
{
    private Ui ui;                     /// context
    private void delegate(ref T) edit; /// applied to every `T` read inside

    /// Stores the edit. Needed because `opCall` hides the struct literal.
    this(Ui ui, void delegate(ref T) edit)
    {
        this.ui = ui;
        this.edit = edit;
    }

    /// Declares `children` with the edit in effect.
    void opCall(scope void delegate() children)
    {
        Ui.Edits!T stack = ui.editsOf!T();
        stack.items ~= edit;
        scope (exit)
        {
            stack.items.length -= 1;
            stack.items.assumeSafeAppend();
        }
        children();
    }
}

/// Immediate-mode context. One per window.
final class Ui
{
    Point mouse;   /// pointer position for this frame
    bool pressed;  /// button went down since the last frame
    bool down;     /// button is held
    Drawn[] drawn; /// output of the last `frame`
    bool again;    /// a widget handled input in this pass, so `frame` builds again before drawing
    int skipped;   /// subtrees reused by `memo` this frame
    Theme theme;   /// styles, or the defaults of each style struct when null

    private Node root;              /// this frame's tree
    private Node[] open;            /// containers being declared
    private Id[] idStack;           /// pushed keys, innermost last
    private Tracked[] tracked;      /// nodes that need their rect recorded
    private Id[] touched;           /// per-ID memory used this frame, in call order
    private Rect[Id] lastRects;     /// rects from the previous frame
    private Rect[Id] rects;         /// rects from this frame
    private Object[Id] memory;      /// per-ID state that survives frames
    private int[Id] memoryUsed;     /// build pass each memory entry was last used in
    private int pass;               /// build passes so far
    private Object[string] edits;   /// `Edits!T` by `T.mangleof`, from `withStyle`

    /// Scoped edits of style `T`, innermost last.
    private static final class Edits(T)
    {
        void delegate(ref T)[] items; /// edits in effect
    }

    /// Most build passes per frame. A view still changing state after that shows it next frame.
    enum maxPasses = 4;

    /// Builds a frame by running `view`, then lays it out at `viewport` and paints it. A pass that
    /// handled input is built again with the press spent, so the drawn frame already shows the change.
    void frame(scope void delegate() view, Size viewport)
    {
        begin();
        foreach (int i; 1 .. maxPasses + 1)
        {
            view();
            if (again == false || i == maxPasses)
            {
                break;
            }
            pressed = false;
            begin();
        }
        end(viewport);
    }

    /// Starts a build pass. The root is a padded column filling the window.
    private void begin()
    {
        ++pass;
        again = false;
        Flex body = new Flex(Axis.vertical, 4, CrossAlign.stretch, null);
        root = new Padding(Insets.all(8), body);
        open = [body];
        tracked.length = 0;
        tracked.assumeSafeAppend();
        touched.length = 0;
        touched.assumeSafeAppend();
        skipped = 0;
        rects = null;
    }

    /// Lays out at `viewport`, records rects, paints and drops unused memory.
    private void end(Size viewport)
    {
        LayoutOwner owner = new LayoutOwner(root, viewport);
        owner.flush();
        foreach (Tracked t; tracked)
        {
            rects[t.id] = t.node.bounds;
        }
        lastRects = rects;
        drawn = null;
        paint(root, style!TextStyle().color);
        foreach (Id id; memoryUsed.keys)
        {
            if (memoryUsed[id] != pass)
            {
                memory.remove(id);
                memoryUsed.remove(id);
            }
        }
        pressed = false;
    }

    /// FNV-1a of the call site and pushed keys.
    Id id(string file, size_t line)
    {
        Id h = 0xcbf2_9ce4_8422_2325;
        void mix(const(ubyte)[] bytes)
        {
            foreach (ubyte b; bytes)
            {
                h = (h ^ b) * 0x100_0000_01b3;
            }
        }
        foreach (Id k; idStack)
        {
            mix((cast(const(ubyte)*) &k)[0 .. Id.sizeof]);
        }
        mix(cast(const(ubyte)[]) file);
        mix((cast(const(ubyte)*) &line)[0 .. size_t.sizeof]);
        return h;
    }

    /// Scopes following IDs by `key`, for loop bodies.
    void pushId(Id key)
    {
        idStack ~= key;
    }

    /// Ends the innermost `pushId`.
    void popId()
    {
        idStack.length -= 1;
        idStack.assumeSafeAppend();
    }

    /// Persistent state of type `T` for `id`, created from `init` on first use.
    T* memoryFor(T)(Id id, T init)
    {
        static final class Box
        {
            T value; /// stored state
        }

        memoryUsed[id] = pass;
        touched ~= id;
        if (Object* o = id in memory)
        {
            Box found = cast(Box) *o;
            assert(found !is null, "per-ID memory reused with another type, IDs collide");
            return &found.value;
        }
        Box b = new Box;
        b.value = init;
        memory[id] = b;
        return &b.value;
    }

    /// True if the pointer is over `id` as laid out last frame.
    bool hovered(Id id)
    {
        Rect* r = id in lastRects;
        return r !is null && r.contains(mouse);
    }

    /// Adds `n` to the open container.
    void put(Node n)
    {
        open[$ - 1].add(n);
    }

    /// Runs `children` with `n` as the open container.
    void inside(Node n, scope void delegate() children)
    {
        open ~= n;
        if (children !is null)
        {
            children();
        }
        open.length -= 1;
        open.assumeSafeAppend();
    }

    /// The single node declared by `child`, not yet attached.
    Node one(scope void delegate() child)
    {
        Fixed scratch = new Fixed(Size.init);
        inside(scratch, child);
        assert(scratch.children.length == 1, "exactly one child expected");
        return scratch.children[0];
    }

    /// Records the rect of `n` under `id` at `end`, for next frame's `hovered` and `clickable`.
    void track(Node n, Id id)
    {
        tracked ~= Tracked(n, id);
    }

    /// Pointer state of `id` from last frame's rects, none if disabled. A click asks for another build pass.
    Press clickable(Id id, bool enabled = true)
    {
        if (enabled == false || hovered(id) == false)
        {
            return Press.init;
        }
        again = again || pressed;
        return Press(true, down, pressed);
    }

    /// Style `T` for `variant`: from the theme or `T`'s defaults, then the `withStyle` edits, innermost last.
    T style(T)(string variant = null)
    {
        T s = theme is null ? T.init : theme.style!T(variant);
        if (Object* o = T.mangleof in edits)
        {
            foreach (void delegate(ref T) e; (cast(Edits!T) *o).items)
            {
                e(s);
            }
        }
        return s;
    }

    /// Edit for every `T` read inside, then the children:
    /// `ui.withStyle((ref ButtonStyle s) { s.padX = 2; })({ ... })`.
    StyleScope!T withStyle(T)(void delegate(ref T) edit)
    {
        return StyleScope!T(this, edit);
    }

    /// Edit stack of style `T`, created on first use.
    private Edits!T editsOf(T)()
    {
        if (Object* o = T.mangleof in edits)
        {
            return cast(Edits!T) *o;
        }
        Edits!T e = new Edits!T;
        edits[T.mangleof] = e;
        return e;
    }

    /// True if `p` is inside any of `nodes` as laid out last frame.
    private static bool under(Node[] nodes, Point p)
    {
        foreach (Node n; nodes)
        {
            if (n.bounds.contains(p))
            {
                return true;
            }
        }
        return false;
    }

    /// Declares `content` once and reuses its nodes on later frames while `inputs`
    /// compare equal, no press lands inside and it handled no input. This is path D.
    /// NOTE: re-runs on press only. Hover styling inside would need the same check.
    void memo(T)(T inputs, scope void delegate() content,
        string file = __FILE__, size_t line = __LINE__)
    {
        Id i = id(file, line);
        Memo!T* slot = memoryFor!(Memo!T)(i, null);
        Memo!T m = *slot;
        if (m !is null && m.inputs == inputs && m.stale == false
            && (pressed && under(m.nodes, mouse)) == false)
        {
            foreach (Node n; m.nodes)
            {
                put(n);
            }
            tracked ~= m.tracked;
            foreach (Id t; m.touched)
            {
                memoryUsed[t] = pass;
            }
            touched ~= m.touched;
            ++skipped;
            return;
        }
        size_t trackedFrom = tracked.length;
        size_t touchedFrom = touched.length;
        bool outerAgain = again;
        again = false;
        Fixed scratch = new Fixed(Size.init);
        pushId(i);
        inside(scratch, content);
        popId();
        Node[] nodes = scratch.children.dup;
        foreach (Node n; nodes)
        {
            put(n);
        }
        if (m is null)
        {
            m = new Memo!T;
            *slot = m;
        }
        m.inputs = inputs;
        m.nodes = nodes;
        m.tracked = tracked[trackedFrom .. $].dup;
        m.touched = touched[touchedFrom .. $].dup;
        m.stale = again;
        again = again || outerAgain;
    }

    /// Appends text, button and box rects of the laid-out tree to `drawn`. Text inherits `ink`
    /// unless a surface sets its own, as CSS `color` does.
    private void paint(Node n, Color ink)
    {
        if (Label l = cast(Label) n)
        {
            drawn ~= Drawn(l.text.bounds, l.text.content, ink);
            return;
        }
        if (ButtonNode b = cast(ButtonNode) n)
        {
            drawn ~= Drawn(b.bounds, b.caption);
        }
        else if (Surface s = cast(Surface) n)
        {
            drawn ~= Drawn(s.bounds, null, s.fill);
            if (s.ink.a > 0)
            {
                ink = s.ink;
            }
        }
        foreach (Node c; n.children)
        {
            paint(c, ink);
        }
    }

    /// Rect of the first drawn item with `text`.
    Rect find(string text)
    {
        foreach (Drawn d; drawn)
        {
            if (d.text == text)
            {
                return d.r;
            }
        }
        assert(false, "not drawn: " ~ text);
    }
}

/// Vertical group. Options by name in any order, then the children:
/// `ui.column(gap: 4)({ ... })`. Two calls for the reason given at `layout.FlexSpec`.
Group column(Ui ui, float gap = 0, CrossAlign cross = CrossAlign.start)
{
    return Group(ui, Axis.vertical, gap, cross);
}

/// Horizontal group, as `column`.
Group row(Ui ui, float gap = 0, CrossAlign cross = CrossAlign.start)
{
    return Group(ui, Axis.horizontal, gap, cross);
}

/// Single child that takes the remaining space of its flex parent.
void expand(Ui ui, scope void delegate() child)
{
    ui.put(new Flexible(ui.one(child)));
}

/// Box that grows with its parent, for text fields and spacers.
void box(Ui ui, float height = 0)
{
    ui.put(new Fixed(Size(0, height)));
}

/// Text.
void label(Ui ui, string s)
{
    ui.put(new Label(s));
}

/// Button, true on the frame it is clicked.
bool button(Ui ui, string caption, string file = __FILE__, size_t line = __LINE__)
{
    Id i = ui.id(file, line);
    ButtonNode n = new ButtonNode(caption);
    ui.put(n);
    ui.track(n, i);
    return ui.clickable(i).clicked;
}

/// Checkbox bound to `value`, toggled when clicked.
bool checkbox(Ui ui, ref bool value, string caption, string file = __FILE__, size_t line = __LINE__)
{
    Id i = ui.id(file, line);
    Label n = new Label((value ? "[x] " : "[ ] ") ~ caption);
    ui.put(n);
    ui.track(n, i);
    bool clicked = ui.clickable(i).clicked;
    if (clicked)
    {
        value = value == false;
    }
    return clicked;
}

/// Header that hides `children` when collapsed. Open state lives in per-ID memory.
void collapsing(Ui ui, string title, scope void delegate() children,
    string file = __FILE__, size_t line = __LINE__)
{
    Id i = ui.id(file, line);
    bool* isOpen = ui.memoryFor!bool(i, true);
    if (ui.clickable(i).clicked)
    {
        *isOpen = *isOpen == false;
    }
    Label header = new Label((*isOpen ? "v " : "> ") ~ title);
    ui.put(header);
    ui.track(header, i);
    if (*isOpen)
    {
        children();
    }
}

/// Breakpoint as plain data.
struct Breakpoint
{
    uint id;            /// stable key
    string file;        /// source file
    uint line;          /// source line
    bool enabled = true; /// checkbox state
    uint hits;          /// hit count
}

/// Breakpoints panel: plain code over plain data, as in ddui, with real layout.
void breakpointsPanel(Ui ui, ref Breakpoint[] items, string filter)
{
    ui.row(gap: 4, cross: CrossAlign.center)({
        ui.label("Filter");
        ui.expand({ ui.box(height: 20); });
    });
    size_t shown;
    ui.expand({
        ui.column(cross: CrossAlign.stretch)({
            foreach (ref Breakpoint bp; items)
            {
                if (filter.length > 0 && bp.file != filter)
                {
                    continue;
                }
                ++shown;
                ui.pushId(bp.id);
                scope (exit)
                {
                    ui.popId();
                }
                ui.row(gap: 4, cross: CrossAlign.center)({
                    ui.checkbox(bp.enabled, format("%s:%d", bp.file, bp.line));
                    ui.label(format("%d", bp.hits));
                });
            }
        });
    });
    ui.row(gap: 4, cross: CrossAlign.center)({
        ui.label(format("%d of %d shown", shown, items.length));
        ui.expand({ ui.box(); });
        if (ui.button("Remove disabled"))
        {
            Breakpoint[] kept;
            foreach (ref Breakpoint b; items)
            {
                if (b.enabled)
                {
                    kept ~= b;
                }
            }
            items = kept;
        }
    });
}

/// Five breakpoints across three files.
private Breakpoint[] sample()
{
    return [
        Breakpoint(1, "main.d", 10),
        Breakpoint(2, "main.d", 42),
        Breakpoint(3, "parser.d", 7),
        Breakpoint(4, "parser.d", 99),
        Breakpoint(5, "lexer.d", 3),
    ];
}

/// First frame is already laid out like the retained version in layout.d.
unittest
{
    Ui ui = new Ui;
    Breakpoint[] items = sample();
    ui.frame({ breakpointsPanel(ui, items, null); }, Size(400, 300));
    assert(ui.find("Remove disabled") == Rect(272, 268, 120, 24), "same rect as layout.d");
    assert(ui.find("5 of 5 shown").y == 272, "centered in the 24 px footer");
}

/// Click lands on what the user saw, and the frame it lands in already shows the change.
unittest
{
    Ui ui = new Ui;
    Breakpoint[] items = sample();
    items[1].enabled = false;
    int passes;
    void run()
    {
        ui.frame({
            ++passes;
            breakpointsPanel(ui, items, null);
        }, Size(400, 300));
    }

    run();
    Rect b = ui.find("Remove disabled");
    ui.mouse = Point(b.x + 5, b.y + 5);
    ui.pressed = true;
    passes = 0;
    run();
    assert(items.length == 4);
    assert(passes == 2, "built again before drawing");
    ui.find("4 of 4 shown");
}

/// Checkbox IDs are scoped by breakpoint ID, so a click toggles the right one, once.
unittest
{
    Ui ui = new Ui;
    Breakpoint[] items = sample();
    ui.frame({ breakpointsPanel(ui, items, null); }, Size(400, 300));
    Rect r = ui.find("[x] parser.d:7");
    ui.mouse = Point(r.x + 2, r.y + 2);
    ui.pressed = true;
    ui.frame({ breakpointsPanel(ui, items, null); }, Size(400, 300));
    assert(items[2].enabled == false, "the second pass did not toggle it back");
    assert(items[1].enabled && items[3].enabled);
    ui.find("[ ] parser.d:7");
}

/// Per-ID memory survives frames while declared and is dropped when not.
unittest
{
    Ui ui = new Ui;
    bool showPanel = true;
    void run()
    {
        ui.frame({
            if (showPanel)
            {
                ui.collapsing("Watch", { ui.label("x = 1"); });
            }
        }, Size(200, 100));
    }

    run();
    ui.find("x = 1");
    Rect h = ui.find("v Watch");
    ui.mouse = Point(h.x + 1, h.y + 1);
    ui.pressed = true;
    run();
    ui.find("> Watch");
    run();
    ui.find("> Watch");
    showPanel = false;
    run();
    showPanel = true;
    run();
    ui.find("v Watch");
    ui.find("x = 1");
}

/// `memo` reuses a row while its breakpoint is unchanged, and re-runs it on change or press.
unittest
{
    Ui ui = new Ui;
    Breakpoint[] items = sample();
    int runs;
    void run()
    {
        ui.frame({
            foreach (ref Breakpoint bp; items)
            {
                ui.pushId(bp.id);
                ui.memo(bp, {
                    ++runs;
                    ui.checkbox(bp.enabled, format("%s:%d", bp.file, bp.line));
                });
                ui.popId();
            }
        }, Size(400, 300));
    }

    run();
    assert(runs == 5 && ui.skipped == 0);
    run();
    assert(runs == 5 && ui.skipped == 5, "nothing changed, nothing declared");
    ui.find("[x] parser.d:7");
    items[3].hits = 1;
    run();
    assert(runs == 6 && ui.skipped == 4);

    Rect r = ui.find("[x] parser.d:7");
    ui.mouse = Point(r.x + 2, r.y + 2);
    ui.pressed = true;
    run();
    assert(runs == 8 && items[2].enabled == false, "the press re-runs the row, then its changed inputs do");
    ui.find("[ ] parser.d:7");
    run();
    assert(runs == 8 && ui.skipped == 5);
}

/// A reused subtree that handled input re-runs in the next pass, and its per-ID memory survives skipped frames.
unittest
{
    Ui ui = new Ui;
    int rev;
    void run()
    {
        ui.frame({ ui.memo(rev, { ui.collapsing("Watch", { ui.label("x = 1"); }); }); }, Size(200, 100));
    }

    run();
    Rect h = ui.find("v Watch");
    ui.mouse = Point(h.x + 1, h.y + 1);
    ui.pressed = true;
    run();
    assert(ui.skipped == 0, "handled input in the first pass, so the second re-ran it");
    ui.find("> Watch");
    run();
    run();
    assert(ui.skipped == 1);
    ++rev;
    run();
    assert(ui.skipped == 0);
    ui.find("> Watch");
}
