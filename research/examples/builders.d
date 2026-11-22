/// Six ways to write the same tree in D, all producing `layout` nodes.
///
/// Plain constructors, fluent chains, nested delegates, a `with` block, named
/// arguments, and CTFE markup from a string import. Plus a UDA-driven
/// inspector built by compile-time reflection. Build with `-J.` for the markup.
module builders;

import layout;
import std.ascii : isWhite;
import std.conv : to;
import std.format : format;
import std.traits : FieldNameTuple;

/// Fluent wrapper around a flex container.
final class FlexBuilder
{
    private Flex node; /// container being built

    /// Starts a container on `axis`.
    this(Axis axis)
    {
        node = new Flex(axis, 0, CrossAlign.start, null);
    }

    /// Sets the gap.
    FlexBuilder gap(float g)
    {
        node.gap = g;
        return this;
    }

    /// Sets cross-axis placement.
    FlexBuilder cross(CrossAlign c)
    {
        node.cross = c;
        return this;
    }

    /// Adds a fixed child.
    FlexBuilder child(Node n)
    {
        node.add(n);
        return this;
    }

    /// Adds a child that takes the remaining space.
    FlexBuilder grow(Node n)
    {
        node.add(expanded(n));
        return this;
    }

    /// Adds a nested builder's result.
    FlexBuilder child(FlexBuilder b)
    {
        return child(b.node);
    }

    /// The finished container.
    Flex done()
    {
        return node;
    }
}

/// Fluent row.
FlexBuilder hbox()
{
    return new FlexBuilder(Axis.horizontal);
}

/// Fluent column.
FlexBuilder vbox()
{
    return new FlexBuilder(Axis.vertical);
}

/// Builder for the nested-delegate style. Children attach to the innermost open container.
struct Builder
{
    Node result;        /// first top-level node
    private Node[] open; /// containers being declared

    /// Attaches `n` to the open container, or makes it the result.
    private void put(Node n)
    {
        if (open.length > 0)
        {
            open[$ - 1].add(n);
        }
        else if (result is null)
        {
            result = n;
        }
    }

    /// Declares `n` and runs `children` inside it.
    private void nest(Node n, scope void delegate() children)
    {
        put(n);
        open ~= n;
        children();
        open.length -= 1;
    }

    /// Vertical container.
    void column(float gap, CrossAlign cross, scope void delegate() children)
    {
        nest(new Flex(Axis.vertical, gap, cross, null), children);
    }

    /// Horizontal container.
    void row(float gap, CrossAlign cross, scope void delegate() children)
    {
        nest(new Flex(Axis.horizontal, gap, cross, null), children);
    }

    /// The single node declared by `child`.
    /// NOTE: not wrapped in a column, a column would hand it an unbounded height.
    private Node one(scope void delegate() child)
    {
        Fixed scratch = new Fixed(Size.init);
        open ~= scratch;
        child();
        open.length -= 1;
        assert(scratch.children.length == 1, "exactly one child expected");
        return scratch.children[0];
    }

    /// Padding around one child.
    void pad(float all, scope void delegate() child)
    {
        put(new Padding(Insets.all(all), one(child)));
    }

    /// One child taking the remaining space.
    void grow(scope void delegate() child)
    {
        put(expanded(one(child)));
    }

    /// Text leaf, returned for later updates.
    Text text(string s)
    {
        Text t = new Text(s);
        put(t);
        return t;
    }

    /// Fixed-size leaf.
    void box(float w, float h)
    {
        put(new Fixed(Size(w, h)));
    }
}

/// D expression building the tree described by s-expression `src`. Runs at compile time.
///
/// Forms: `(column gap align ...)`, `(row gap align ...)`, `(pad n child)`,
/// `(grow child)`, `(box w h)`, `(text "s")` and `(text "s" @var)` which also
/// assigns the node to `var`.
string markupToD(string src)
{
    size_t i;

    /// Skips spaces and newlines.
    void skip()
    {
        while (i < src.length && isWhite(src[i]))
        {
            ++i;
        }
    }

    /// Next bare word.
    string word()
    {
        skip();
        size_t s = i;
        while (i < src.length && src[i] != ' ' && src[i] != ')' && src[i] != '(' && src[i] != '\n')
        {
            ++i;
        }
        if (i == s)
        {
            assert(false, format("ui markup: word expected at offset %d", s));
        }
        return src[s .. i];
    }

    /// Next quoted string, quotes kept.
    string quoted()
    {
        skip();
        if (i >= src.length || src[i] != '"')
        {
            assert(false, format("ui markup: string expected at offset %d", i));
        }
        size_t s = i++;
        while (i < src.length && src[i] != '"')
        {
            ++i;
        }
        return src[s .. ++i];
    }

    /// Consumes `c` or fails.
    void expect(char c)
    {
        skip();
        if (i >= src.length || src[i] != c)
        {
            assert(false, format("ui markup: '%s' expected at offset %d", c, i));
        }
        ++i;
    }

    /// One parenthesized form.
    string node()
    {
        expect('(');
        string name = word();
        string r;
        switch (name)
        {
        case "column":
        case "row":
            string gap = word();
            string cross = word();
            r = name ~ "(" ~ gap ~ ", CrossAlign." ~ cross ~ ")(";
            string sep;
            skip();
            while (i < src.length && src[i] == '(')
            {
                r ~= sep ~ node();
                sep = ", ";
                skip();
            }
            r ~= ")";
            break;
        case "pad":
            string n = word();
            r = "new Padding(Insets.all(" ~ n ~ "), " ~ node() ~ ")";
            break;
        case "grow":
            r = "expanded(" ~ node() ~ ")";
            break;
        case "box":
            string w = word();
            string h = word();
            r = "new Fixed(Size(" ~ w ~ ", " ~ h ~ "))";
            break;
        case "text":
            r = "new Text(" ~ quoted() ~ ")";
            skip();
            if (i < src.length && src[i] == '@')
            {
                ++i;
                r = "(" ~ word() ~ " = " ~ r ~ ")";
            }
            break;
        default:
            assert(false, "ui markup: unknown form " ~ name);
        }
        expect(')');
        return r;
    }

    string r = node();
    skip();
    if (i != src.length)
    {
        assert(false, format("ui markup: trailing input at offset %d", i));
    }
    return r;
}

/// Compile-time translation of markup, for `mixin(ui!(import("file.ui")))`.
enum string ui(string src) = markupToD(src);

/// Field label for the inspector.
struct label
{
    string text; /// shown instead of the field name
}

/// Excludes a field from the inspector.
enum hidden;

/// Rows of "label: value" for each field of `value`, built by reflection.
Flex inspector(T)(ref T value)
{
    Flex col = new Flex(Axis.vertical, 2, CrossAlign.stretch, null);
    static foreach (string name; FieldNameTuple!T)
    {{
        alias attrs = __traits(getAttributes, __traits(getMember, T, name));
        string text = to!string(__traits(getMember, value, name));
        static if (attrs.length == 0)
        {
            col.add(new Text(name ~ ": " ~ text));
        }
        else static if (is(typeof(attrs[0]) == label))
        {
            col.add(new Text(attrs[0].text ~ ": " ~ text));
        }
    }}
    return col;
}

/// Button and summary rects after laying `root` out in 400x300.
private Rect[2] probe(Node root, Text summary, Node button)
{
    LayoutOwner owner = new LayoutOwner(root, Size(400, 300));
    owner.flush();
    return [summary.bounds, button.bounds];
}

/// The same panel skeleton in six styles gives the same layout.
unittest
{
    enum Rect[2] expect = [Rect(8, 272, 96, 16), Rect(272, 268, 120, 24)];

    // 1. plain constructors
    Text s1 = new Text("5 of 5 shown");
    Fixed b1 = new Fixed(Size(120, 24));
    Node r1 = new Padding(Insets.all(8), column(4, CrossAlign.stretch)(
        row(4, CrossAlign.center)(new Text("Filter"), expanded(new Fixed(Size(0, 20)))),
        expanded(new Padding(Insets.all(4), column(0, CrossAlign.stretch)(new Text("main.d:42")))),
        row(4, CrossAlign.center)(s1, expanded(new Fixed(Size(0, 0))), b1)));
    assert(probe(r1, s1, b1) == expect);

    // 2. fluent chains
    Text s2 = new Text("5 of 5 shown");
    Fixed b2 = new Fixed(Size(120, 24));
    Node r2 = new Padding(Insets.all(8), vbox().gap(4).cross(CrossAlign.stretch)
        .child(hbox().gap(4).cross(CrossAlign.center)
            .child(new Text("Filter"))
            .grow(new Fixed(Size(0, 20))))
        .grow(new Padding(Insets.all(4), vbox().cross(CrossAlign.stretch)
            .child(new Text("main.d:42"))
            .done()))
        .child(hbox().gap(4).cross(CrossAlign.center)
            .child(s2)
            .grow(new Fixed(Size(0, 0)))
            .child(b2))
        .done());
    assert(probe(r2, s2, b2) == expect);

    // 3. nested delegates
    Builder b;
    Text s3;
    b.pad(8, {
        b.column(4, CrossAlign.stretch, {
            b.row(4, CrossAlign.center, {
                b.text("Filter");
                b.grow({ b.box(0, 20); });
            });
            b.grow({ b.pad(4, { b.column(0, CrossAlign.stretch, { b.text("main.d:42"); }); }); });
            b.row(4, CrossAlign.center, {
                s3 = b.text("5 of 5 shown");
                b.grow({ b.box(0, 0); });
                b.box(120, 24);
            });
        });
    });
    Node b3 = s3.parent.children[$ - 1];
    assert(probe(b.result, s3, b3) == expect);

    // 4. with block over the same builder
    Builder w;
    Text s4;
    with (w)
    {
        pad(8, {
            column(4, CrossAlign.stretch, {
                row(4, CrossAlign.center, {
                    text("Filter");
                    grow({ box(0, 20); });
                });
                grow({ pad(4, { column(0, CrossAlign.stretch, { text("main.d:42"); }); }); });
                row(4, CrossAlign.center, {
                    s4 = text("5 of 5 shown");
                    grow({ box(0, 0); });
                    box(120, 24);
                });
            });
        });
    }
    assert(probe(w.result, s4, s4.parent.children[$ - 1]) == expect);

    // 5. named arguments: options by name in any order, then the children
    Text s5 = new Text("5 of 5 shown");
    Fixed b5 = box(w: 120, h: 24);
    Node r5 = pad(all: 8, column(gap: 4, cross: CrossAlign.stretch)(
        row(cross: CrossAlign.center, gap: 4)(new Text("Filter"), expanded(box(h: 20))),
        expanded(pad(all: 4, column(cross: CrossAlign.stretch)(new Text("main.d:42")))),
        row(gap: 4, cross: CrossAlign.center)(s5, expanded(box()), b5)));
    assert(probe(r5, s5, b5) == expect);

    // 6. CTFE markup from a string import
    Text summary;
    Node r6 = mixin(ui!(import("panel.ui")));
    assert(probe(r6, summary, summary.parent.children[$ - 1]) == expect);
}

/// Inspector rows come from fields and their attributes.
unittest
{
    static struct BreakpointInfo
    {
        @label("Location") string where = "main.d:42";
        @label("Hit count") uint hits = 3;
        bool enabled = true;
        @hidden uint internalId = 77;
    }

    BreakpointInfo info;
    Flex rows = inspector(info);
    string[] lines;
    foreach (Node n; rows.children)
    {
        lines ~= (cast(Text) n).content;
    }
    assert(lines == ["Location: main.d:42", "Hit count: 3", "enabled: true"]);
}
