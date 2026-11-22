/// Chapter 8: theme files, style structs, variants and checking.
module guide.themes;

import dentrite.host : LibraryStyles;
import dentrite.theme;
import dentrite.widgets.button : ButtonStyle;
import guide.islands : ChartStyle;
import std.meta : AliasSeq;

/// Styles the guide's theme may set: the library's, the chart's, and a button variant of the app.
alias GuideStyles = AliasSeq!(LibraryStyles, ChartStyle, Variants!(ButtonStyle, "large"));

/// The theme file passes the check, and a variant starts from its base section.
unittest
{
    import std.file : readText;

    Theme t = new Theme(readText("themes/dark.theme"), "themes/dark.theme");
    t.check!GuideStyles();
    ChartStyle base = t.style!ChartStyle(null);
    ChartStyle alarm = t.style!ChartStyle("alarm");
    assert(base.width == 1.5 && alarm.width == 2.5);
    assert(alarm.background == base.background && alarm.line != base.line);
}

/// Mistakes name the file and line.
unittest
{
    /// Message of checking theme `text`, or null when it passes.
    string error(string text)
    {
        try
        {
            new Theme(text, "app.theme").check!GuideStyles();
        }
        catch (Exception e)
        {
            return e.msg;
        }
        return null;
    }

    assert(error("[chart]\nwidht = 2\n") == "app.theme(2): ChartStyle has no field widht");
    assert(error("[chart.warning]\nwidth = 2\n") == "app.theme(1): no style reads section [chart.warning]");
    assert(error("[button.large]\npadX = 18\n") is null, "declared with Variants");
}

/// A theme read at compile time fails the build on a mistake.
unittest
{
    enum string text = "[palette]\nred = #e5484d\n\n[chart]\nline = red\nwidth = 2\n";
    static assert(checkTheme!GuideStyles(text, "inline.theme"));
    enum ChartStyle c = loadStyle!ChartStyle(text, "inline.theme", null);
    static assert(c.width == 2 && c.line == Color(0xe5, 0x48, 0x4d, 0xff));
}
