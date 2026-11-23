/// SDL3 platform: window, events, clipboard and cursors, presenting frames drawn with GL 3.3 or in software.
module dentrite.sdl3;

import core.stdc.stdlib : free, malloc;
import core.stdc.string : strdup;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration;
import dentrite.access : AccessAdapter, AccessDemand, AccessUpdate;
import dentrite.accesskit : AccessKitAdapter;
import dentrite.backend.gl33 : GL33Renderer;
import dentrite.backend.software : SoftwareRenderer;
import dentrite.c.gl : GL_RENDERER, GL_VERSION, glGetString, loadGL;
import dentrite.c.sdl;
import dentrite.deadkeys : DeadKeys;
import dentrite.geom;
import dentrite.image : Image;
import dentrite.node : CursorShape, Mod, PointerKind;
import dentrite.platform;
import std.algorithm.comparison : max;
import std.exception : enforce;
import std.process : environment;
import std.stdio : stderr;
import std.string : fromStringz, toStringz;

/// SDL3 user event type that wakes the loop, set once SDL is up.
private __gshared uint wakeEvent;

/// Pushes the wake event, any thread.
private void wakeSdl() nothrow
{
    SDL_Event e;
    e.type = wakeEvent;
    SDL_PushEvent(&e);
}

/// SDL3 user event type carrying an AccessKit action request, set once SDL is up.
private __gshared uint accessEvent;

/// File dialog waiting for its answer. The SDL callback fills it on any thread, `wait` hands it to the UI.
private final class FileRequest
{
    void delegate(string[]) done;   /// app handler
    SDL_DialogFileFilter[] filters; /// kept alive until the answer
    const(char)* start;             /// kept alive until the answer
    char** paths;   /// answer copied with malloc, freed on the UI thread
    size_t count;   /// entries in `paths`
    bool answered;  /// set by the callback under `answerLock`
}

/// Guards `FileRequest.answered` and the answer fields.
private __gshared Mutex answerLock;

/// Copies the answer of a file dialog into its request and wakes the loop. Any thread, so no GC.
private extern (C) void fileAnswered(void* userdata, const(char*)* list, int filter) nothrow @nogc
{
    FileRequest r = cast(FileRequest) userdata;
    size_t n;
    while (list !is null && list[n] !is null)
    {
        ++n;
    }
    char** copy = n == 0 ? null : cast(char**) malloc(n * (char*).sizeof);
    foreach (size_t i; 0 .. n)
    {
        copy[i] = strdup(list[i]);
    }
    answerLock.lock_nothrow();
    r.paths = copy;
    r.count = n;
    r.answered = true;
    answerLock.unlock_nothrow();
    SDL_Event e;
    e.type = wakeEvent;
    SDL_PushEvent(&e);
}

/// SDL3 window with a GL 3.3 context or a software surface.
final class SdlPlatform : Platform, FileDialogs, AccessAdapter, WindowControl
{
    Renderer renderer;              /// renderer drawing into this window, created along with it
    /// Called with every SDL event on the UI thread, before the library handles it.
    void delegate(ref const SDL_Event) onSdlEvent;

    private SDL_Window* win;        /// SDL window
    private SDL_GLContext gl;       /// GL context, null in software
    private SoftwareRenderer soft;  /// software renderer, null with GL
    private int windowW;            /// width in window coordinates
    private int pixelW;             /// framebuffer width
    private SDL_Cursor*[CursorShape.max + 1] cursors; /// stock cursors, made on first use
    private bool closed;            /// `close` already ran
    private FileRequest[] requests; /// file dialogs not answered or not handed out yet
    private bool logInput;          /// DENTRITE_LOG_INPUT is set, so input events go to stderr
    private DeadKeys deadKeys;      /// dead key accents on Wayland, null elsewhere
    private bool textOn;            /// text input started
    private bool deadShown;         /// a dead key's accent is shown as composition
    private AccessKitAdapter access; /// screen reader bridge with `WindowOptions.accessibility`, else null
    private Event queued;           /// event `wait` hands out next, after one translated into two
    private bool hasQueued;         /// `queued` is waiting
    private float forced = 0;       /// `WindowOptions.scale`, 0 for the display's own

    /// Opens the window and sets up the renderer `o.renderer` names.
    this(WindowOptions o)
    {
        SDL_SetHint("SDL_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR", "0");
        // NOTE: without it XIM and IBus show nothing until text is committed, such as a dead key's accent.
        SDL_SetHint("SDL_IME_IMPLEMENTED_UI", "composition");
        // NOTE: else closing the window also sends a quit, which `Host.onCloseRequest` cannot cancel.
        SDL_SetHint("SDL_QUIT_ON_LAST_WINDOW_CLOSE", "0");
        enforce(SDL_Init(SDL_INIT_VIDEO), "SDL_Init: " ~ error());
        wakeEvent = SDL_RegisterEvents(2);
        accessEvent = wakeEvent + 1;
        logInput = environment.get("DENTRITE_LOG_INPUT").length > 0;
        if (logInput)
        {
            stderr.writefln("dentrite: SDL video driver %s", fromStringz(SDL_GetCurrentVideoDriver()));
        }
        if (answerLock is null)
        {
            answerLock = new Mutex;
        }
        bool useGL = o.renderer == RendererKind.gl33;
        if (useGL)
        {
            SDL_GL_SetAttribute(SDL_GLAttr.contextMajorVersion, 3);
            SDL_GL_SetAttribute(SDL_GLAttr.contextMinorVersion, 3);
            SDL_GL_SetAttribute(SDL_GLAttr.contextProfileMask, SDL_GL_CONTEXT_PROFILE_CORE);
            SDL_GL_SetAttribute(SDL_GLAttr.doubleBuffer, 1);
            SDL_GL_SetAttribute(SDL_GLAttr.depthSize, 24);
        }
        forced = o.scale;
        int w = toWindow(o.width);
        int h = toWindow(o.height);
        ulong flags = SDL_WINDOW_RESIZABLE | (useGL ? SDL_WINDOW_OPENGL : 0)
            | (forced > 0 ? 0 : SDL_WINDOW_HIGH_PIXEL_DENSITY) | (o.hidden ? SDL_WINDOW_HIDDEN : 0);
        win = SDL_CreateWindow(o.title.toStringz, w, h, flags);
        enforce(win !is null, "SDL_CreateWindow: " ~ error());
        if (useGL)
        {
            string why = startGL(o.vsync);
            if (why is null)
            {
                renderer = new GL33Renderer;
            }
            else
            {
                stderr.writefln("dentrite: %s, drawing in software", why);
                useGL = false;
                SDL_DestroyWindow(win);
                win = SDL_CreateWindow(o.title.toStringz, w, h, flags & ~SDL_WINDOW_OPENGL);
                enforce(win !is null, "SDL_CreateWindow: " ~ error());
            }
        }
        if (useGL == false)
        {
            SDL_SetWindowSurfaceVSync(win, o.vsync ? 1 : 0);
            soft = new SoftwareRenderer;
            renderer = soft;
        }
        setMinimumSize(o.minWidth, o.minHeight);
        readSizes();
        setWaker(&wakeSdl);
        if (fromStringz(SDL_GetCurrentVideoDriver()) == "wayland")
        {
            deadKeys = DeadKeys.open(SDL_GetPointerProperty(SDL_GetWindowProperties(win),
                "SDL.window.wayland.display", null));
        }
        if (o.accessibility)
        {
            string path = environment.get("DENTRITE_ACCESSKIT");
            access = AccessKitAdapter.open(win, accessEvent, path.length > 0 ? path.toStringz : null);
            if (access is null)
            {
                stderr.writeln("dentrite: accessibility off, AccessKit not found. DENTRITE_ACCESSKIT names its file");
            }
        }
        if (logInput)
        {
            stderr.writefln("dentrite: dead key accents %s", deadKeys is null ? "off" : "on");
        }
    }

    /// Makes a GL 3.3 context for the window and loads GL. Null on success, else why not, with no context left.
    /// NOTE: without a GPU driver Windows gives an OpenGL 1.1 context, and SDL returns it in place of 3.3.
    private string startGL(bool vsync)
    {
        gl = SDL_GL_CreateContext(win);
        if (gl is null)
        {
            return "no OpenGL 3.3 context: " ~ error();
        }
        SDL_GL_MakeCurrent(win, gl);
        string why;
        glGetString = cast(typeof(glGetString)) SDL_GL_GetProcAddress("glGetString");
        const(char)* ver = glGetString is null ? null : glGetString(GL_VERSION);
        string v = ver is null ? null : fromStringz(ver).idup;
        if (v.length < 3 || v[0] < '3' || (v[0] == '3' && v[2] < '3'))
        {
            const(char)* by = v is null ? null : glGetString(GL_RENDERER);
            why = "OpenGL 3.3 needed, the driver gives " ~ (v is null ? "none" : v ~ " from " ~ fromStringz(by).idup);
        }
        else
        {
            string missing = loadGL((const(char)* name) => cast(void*) SDL_GL_GetProcAddress(name));
            why = missing is null ? null : "GL entry point missing: " ~ missing;
        }
        if (why !is null)
        {
            SDL_GL_DestroyContext(gl);
            gl = null;
            return why;
        }
        SDL_GL_SetSwapInterval(vsync ? 1 : 0);
        return null;
    }

    /// What the next accessibility update must hold, none without AccessKit.
    AccessDemand demand()
    {
        return access is null ? AccessDemand.none : access.demand();
    }

    /// Sends an accessibility update to AccessKit.
    void update(ref const AccessUpdate u, float scale)
    {
        if (access !is null)
        {
            access.update(u, scale);
        }
    }

    /// Last SDL error.
    private static string error()
    {
        return fromStringz(SDL_GetError()).idup;
    }

    /// Caches the sizes that map window coordinates to pixels.
    private void readSizes()
    {
        int unused;
        SDL_GetWindowSize(win, &windowW, &unused);
        SDL_GetWindowSizeInPixels(win, &pixelW, &unused);
    }

    /// Window coordinates to physical pixels.
    private Point toPixels(float x, float y)
    {
        float k = windowW > 0 ? cast(float) pixelW / windowW : 1;
        return Point(x * k, y * k);
    }

    /// Framebuffer size and display scale.
    Metrics metrics()
    {
        Metrics m;
        SDL_GetWindowSizeInPixels(win, &m.pixelW, &m.pixelH);
        m.scale = SDL_GetWindowDisplayScale(win);
        return m;
    }

    /// Next SDL event within `timeout`, translated. Kind `none` for events the host does not need.
    /// SDL waits in whole milliseconds, so the last part of a wait sleeps without seeing events.
    bool wait(ref Event e, Duration timeout)
    {
        int ms = timeout == Duration.max ? -1 : cast(int) timeout.total!"msecs";
        if (ms == 0 && timeout > Duration.zero)
        {
            Thread.sleep(timeout);
        }
        if (hasQueued)
        {
            e = queued;
            hasQueued = false;
            return true;
        }
        if (takeAnswer(e))
        {
            return true;
        }
        SDL_Event s;
        if ((ms == 0 ? SDL_PollEvent(&s) : SDL_WaitEventTimeout(&s, ms)) == false)
        {
            return false;
        }
        if (onSdlEvent !is null)
        {
            onSdlEvent(s);
        }
        e = translate(s);
        if (e.kind == EventKind.wake)
        {
            takeAnswer(e);
        }
        return true;
    }

    /// Shows an SDL file dialog over the window. The answer comes back from `wait` as a `call` event.
    void fileDialog(FileDialogKind kind, const(FileFilter)[] filters, string start, void delegate(string[]) done)
    {
        FileRequest r = new FileRequest;
        r.done = done;
        foreach (ref const FileFilter f; filters)
        {
            r.filters ~= SDL_DialogFileFilter(f.name.toStringz, f.pattern.toStringz);
        }
        r.start = start is null ? null : start.toStringz;
        requests ~= r;
        void* u = cast(void*) r;
        const(SDL_DialogFileFilter)* fs = r.filters.length == 0 ? null : r.filters.ptr;
        int n = cast(int) r.filters.length;
        final switch (kind)
        {
        case FileDialogKind.open:
        case FileDialogKind.openMany:
            SDL_ShowOpenFileDialog(&fileAnswered, u, win, fs, n, r.start, kind == FileDialogKind.openMany);
            break;
        case FileDialogKind.save:
            SDL_ShowSaveFileDialog(&fileAnswered, u, win, fs, n, r.start);
            break;
        case FileDialogKind.folder:
            SDL_ShowOpenFolderDialog(&fileAnswered, u, win, r.start, false);
            break;
        }
    }

    /// Turns the first answered file dialog into a `call` event and frees its copy. False if none is answered.
    private bool takeAnswer(ref Event e)
    {
        FileRequest found;
        answerLock.lock_nothrow();
        foreach (size_t i, FileRequest r; requests)
        {
            if (r.answered)
            {
                found = r;
                requests = requests[0 .. i] ~ requests[i + 1 .. $];
                break;
            }
        }
        answerLock.unlock_nothrow();
        if (found is null)
        {
            return false;
        }
        string[] paths;
        foreach (size_t i; 0 .. found.count)
        {
            paths ~= fromStringz(found.paths[i]).idup;
            free(found.paths[i]);
        }
        free(found.paths);
        void delegate(string[]) done = found.done;
        e = Event.init;
        e.kind = EventKind.call;
        e.call = () { done(paths); };
        return true;
    }

    /// Event for SDL event `s`.
    private Event translate(ref SDL_Event s)
    {
        Event e;
        if (logInput)
        {
            logEvent(s);
        }
        switch (s.type)
        {
        case SDL_EventType.quit:
            e.kind = EventKind.quit;
            break;
        case SDL_EventType.windowCloseRequested:
            e.kind = EventKind.close;
            break;
        case SDL_EventType.windowMoved:
        case SDL_EventType.windowShown:
            if (access !is null)
            {
                access.windowMoved(win);
            }
            break;
        case SDL_EventType.windowFocusGained:
            if (access !is null)
            {
                access.windowFocus(true);
            }
            break;
        case SDL_EventType.windowResized:
        case SDL_EventType.windowPixelSizeChanged:
        case SDL_EventType.windowDisplayScaleChanged:
            readSizes();
            e.kind = EventKind.resized;
            if (access !is null)
            {
                access.windowMoved(win);
            }
            break;
        case SDL_EventType.windowExposed:
            e.kind = EventKind.exposed;
            break;
        case SDL_EventType.windowMouseLeave:
            e.kind = EventKind.pointerLeft;
            break;
        case SDL_EventType.windowFocusLost:
            e.kind = EventKind.focusLost;
            deadShown = false;
            if (access !is null)
            {
                access.windowFocus(false);
            }
            break;
        case SDL_EventType.mouseMotion:
            e.kind = EventKind.pointer;
            e.pointer = PointerKind.move;
            e.pos = toPixels(s.motion.x, s.motion.y);
            break;
        case SDL_EventType.mouseButtonDown:
        case SDL_EventType.mouseButtonUp:
            e.kind = EventKind.pointer;
            e.pointer = s.type == SDL_EventType.mouseButtonDown ? PointerKind.down : PointerKind.up;
            e.pos = toPixels(s.button.x, s.button.y);
            e.button = s.button.button;
            e.clicks = s.button.clicks;
            e.mods = modsOf(SDL_GetModState());
            break;
        case SDL_EventType.mouseWheel:
            float dir = s.wheel.direction == 1 ? -1 : 1;
            e.kind = EventKind.wheel;
            e.pos = toPixels(s.wheel.mouseX, s.wheel.mouseY);
            e.dx = s.wheel.x * dir;
            e.dy = -s.wheel.y * dir;
            e.mods = modsOf(SDL_GetModState());
            break;
        case SDL_EventType.keyDown:
            e.kind = EventKind.key;
            e.key = s.key.key;
            e.mods = modsOf(s.key.mod);
            e.repeat = s.key.repeat;
            deadKey(s.key, e);
            break;
        case SDL_EventType.textEditing:
            if (deadShown && *s.edit.text == 0)
            {
                break; // the compositor ending a composition it never showed, which would hide the accent
            }
            deadShown = false;
            e.kind = EventKind.compose;
            e.text = fromStringz(s.edit.text).idup;
            e.start = s.edit.start;
            e.length = s.edit.length;
            break;
        case SDL_EventType.textInput:
            deadShown = false;
            e.kind = EventKind.text;
            e.text = fromStringz(s.text.text).idup;
            break;
        default:
            if (s.type == wakeEvent)
            {
                e.kind = EventKind.wake;
            }
            else if (s.type == accessEvent)
            {
                e.kind = EventKind.access;
                e.request = AccessKitAdapter.request(s);
            }
            break;
        }
        return e;
    }

    /// Writes key, text and composition events to stderr.
    private static void logEvent(ref SDL_Event s)
    {
        switch (s.type)
        {
        case SDL_EventType.keyDown:
        case SDL_EventType.keyUp:
            stderr.writefln("dentrite: key %s scancode %d key 0x%x raw %d mods 0x%x",
                s.type == SDL_EventType.keyDown ? "down" : "up", s.key.scancode, s.key.key, s.key.raw, s.key.mod);
            break;
        case SDL_EventType.textEditing:
            stderr.writefln("dentrite: compose \"%s\" start %d length %d", fromStringz(s.edit.text),
                s.edit.start, s.edit.length);
            break;
        case SDL_EventType.textInput:
            stderr.writefln("dentrite: text \"%s\"", fromStringz(s.text.text));
            break;
        default:
            break;
        }
    }

    /// Turns a dead key into composition showing its accent, and clears that ahead of the next key, which
    /// commits it. Backspace and Escape only cancel it.
    private void deadKey(ref const SDL_KeyboardEvent k, ref Event e)
    {
        bool modifier = (k.scancode >= 224 && k.scancode <= 231) || k.scancode == 57 || k.scancode == 257;
        if (deadKeys is null || textOn == false || modifier)
        {
            return;
        }
        string accent = deadKeys.accent(k.raw);
        if (accent is null && deadShown == false)
        {
            return;
        }
        bool cancel = k.scancode == 42 || k.scancode == 41;
        if (accent is null && cancel == false)
        {
            queued = e;
            hasQueued = true;
        }
        deadShown = accent !is null;
        e = Event.init;
        e.kind = EventKind.compose;
        e.text = accent is null ? "" : accent;
    }

    /// Mod bits from SDL's modifier bits.
    private static ubyte modsOf(ushort m)
    {
        return cast(ubyte)(((m & SDL_KMOD_SHIFT) ? Mod.shift : 0) | ((m & SDL_KMOD_CTRL) ? Mod.ctrl : 0)
            | ((m & SDL_KMOD_ALT) ? Mod.alt : 0) | ((m & SDL_KMOD_GUI) ? Mod.gui : 0));
    }

    /// Swaps GL buffers, or copies the software frame to the window surface.
    void present()
    {
        if (gl !is null)
        {
            SDL_GL_SwapWindow(win);
            return;
        }
        SDL_Surface* dst = SDL_GetWindowSurface(win);
        if (dst is null || soft.pixels.length == 0)
        {
            return;
        }
        SDL_Surface* src = SDL_CreateSurfaceFrom(soft.width, soft.height, SDL_PIXELFORMAT_ABGR8888,
            soft.pixels.ptr, soft.width * 4);
        if (src is null)
        {
            return;
        }
        SDL_BlitSurface(src, null, dst, null);
        SDL_DestroySurface(src);
        SDL_UpdateWindowSurface(win);
    }

    /// Shows the stock cursor for `shape`.
    void setCursor(CursorShape shape)
    {
        if (cursors[shape] is null)
        {
            static immutable SDL_SystemCursor[CursorShape.max + 1] map = [SDL_SystemCursor.default_,
                SDL_SystemCursor.text, SDL_SystemCursor.pointer, SDL_SystemCursor.ewResize,
                SDL_SystemCursor.nsResize, SDL_SystemCursor.nwseResize, SDL_SystemCursor.neswResize,
                SDL_SystemCursor.move];
            cursors[shape] = SDL_CreateSystemCursor(map[shape]);
        }
        SDL_SetCursor(cursors[shape]);
    }

    /// SDL window, for SDL calls the library does not wrap.
    SDL_Window* handle()
    {
        return win;
    }

    /// Logical pixels `n` in window coordinates, as the window size is given at creation.
    private int toWindow(int n)
    {
        return forced > 0 ? cast(int)(n * forced) : n;
    }

    /// Sets the title bar text.
    void setTitle(string title)
    {
        SDL_SetWindowTitle(win, title.toStringz);
    }

    /// Shows or hides the window.
    void setVisible(bool on)
    {
        if (on)
        {
            SDL_ShowWindow(win);
        }
        else
        {
            SDL_HideWindow(win);
        }
    }

    /// True unless hidden.
    bool visible()
    {
        return (SDL_GetWindowFlags(win) & SDL_WINDOW_HIDDEN) == 0;
    }

    /// Sets the smallest size the user can resize to, in logical pixels, 0 for no limit.
    void setMinimumSize(int w, int h)
    {
        SDL_SetWindowMinimumSize(win, toWindow(max(0, w)), toWindow(max(0, h)));
    }

    /// Sets the window icon from `img`, which SDL copies.
    void setIcon(Image img)
    {
        ubyte[] px = img.straight();
        SDL_Surface* s = SDL_CreateSurfaceFrom(img.width, img.height, SDL_PIXELFORMAT_ABGR8888, px.ptr,
            img.width * 4);
        if (s is null)
        {
            return;
        }
        SDL_SetWindowIcon(win, s);
        SDL_DestroySurface(s);
    }

    /// Starts or stops SDL text events.
    void textInput(bool on)
    {
        textOn = on;
        deadShown = false;
        if (on)
        {
            SDL_StartTextInput(win);
        }
        else
        {
            SDL_StopTextInput(win);
        }
    }

    /// Tells the input method where the caret is, given in physical pixels.
    void textInputArea(Rect caret)
    {
        float k = pixelW > 0 ? cast(float) windowW / pixelW : 1;
        SDL_Rect r = SDL_Rect(cast(int)(caret.x * k), cast(int)(caret.y * k), max(1, cast(int)(caret.w * k)),
            max(1, cast(int)(caret.h * k)));
        SDL_SetTextInputArea(win, &r, 0);
    }

    /// Clipboard text.
    string clipboard()
    {
        char* c = SDL_GetClipboardText();
        if (c is null)
        {
            return null;
        }
        string s = fromStringz(c).idup;
        SDL_free(c);
        return s;
    }

    /// Sets the clipboard.
    void setClipboard(string s)
    {
        SDL_SetClipboardText(s.toStringz);
    }

    /// Destroys the context and window and quits SDL. Safe to call twice.
    void close()
    {
        if (closed)
        {
            return;
        }
        closed = true;
        setWaker(null);
        if (access !is null)
        {
            access.close();
            access = null;
        }
        if (deadKeys !is null)
        {
            deadKeys.close();
            deadKeys = null;
        }
        if (gl !is null)
        {
            SDL_GL_DestroyContext(gl);
        }
        SDL_DestroyWindow(win);
        SDL_Quit();
    }
}
