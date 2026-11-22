/// Headless host and input helpers shared by the guide's tests.
module guide.harness;

import dentrite.access : AccessNode, Role;
import dentrite.backend.software : SoftwareRenderer;
import dentrite.headless : HeadlessPlatform;
import dentrite.host : Host;
import dentrite.node;
import dentrite.platform : WindowOptions;
import dentrite.theme : Theme;
import guide.themes : GuideStyles;

/// Font files of the examples, relative to `guide/examples/`.
immutable string[3] guideFonts = ["../../fonts/Inter-Regular.otf", "../../fonts/Inter-SemiBold.otf",
    "../../fonts/JetBrainsMono-Regular.ttf"];

/// Headless host of `w` by `h` logical pixels, drawing in software, with the theme file `themePath` if given.
/// Close it when done.
Host testHost(int w = 400, int h = 300, string themePath = null)
{
    WindowOptions o;
    o.fonts = guideFonts;
    o.themePath = themePath;
    o.checkTheme = (Theme t) { t.check!GuideStyles(); };
    return new Host(new HeadlessPlatform(w, h), new SoftwareRenderer, o);
}

/// True if a node with `role` and `name` is shown, as a screen reader would see it after the last frame.
bool shows(Host h, Role role, string name)
{
    return h.find(role, name) !is null;
}
