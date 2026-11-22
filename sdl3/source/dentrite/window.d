/// SDL3 window running a `Host`, drawn with GL 3.3 or in software.
module dentrite.window;

public import dentrite.host;
public import dentrite.platform;
import dentrite.sdl3 : SdlPlatform;
import std.stdio : stderr;

/// Host on an SDL3 window. `scope Window w = new Window(o)` closes it at scope exit.
final class Window : Host
{
    /// Opens the window with the renderer `o.renderer` names, loads fonts and the theme.
    this(WindowOptions o)
    {
        SdlPlatform p = new SdlPlatform(o);
        super(p, p.renderer, o);
        stderr.writeln("dentrite: ", renderer.description());
    }
}
