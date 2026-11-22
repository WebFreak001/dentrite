/// SDL3 window running a `Host`, drawn with GL 3.3 or in software.
module dentrite.window;

public import dentrite.host;
public import dentrite.platform;
import dentrite.c.sdl : SDL_Window;
import dentrite.sdl3 : SdlPlatform;
import std.stdio : stderr;

/// Host on an SDL3 window. `scope Window w = new Window(o)` closes it at scope exit.
final class Window : Host
{
    private SdlPlatform sdl; /// platform behind `platform`

    /// Opens the window with the renderer `o.renderer` names, loads fonts and the theme.
    this(WindowOptions o)
    {
        sdl = new SdlPlatform(o);
        super(sdl, sdl.renderer, o);
        stderr.writeln("dentrite: ", renderer.description());
    }

    /// SDL window, for SDL calls the library does not wrap. Cast it for other SDL bindings.
    /// NOTE: title, visibility, minimum size and icon have `Host` setters, which keep the host in step.
    SDL_Window* sdlWindow()
    {
        return sdl.handle;
    }
}
