#!/usr/bin/env rdmd
/// Builds the API reference from the DDoc comments into `bin/apidoc/`, one page per module and an index. Run
/// `rdmd tools/apidoc.d` from any directory, `--help` lists the options. Layout is in `apidoc.ddoc` and
/// `apidoc.css` next to this file. C bindings (`dentrite.c.*`) are left out.
module apidoc;

import std.algorithm.searching : startsWith;
import std.algorithm.sorting : sort;
import std.array : appender, Appender, replace, split;
import std.file : copy, dirEntries, exists, mkdirRecurse, readText, rename, rmdirRecurse, SpanMode, write;
import std.format : format;
import std.getopt : defaultGetoptPrinter, getopt, GetoptResult;
import std.path : absolutePath, buildPath, dirName, relativePath, setExtension, stripExtension;
import std.process : Config, environment, execute;
import std.stdio : stderr, writefln;
import std.string : indexOf, lineSplitter, strip;
import std.typecons : Tuple;

/// Repository root, from this file's location.
enum string root = dirName(dirName(__FILE_FULL_PATH__));

/// Subpackages in index order.
immutable string[] subpackages = ["core", "gl33", "sdl3"];

/// One documented module.
struct Module
{
    string name; /// Full name, `dentrite.widgets.button`.
    string file; /// Source path relative to the root.
    string sub; /// Subpackage holding it.
    string summary; /// First sentence of the module comment.
}

/// Builds the reference. Returns 0, or 1 on failure.
int main(string[] args)
{
    string outDir = "bin/apidoc";
    string dc = environment.get("DC", "dmd");
    GetoptResult help;
    try
    {
        help = getopt(args,
            "out", "Output directory, relative to the root. bin/apidoc by default.", &outDir,
            "dc", "Compiler, $DC or dmd by default.", &dc);
    }
    catch (Exception e)
    {
        stderr.writeln(e.msg);
        return 1;
    }
    if (help.helpWanted)
    {
        defaultGetoptPrinter("Builds the API reference into bin/apidoc/.", help.options);
        return 0;
    }

    // -op mirrors source paths under -Dd, so the compiler runs from the root on relative paths
    outDir = relativePath(absolutePath(outDir, root), root);
    string gen = buildPath(outDir, ".gen");
    string html = buildPath(gen, "html");
    if (exists(buildPath(root, gen)))
    {
        rmdirRecurse(buildPath(root, gen));
    }
    mkdirRecurse(buildPath(root, gen));

    Module[] modules = findModules();
    string nav = buildPath(gen, "nav.ddoc");
    string index = buildPath(gen, "index.dd");
    write(buildPath(root, nav), navMacro(modules));
    write(buildPath(root, index), indexPage(modules));

    string[] cmd = [dc, "-D", "-o-", "-op", "-Dd" ~ html];
    foreach (string sub; subpackages)
    {
        cmd ~= "-I" ~ buildPath(sub, "source");
    }
    cmd ~= [buildPath("tools", "apidoc.ddoc"), nav, index];
    foreach (ref const(Module) m; modules)
    {
        cmd ~= m.file;
    }
    Tuple!(int, "status", string, "output") r = execute(cmd, null, Config.none, size_t.max, root);
    if (r.status != 0)
    {
        stderr.writeln(r.output);
        return 1;
    }
    if (r.output.length > 0)
    {
        stderr.write(r.output);
    }

    foreach (ref const(Module) m; modules)
    {
        string page = readText(buildPath(root, html, setExtension(m.file, "html")));
        write(buildPath(root, outDir, m.name ~ ".html"), highlight(page));
    }
    rename(buildPath(root, html, setExtension(index, "html")), buildPath(root, outDir, "index.html"));
    copy(buildPath(root, "tools", "apidoc.css"), buildPath(root, outDir, "apidoc.css"));
    rmdirRecurse(buildPath(root, gen));
    writefln("%d modules in %s", modules.length, buildPath(outDir, "index.html"));
    return 0;
}

/// Documented modules of every subpackage, sorted by name within each.
Module[] findModules()
{
    Module[] all;
    foreach (string sub; subpackages)
    {
        string src = buildPath(root, sub, "source");
        Module[] found;
        foreach (string path; dirEntries(src, "*.d", SpanMode.depth))
        {
            string rel = relativePath(path, src);
            string name = stripExtension(rel).replace("/", ".").replace("\\", ".");
            if (name.startsWith("dentrite.c."))
            {
                continue;
            }
            if (name.split(".")[$ - 1] == "package")
            {
                name = name[0 .. $ - ".package".length];
            }
            found ~= Module(name, relativePath(path, root), sub, summary(readText(path)));
        }
        found.sort!((a, b) => a.name < b.name);
        all ~= found;
    }
    return all;
}

/// First sentence of the `///` comment above the module line in `text`, or "".
string summary(string text)
{
    string[] block;
    foreach (string line; lineSplitter(text))
    {
        string s = line.strip;
        if (s.startsWith("module "))
        {
            break;
        }
        if (s.startsWith("///"))
        {
            block ~= s[3 .. $].strip;
        }
        else
        {
            block = null;
        }
    }
    string para;
    foreach (string line; block)
    {
        if (line.length == 0)
        {
            break;
        }
        para ~= (para.length > 0 ? " " : "") ~ line;
    }
    ptrdiff_t end = para.indexOf(". ");
    return end >= 0 ? para[0 .. end + 1] : para;
}

/// Macro file defining `NAV`, the sidebar listing every module by subpackage.
string navMacro(const(Module)[] modules)
{
    Appender!string a = appender!string();
    a ~= "NAV =\n";
    foreach (string sub; subpackages)
    {
        a ~= format("<h3>%s</h3>\n<ul>\n", sub);
        foreach (ref const(Module) m; modules)
        {
            if (m.sub == sub)
            {
                a ~= format("<li><a href=\"%s.html\">%s</a></li>\n", m.name, m.name["dentrite.".length .. $]);
            }
        }
        a ~= "</ul>\n";
    }
    return a.data;
}

/// Index page: a table of modules and their summaries per subpackage.
string indexPage(const(Module)[] modules)
{
    Appender!string a = appender!string();
    a ~= "Ddoc\n";
    a ~= "Retained UI library in D. `dentrite:core` has no SDL or GL, `dentrite:gl33` is the OpenGL 3.3 renderer, "
        ~ "`dentrite:sdl3` the SDL3 window.\n\n";
    foreach (string sub; subpackages)
    {
        a ~= format("## dentrite:%s\n\n| Module | Summary |\n|---|---|\n", sub);
        foreach (ref const(Module) m; modules)
        {
            if (m.sub == sub)
            {
                a ~= format("| [%s](%s.html) | %s |\n", m.name, m.name, m.summary.replace("|", "\\|"));
            }
        }
        a ~= "\n";
    }
    a ~= "Macros:\nTITLE = dentrite API reference\nDDOC_BLANKLINE = $(LF)\n";
    return a.data;
}

/// D keywords, basic types included.
immutable bool[string] keywords;

/// Phobos and druntime aliases colored as types.
immutable bool[string] typeAliases;

shared static this()
{
    bool[string] k;
    foreach (string w; ["abstract", "alias", "align", "asm", "assert", "auto", "bool", "break", "byte", "case",
        "cast", "catch", "char", "class", "const", "continue", "dchar", "debug", "default", "delegate",
        "deprecated", "do", "double", "else", "enum", "export", "extern", "false", "final", "finally", "float",
        "for", "foreach", "foreach_reverse", "function", "goto", "if", "immutable", "import", "in", "inout",
        "int", "interface", "invariant", "is", "lazy", "long", "mixin", "module", "new", "nothrow", "null", "out",
        "override", "package", "pragma", "private", "protected", "public", "pure", "real", "ref", "return",
        "scope", "shared", "short", "static", "struct", "super", "switch", "synchronized", "template", "this",
        "throw", "true", "try", "typeid", "typeof", "ubyte", "uint", "ulong", "union", "unittest", "ushort",
        "version", "void", "wchar", "while", "with", "__gshared", "__traits"])
    {
        k[w] = true;
    }
    keywords = cast(immutable) k;
    bool[string] t;
    foreach (string w; ["string", "wstring", "dstring", "size_t", "ptrdiff_t"])
    {
        t[w] = true;
    }
    typeAliases = cast(immutable) t;
}

/// `page` with D syntax colored in declarations and code listings, which DDoc leaves plain or marks only
/// keywords, strings and comments in.
string highlight(string page)
{
    static immutable string[2][] regions = [
        [`<div class="decl"><code>`, `</code></div>`],
        [`<pre class="listing"><code`, `</code></pre>`],
    ];
    Appender!string a = appender!string();
    size_t i;
    while (i < page.length)
    {
        ptrdiff_t best = -1;
        size_t which;
        foreach (size_t r, ref const(string[2]) region; regions)
        {
            ptrdiff_t at = page[i .. $].indexOf(region[0]);
            if (at >= 0 && (best < 0 || at < best))
            {
                best = at;
                which = r;
            }
        }
        if (best < 0)
        {
            a ~= page[i .. $];
            break;
        }
        size_t open = i + best;
        // the listing opener may carry a class, so the body starts after its closing bracket
        size_t tagEnd = open + regions[which][0].length;
        size_t start = tagEnd + page[tagEnd - 1 .. $].indexOf('>');
        ptrdiff_t len = page[start .. $].indexOf(regions[which][1]);
        if (len < 0)
        {
            a ~= page[i .. $];
            break;
        }
        a ~= page[i .. start];
        a ~= colorize(page[start .. start + len]);
        i = start + len;
    }
    return a.data;
}

/// `code` with keywords, types, numbers and literals wrapped in spans. Text inside nested tags is kept, as DDoc
/// already marked it.
string colorize(string code)
{
    Appender!string a = appender!string();
    int depth;
    size_t i;
    while (i < code.length)
    {
        char c = code[i];
        size_t j = i + 1;
        if (c == '<')
        {
            while (j < code.length && code[j - 1] != '>')
            {
                ++j;
            }
            string tag = code[i .. j];
            if (tag.startsWith("</"))
            {
                --depth;
            }
            else if (tag.startsWith("<br") == false && tag[$ - 2] != '/')
            {
                ++depth;
            }
            a ~= tag;
        }
        else if (depth > 0)
        {
            a ~= c;
        }
        else if (c == '&')
        {
            while (j < code.length && code[j - 1] != ';')
            {
                ++j;
            }
            a ~= code[i .. j];
        }
        else if (isIdentStart(c) || (c == '@' && j < code.length && isIdentStart(code[j])))
        {
            while (j < code.length && isIdentChar(code[j]))
            {
                ++j;
            }
            string word = code[i .. j];
            if (c == '@' || word in keywords)
            {
                a ~= `<span class="keyword">` ~ word ~ `</span>`;
            }
            else if (word in typeAliases || (c >= 'A' && c <= 'Z'))
            {
                a ~= `<span class="type">` ~ word ~ `</span>`;
            }
            else
            {
                a ~= word;
            }
        }
        else if (c >= '0' && c <= '9')
        {
            while (j < code.length && (isIdentChar(code[j])
                || (code[j] == '.' && j + 1 < code.length && code[j + 1] >= '0' && code[j + 1] <= '9')))
            {
                ++j;
            }
            a ~= `<span class="number">` ~ code[i .. j] ~ `</span>`;
        }
        else if (c == '"' || c == '\'')
        {
            while (j < code.length && code[j] != c && code[j] != '<')
            {
                j += code[j] == '\\' ? 2 : 1;
            }
            if (j < code.length && code[j] == c)
            {
                a ~= `<span class="string_literal">` ~ code[i .. j + 1] ~ `</span>`;
                ++j;
            }
            else
            {
                a ~= c;
                j = i + 1;
            }
        }
        else
        {
            a ~= c;
        }
        i = j;
    }
    return a.data;
}

/// True if `c` can start a D identifier.
bool isIdentStart(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c >= 0x80;
}

/// True if `c` can continue a D identifier.
bool isIdentChar(char c)
{
    return isIdentStart(c) || (c >= '0' && c <= '9');
}
