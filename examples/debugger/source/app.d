/// Debugger-shaped example: retained panels on signals, island views, a raw GL view and a fake
/// target thread, in one SDL3 window.
module app;

import core.time : MonoTime;
import debugger.backend;
import debugger.cube;
import debugger.model;
import debugger.panels;
import debugger.views;
import dentrite.backend.gl33 : GL33Renderer;
import dentrite.containers;
import dentrite.dock;
import dentrite.immediate : Ui;
import dentrite.island;
import dentrite.node;
import dentrite.script : scriptSteps;
import dentrite.signals;
import dentrite.text : FontKind;
import dentrite.theme : Theme;
import dentrite.window;
import std.conv : to;
import std.format : format;
import std.getopt : defaultGetoptPrinter, getopt, GetoptResult;
import std.stdio : stderr, writeln;
import std.string : split;

/// Layout file of interactive runs, in the working directory.
enum string layoutFile = "layout.json";

/// Default layout: breakpoints over registers on the left, the views over the console on the right.
DockSpace defaultLayout()
{
    DockSpace space = new DockSpace(DockNode.split(false,
        DockNode.split(true, DockNode.stack("breakpoints"), DockNode.stack("registers")),
        DockNode.split(true, DockNode.stack("disassembly", "memory", "viewport"), DockNode.stack("console"))));
    space.root.shares = [0.9f, 1.6f];
    space.root.children[0].shares = [1.3f, 1];
    space.root.children[1].shares = [1.8f, 1];
    return space;
}

/// Layout saved in `path`, or the default when it is missing, malformed or holds other panes.
DockSpace loadLayout(string path)
{
    import std.algorithm.sorting : sort;
    import std.file : exists, readText;
    import std.json : parseJSON;

    if (exists(path) == false)
    {
        return defaultLayout();
    }
    try
    {
        DockSpace saved = DockSpace.restore(parseJSON(readText(path)));
        if (sort(saved.paneIds).release == sort(defaultLayout().paneIds).release)
        {
            return saved;
        }
        stderr.writeln(path, ": other panes than this build has, using the default layout");
    }
    catch (Exception e)
    {
        stderr.writeln(path, ": ", e.msg, ", using the default layout");
    }
    return defaultLayout();
}

/// Debugger window contents in `w`, with the dock view laid out by `space` in `dock`.
Node debuggerUi(Window w, Session s, Backend be, Cube cube, Signal!string statusLeft, Signal!string statusRight,
    DockSpace space, out DockView dock)
{
    DebugCommands c = debugCommands(s, be);
    Node[string] panes = [
        "breakpoints": breakpointsPanel(s),
        "registers": registersPanel(s),
        "disassembly": island((Ui ui) { disassembly(ui, s); }),
        "memory": island((Ui ui) { memoryView(ui, s); }),
        "viewport": new RawView(&cube.draw, true),
        "console": island((Ui ui) { console(ui, s); }),
    ];
    string[string] titles = ["breakpoints": "Breakpoints", "registers": "Registers", "disassembly": "Disassembly",
        "memory": "Memory", "viewport": "Viewport", "console": "Console"];
    DockView view = new DockView(space, panes, titles);
    dock = view;
    return column()(
        menus(c, () { w.running = false; }, &w.reloadTheme, () { view.setSpace(defaultLayout()); }),
        toolbar(s, c),
        expanded(view),
        statusBar(statusLeft, statusRight),
    );
}

/// Opens the window, starts the target and runs until closed.
int main(string[] args)
{
    float scale = 0;
    string size = "1280x800";
    string shot;
    int frames = 3;
    string script;
    bool noTarget;
    bool noVsync;
    bool noCache;
    RendererKind renderer;
    bool paused;
    double duration = 0;
    string layout;
    GetoptResult help = getopt(args,
        "scale", "Forced scale, such as 1.5. Default: the display's.", &scale,
        "size", "Logical window size, WxH.", &size,
        "shot", "Write a PNG after --frames frames, then exit.", &shot,
        "frames", "Frames before --shot.", &frames,
        "script", "Scripted input before --shot, steps separated by ;: " ~ scriptSteps, &script,
        "no-target", "Do not start the fake target thread.", &noTarget,
        "no-vsync", "Do not wait for vertical blank.", &noVsync,
        "no-cache", "Repaint every layer every frame, to compare.", &noCache,
        "renderer", "gl33 or software. The viewport stays empty in software.", &renderer,
        "paused", "Start with the target paused.", &paused,
        "duration", "Run the real loop this many seconds, then print frame counts and exit.", &duration,
        "layout", "Dock layout file, read at start and written on quit. Default: " ~ layoutFile
            ~ ", none with --shot or --duration.", &layout);
    if (help.helpWanted)
    {
        defaultGetoptPrinter("dentrite debugger example", help.options);
        return 0;
    }
    string[] wh = size.split("x");
    WindowOptions o;
    o.title = "dentrite debugger example";
    o.width = wh[0].to!int;
    o.height = wh[1].to!int;
    o.scale = scale;
    o.vsync = noVsync == false;
    o.cachePaint = noCache == false;
    o.renderer = renderer;
    o.fonts = ["../../fonts/Inter-Regular.otf", "../../fonts/Inter-SemiBold.otf",
        "../../fonts/JetBrainsMono-Regular.ttf"];
    o.themePath = "themes/dark.theme";
    o.checkTheme = (Theme t) { t.check!(LibraryStyles, CodeStyle)(); };
    scope Window w = new Window(o);

    Session s = new Session;
    Backend be = new Backend(s.program);
    Cube cube = new Cube;
    Signal!string statusLeft = signal("Ready");
    Signal!string statusRight = signal("");
    if (layout.length == 0 && shot.length == 0 && duration == 0)
    {
        layout = layoutFile;
    }
    DockView dock;
    scope Scope root = effectScope(() {
        w.setRoot(debuggerUi(w, s, be, cube, statusLeft, statusRight,
            layout.length > 0 ? loadLayout(layout) : defaultLayout(), dock));
        effect(() {
            Breakpoint[] all = s.breakpoints.get;
            foreach (Breakpoint b; all)
            {
                b.enabled.get;
            }
            be.arm(all);
        });
    });

    w.beforeFrame ~= () {
        be.drain(s);
        FrameStats st = w.stats;
        batch(() {
            statusLeft.set(format("%d breakpoints, %,d log lines", s.breakpoints.peek.length, s.log.length));
            statusRight.set(format("frame %.2f ms: layout %.2f, islands %.2f, paint %.2f, tess %.2f, compose %.2f, "
                ~ "render %.2f  |  layers %d of %d, %,d vertices, %d batches  |  %.0f%%",
                ms(st.total), ms(st.layout), ms(st.islands), ms(st.paint), ms(st.tessellate), ms(st.compose),
                ms(st.render), st.layersRecorded, st.layersRecorded + st.layersReused, st.vertices, st.batches,
                w.pixelScale * 100));
        });
    };
    if (paused)
    {
        s.running.set(false);
        be.setRunning(false);
    }
    if (noTarget == false)
    {
        be.start();
    }
    scope (exit)
    {
        be.stop();
    }
    if (shot.length > 0)
    {
        try
        {
            runScripted(w, script, frames, shot);
        }
        catch (Exception e)
        {
            stderr.writeln(e.msg);
            return 1;
        }
        if (layout.length > 0)
        {
            saveLayout(dock.space, layout);
        }
        return 0;
    }
    if (duration > 0)
    {
        timedRun(w, duration);
        return 0;
    }
    w.run();
    saveLayout(dock.space, layout);
    return 0;
}

/// Writes `space` to `path`, reporting failure.
void saveLayout(DockSpace space, string path)
{
    import std.file : write;

    try
    {
        write(path, space.save().toPrettyString);
    }
    catch (Exception e)
    {
        stderr.writeln(path, ": ", e.msg);
    }
}

/// Set by the timer thread of `timedRun` when time is up.
private shared bool timeUp;

/// Runs the real loop for `seconds`, then prints how many frames it drew.
void timedRun(Window w, double seconds)
{
    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;
    import core.time : usecs;

    Thread timer = new Thread(() {
        Thread.sleep(usecs(cast(long)(seconds * 1e6)));
        atomicStore(timeUp, true);
        wakeUi();
    });
    timer.isDaemon = true;
    timer.start();
    w.beforeFrame ~= () {
        if (atomicLoad(timeUp))
        {
            w.running = false;
        }
    };
    ulong before = w.stats.frames;
    MonoTime t0 = MonoTime.currTime;
    w.run();
    double elapsed = (MonoTime.currTime - t0).total!"usecs" / 1e6;
    ulong n = w.stats.frames - before;
    writeln(format("%d frames in %.1f s, %.1f per second", n, elapsed, n / elapsed));
}

/// Milliseconds of `d`.
double ms(Duration d)
{
    return d.total!"usecs" / 1000.0;
}

/// Renders `frames` frames with `script` input spread over them, then writes `shot`.
void runScripted(Window w, string script, int frames, string shot)
{
    import core.thread : Thread;
    import core.time : msecs;
    import dentrite.script : runScript;

    runScript(w, script, (string step, MonoTime began, MonoTime handled) {
        writeln(format("%-24s %6.2f ms: input and effects %.2f, layout %.2f", step, ms(MonoTime.currTime - began),
            ms(handled - began), ms(w.stats.layout)));
    });
    FrameStats sum;
    foreach (int i; 0 .. frames)
    {
        w.requestFrame();
        w.frame();
        FrameStats f = w.stats;
        sum.total += f.total;
        sum.layout += f.layout;
        sum.islands += f.islands;
        sum.paint += f.paint;
        sum.tessellate += f.tessellate;
        sum.compose += f.compose;
        sum.render += f.render;
        sum.layersRecorded += f.layersRecorded;
        Thread.sleep(16.msecs);
    }
    if (frames > 0)
    {
        writeln(format("mean of %d frames: %.2f ms, layout %.2f, islands %.2f, paint %.2f, tess %.2f, compose %.2f, "
            ~ "render %.2f, layers recorded %.1f", frames, ms(sum.total) / frames, ms(sum.layout) / frames,
            ms(sum.islands) / frames, ms(sum.paint) / frames, ms(sum.tessellate) / frames, ms(sum.compose) / frames,
            ms(sum.render) / frames, cast(double) sum.layersRecorded / frames));
    }
    w.screenshotPath = shot;
    w.requestFrame();
    w.frame();
    FrameStats st = w.stats;
    writeln(format("frame %.2f ms: layout %.2f, islands %.2f, paint %.2f, tess %.2f, compose %.2f, render %.2f, "
        ~ "layers %d of %d, %d cmds, %d vertices, %d batches, %d KB of meshes", ms(st.total), ms(st.layout),
        ms(st.islands), ms(st.paint), ms(st.tessellate), ms(st.compose), ms(st.render), st.layersRecorded,
        st.layersRecorded + st.layersReused, st.commands, st.vertices, st.batches, st.meshBytes / 1024));
    if (GL33Renderer gl = cast(GL33Renderer) w.renderer)
    {
        writeln(format("GL buffers: %d KB", gl.bufferBytes / 1024));
    }
}

import core.time : Duration;
