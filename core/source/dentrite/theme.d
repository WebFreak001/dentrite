/// Theme files: a color palette and one section per style struct, loaded by field name.
///
/// A style struct names its section with `enum section`. `[button]` sets every
/// variant, then `[button.danger]` overrides fields for one variant. A struct
/// with `static void applyVariant(ref T, string)` gives its variants a look of
/// their own without a theme, applied between the two. An app adds variants of
/// its own with `Variants`. Colors are `#rrggbb`, `#rrggbbaa` or a
/// palette token, other values are D literals. The same code runs at compile time
/// over a string import.
module dentrite.theme;

import std.algorithm.searching : all, startsWith;
import std.ascii : isHexDigit;
import std.conv : ConvException, to;
import std.format : format;
import std.string : indexOf, lineSplitter, strip;
import std.traits : FieldNameTuple;

public import dentrite.geom : Color;

/// `key = value` line of a theme file.
struct Entry
{
    string key;   /// style field or palette token name
    string value; /// value as written, unparsed: a color, a palette token or a D literal
    size_t line;  /// line number in the theme file
}

/// `[name]` header and the entries under it.
struct Section
{
    string name;     /// section name, such as `button` or `button.danger`
    size_t line;     /// line number of the header in the theme file
    Entry[] entries; /// entries under the header, in file order
}

/// Sections of `text` in file order. Throws on a line that is not a header, an entry or a `#` comment.
Section[] parseSections(string text, string file)
{
    Section[] sections;
    size_t n;
    foreach (string raw; text.lineSplitter)
    {
        ++n;
        string line = raw.strip;
        if (line.length == 0 || line.startsWith("#"))
        {
            continue;
        }
        if (line[0] == '[' && line[$ - 1] == ']')
        {
            sections ~= Section(line[1 .. $ - 1].strip, n);
            continue;
        }
        ptrdiff_t eq = line.indexOf('=');
        if (eq < 0 || sections.length == 0)
        {
            throw new Exception(format("%s(%d): expected [section] or key = value", file, n));
        }
        sections[$ - 1].entries ~= Entry(line[0 .. eq].strip, line[eq + 1 .. $].strip, n);
    }
    return sections;
}

/// Color of entry `e`: `#rrggbb`, `#rrggbbaa` or a token of `palette`.
Color colorOf(const Entry e, const Color[string] palette, string file)
{
    if (e.value.startsWith("#"))
    {
        string hex = e.value[1 .. $];
        if ((hex.length == 6 || hex.length == 8) && hex.all!isHexDigit)
        {
            uint n = to!uint(hex, 16);
            if (hex.length == 6)
            {
                n = n << 8 | 0xff;
            }
            return Color(cast(ubyte)(n >> 24), cast(ubyte)(n >> 16), cast(ubyte)(n >> 8), cast(ubyte) n);
        }
        throw new Exception(format("%s(%d): bad color %s, expected #rrggbb or #rrggbbaa", file, e.line, e.value));
    }
    if (const(Color)* c = e.value in palette)
    {
        return *c;
    }
    throw new Exception(format("%s(%d): no palette token %s", file, e.line, e.value));
}

/// Tokens of the `[palette]` sections. A token may name one defined above it.
Color[string] paletteOf(const Section[] sections, string file)
{
    Color[string] palette;
    foreach (ref const Section s; sections)
    {
        if (s.name == "palette")
        {
            foreach (ref const Entry e; s.entries)
            {
                palette[e.key] = colorOf(e, palette, file);
            }
        }
    }
    return palette;
}

/// Sets the fields of `s` named by the entries of `sec`. Throws on an unknown field or a bad value.
void apply(T)(ref T s, const Section sec, const Color[string] palette, string file)
{
    foreach (ref const Entry e; sec.entries)
    {
        bool known;
        static foreach (string name; FieldNameTuple!T)
        {
            if (e.key == name)
            {
                known = true;
                alias F = typeof(__traits(getMember, s, name));
                static if (is(F == Color))
                {
                    __traits(getMember, s, name) = colorOf(e, palette, file);
                }
                else
                {
                    try
                    {
                        __traits(getMember, s, name) = to!F(e.value);
                    }
                    catch (ConvException)
                    {
                        throw new Exception(format("%s(%d): %s is not a %s", file, e.line, e.value, F.stringof));
                    }
                }
            }
        }
        if (known == false)
        {
            throw new Exception(format("%s(%d): %s has no field %s", file, e.line, T.stringof, e.key));
        }
    }
}

/// Style `T` for `variant`: the struct defaults, then section `T.section`, then the variant's defaults from
/// `T.applyVariant` if any, then `T.section.variant`. Empty `sections` give the look without a theme.
T resolve(T)(const Section[] sections, const Color[string] palette, string variant, string file)
{
    T s;
    foreach (ref const Section sec; sections)
    {
        if (sec.name == T.section)
        {
            apply(s, sec, palette, file);
        }
    }
    if (variant.length > 0)
    {
        static if (__traits(hasMember, T, "applyVariant"))
        {
            T.applyVariant(s, variant);
        }
        string own = T.section ~ "." ~ variant;
        foreach (ref const Section sec; sections)
        {
            if (sec.name == own)
            {
                apply(s, sec, palette, file);
            }
        }
    }
    return s;
}

/// Variants of style `T` an app adds, named `names`, for `check` and `checkTheme`:
/// `t.check!(LibraryStyles, Variants!(ButtonStyle, "large", "compact"))()` accepts `[button.large]`.
struct Variants(T, names...)
{
    alias Style = T;              /// style the variants belong to
    enum string[] list = [names]; /// variant names
}

/// True if `T` is a `Variants`.
private enum bool isVariants(T) = is(T == Variants!(S, N), S, N...);

/// Style struct `T` reads into: `T` itself, or the style of a `Variants`.
private template StyleOf(T)
{
    static if (isVariants!T)
    {
        alias StyleOf = T.Style;
    }
    else
    {
        alias StyleOf = T;
    }
}

/// True if `T` reads section `name`: the style's own, or one per member of `T.Variants` if declared. A
/// `Variants` reads its listed sections alone.
private bool claims(T)(string name)
{
    static if (isVariants!T)
    {
        foreach (string v; T.list)
        {
            if (name == T.Style.section ~ "." ~ v)
            {
                return true;
            }
        }
        return false;
    }
    else
    {
        return claimsOwn!T(name);
    }
}

/// `claims` for a style struct.
private bool claimsOwn(T)(string name)
{
    if (name == T.section)
    {
        return true;
    }
    static if (is(T.Variants == enum))
    {
        static foreach (string v; __traits(allMembers, T.Variants))
        {
            if (name == T.section ~ "." ~ v)
            {
                return true;
            }
        }
    }
    return false;
}

/// Throws for a section no style of `Styles` reads, or for a bad entry in one they read.
void check(Styles...)(const Section[] sections, const Color[string] palette, string file)
{
    foreach (ref const Section sec; sections)
    {
        bool read = sec.name == "palette";
        static foreach (T; Styles)
        {
            if (claims!T(sec.name))
            {
                read = true;
                StyleOf!T probe;
                apply(probe, sec, palette, file);
            }
        }
        if (read == false)
        {
            throw new Exception(format("%s(%d): no style reads section [%s]", file, sec.line, sec.name));
        }
    }
}

/// True if `text` parses and passes `check` for `Styles`, else throws. For `static assert`.
bool checkTheme(Styles...)(string text, string file)
{
    Section[] sections = parseSections(text, file);
    check!Styles(sections, paletteOf(sections, file), file);
    return true;
}

/// Style `T` for `variant` straight from theme file text, for compile-time use.
T loadStyle(T)(string text, string file, string variant)
{
    Section[] sections = parseSections(text, file);
    return resolve!T(sections, paletteOf(sections, file), variant, file);
}

/// Parsed theme file. Styles resolve on first use and stay cached, so reloading means a new `Theme`.
final class Theme
{
    string file;                   /// file name shown in error messages
    private Section[] sections;    /// in file order
    private Color[string] palette; /// tokens of `[palette]`
    private Object[string] caches; /// `Cache!T` by `T.mangleof`

    /// Resolved styles of type `T` by variant.
    private static final class Cache(T)
    {
        T[string] byVariant; /// resolved styles
    }

    /// Parses `text`, read from `file`. Entries are checked on use or by `check`.
    this(string text, string file)
    {
        this.file = file;
        sections = parseSections(text, file);
        palette = paletteOf(sections, file);
    }

    /// Style `T` for `variant`, resolved on first use.
    T style(T)(string variant)
    {
        Cache!T c;
        if (Object* o = T.mangleof in caches)
        {
            c = cast(Cache!T) *o;
        }
        else
        {
            c = new Cache!T;
            caches[T.mangleof] = c;
        }
        if (T* hit = variant in c.byVariant)
        {
            return *hit;
        }
        T s = resolve!T(sections, palette, variant, file);
        c.byVariant[variant] = s;
        return s;
    }

    /// Throws for a section no style of `Styles` reads, or for a bad entry in one they read.
    /// Run it on a reloaded theme before swapping it in.
    void check(Styles...)()
    {
        .check!Styles(sections, palette, file);
    }
}

version (unittest)
{
    /// Sizes of `Probe`.
    private enum Loudness
    {
        quiet, /// default
        loud,  /// bigger and bold
    }

    /// Style struct for the tests.
    private struct Probe
    {
        enum section = "probe";    /// theme file section
        alias Variants = Loudness; /// variant sections

        Color ink;       /// text color
        float size = 12; /// text size
        bool bold;       /// heavy weight
    }

    /// Theme text for the tests.
    private enum string sample = `
# comment
[palette]
gray.900 = #1d1d20
ink = gray.900
shadow = #00000080

[probe]
ink = ink

[probe.loud]
size = 16
bold = true
`;

    /// Message of the exception `dg` throws, or null.
    private string thrown(scope void delegate() dg)
    {
        try
        {
            dg();
        }
        catch (Exception e)
        {
            return e.msg;
        }
        return null;
    }
}

// A variant starts from the base section, which starts from the struct defaults.
unittest
{
    Theme t = new Theme(sample, "t.theme");
    t.check!Probe();
    Probe quiet = t.style!Probe("quiet");
    Probe loud = t.style!Probe("loud");
    assert(quiet.ink == Color(0x1d, 0x1d, 0x20, 0xff), "token naming a token");
    assert(quiet.size == 12 && quiet.bold == false, "struct defaults");
    assert(loud.ink == quiet.ink && loud.size == 16 && loud.bold);
    assert(t.palette["shadow"] == Color(0, 0, 0, 0x80));
}

// Mistakes name the file and line, as compiler errors do.
unittest
{
    /// Error of checking `sample` with `extra` appended.
    string error(string extra)
    {
        return thrown({ new Theme(sample ~ extra, "t.theme").check!Probe(); });
    }

    assert(error("[probe]\nsiz = 14\n") == "t.theme(15): Probe has no field siz");
    assert(error("[probe]\nsize = big\n") == "t.theme(15): big is not a float");
    assert(error("[probe]\nink = grey.900\n") == "t.theme(15): no palette token grey.900");
    assert(error("[probe]\nink = #1d1d2\n") == "t.theme(15): bad color #1d1d2, expected #rrggbb or #rrggbbaa");
    assert(error("[prob]\n") == "t.theme(14): no style reads section [prob]");
    assert(error("[probe.lound]\n") == "t.theme(14): no style reads section [probe.lound]");
    assert(error("size 14\n") == "t.theme(14): expected [section] or key = value");
}

// An app adds variants by naming them for the check, which still rejects others.
unittest
{
    enum string text = sample ~ "[probe.huge]\nsize = 30\n";
    Theme t = new Theme(text, "t.theme");
    assert(thrown({ t.check!Probe(); }) == "t.theme(14): no style reads section [probe.huge]");
    t.check!(Probe, Variants!(Probe, "huge", "tiny"))();
    assert(t.style!Probe("huge").size == 30 && t.style!Probe("huge").ink == t.style!Probe(null).ink);
    static assert(checkTheme!(Probe, Variants!(Probe, "huge"))(text, "t.theme"));
}

// The same loader runs at compile time, where a mistake fails the build.
unittest
{
    enum Probe loud = loadStyle!Probe(sample, "t.theme", "loud");
    static assert(loud.size == 16 && loud.ink == Color(0x1d, 0x1d, 0x20, 0xff));
    static assert(__traits(compiles, { enum Probe p = loadStyle!Probe(sample ~ "[probe]\nsiz = 1", "t", null); })
        == false);
}
