/// Widget gallery: every dentrite widget in its variants and states, one page each.
module app;

import dentrite.script : runScript, scriptSteps, settle;
import dentrite.signals;
import dentrite.theme : Theme;
import dentrite.window;
import gallery.pages;
import gallery.shell;
import std.conv : to;
import std.getopt : defaultGetoptPrinter, getopt, GetoptResult;
import std.stdio : stderr, writeln;
import std.string : join, split, toLower;

/// Opens the window on the chosen page and runs until closed, or writes screenshots.
int main(string[] args)
{
    import std.algorithm.searching : countUntil;
    import std.file : mkdirRecurse;
    import std.path : buildPath;

    float scale = 0;
    string size = "1100x760";
    string theme = "themes/dark.theme";
    string page;
    string shot;
    string shots;
    string script;
    RendererKind renderer;
    bool access;
    GetoptResult help = getopt(args,
        "scale", "Forced scale, such as 1.5. Default: the display's.", &scale,
        "size", "Logical window size, WxH.", &size,
        "theme", "Theme file.", &theme,
        "page", "Page to open, by name or file name, such as check-boxes.", &page,
        "shot", "Write a PNG after --script, then exit.", &shot,
        "shots", "Write one PNG per page into this directory, then exit.", &shots,
        "script", "Scripted input before --shot, steps separated by ;: " ~ scriptSteps, &script,
        "renderer", "gl33 or software.", &renderer,
        "accessibility", "Expose the UI to screen readers through AccessKit, see DENTRITE_ACCESSKIT.", &access);
    if (help.helpWanted)
    {
        defaultGetoptPrinter("dentrite widget gallery", help.options);
        return 0;
    }
    string[] wh = size.split("x");
    WindowOptions o;
    o.title = "dentrite widget gallery";
    o.width = wh[0].to!int;
    o.height = wh[1].to!int;
    o.scale = scale;
    o.renderer = renderer;
    o.accessibility = access;
    o.fonts = ["../../fonts/Inter-Regular.otf", "../../fonts/Inter-SemiBold.otf",
        "../../fonts/JetBrainsMono-Regular.ttf"];
    o.themePath = theme;
    o.checkTheme = (Theme t) { t.check!GalleryStyles(); };
    
    scope Window w = new Window(o);
    Gallery g = new Gallery(w);
    Page[] ps = pages(g);
    Signal!size_t current = signal(size_t(0));
    if (page.length > 0)
    {
        ptrdiff_t at = countUntil!((Page p) => p.name.toLower == page.toLower || fileName(p.name) == page)(ps);
        if (at < 0)
        {
            string[] names;
            foreach (Page p; ps)
            {
                names ~= fileName(p.name);
            }
            stderr.writeln("unknown page ", page, ", expected one of: ", names.join(" "));
            return 1;
        }
        current.set(at);
    }
    scope Scope root = effectScope(() { w.setRoot(galleryUi(w, g, ps, current)); });

    if (shots.length > 0)
    {
        mkdirRecurse(shots);
        foreach (size_t i, Page p; ps)
        {
            current.set(i);
            settle(w, 3);
            w.screenshotPath = buildPath(shots, fileName(p.name) ~ ".png");
            writeln(w.screenshotPath);
            w.requestFrame();
            w.frame();
        }
        return 0;
    }
    if (shot.length > 0)
    {
        try
        {
            runScript(w, script);
        }
        catch (Exception e)
        {
            stderr.writeln(e.msg);
            return 1;
        }
        settle(w, 2);
        w.screenshotPath = shot;
        w.requestFrame();
        w.frame();
        return 0;
    }
    w.run();
    return 0;
}

