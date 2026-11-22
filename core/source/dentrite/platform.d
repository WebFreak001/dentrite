/// What the host needs from a window system and a renderer, and the events a platform delivers.
///
/// A platform owns the window, its events, the clipboard, the cursor and presenting. A renderer draws a
/// `FrameMesh` into what the platform presents. Platforms translate their input to `Event`, with positions
/// in physical pixels and key codes as in `Key`.
module dentrite.platform;

import core.atomic : atomicLoad, atomicStore;
import core.time : Duration;
import dentrite.access : AccessRequest;
import dentrite.draw : FrameMesh;
import dentrite.geom;
import dentrite.node : CursorShape, PointerKind;
import dentrite.text : FontKind, GlyphAtlas;
import dentrite.theme : Theme;

/// Renderers a platform can set up.
enum RendererKind
{
    gl33,     /// OpenGL 3.3 core
    software, /// CPU rasterizer
}

/// Window settings, read by the platform and the host.
struct WindowOptions
{
    string title = "dentrite";   /// window title
    int width = 1280;            /// window width in logical pixels
    int height = 800;            /// window height in logical pixels
    float scale = 0;             /// display scale to use, 0 to take the display's own
    bool vsync = true;           /// wait for vertical blank
    double maxFps = 120;         /// frame rate cap, for when vsync does not limit it
    RendererKind renderer;       /// renderer drawing the frames
    string[FontKind.max + 1] fonts; /// font file for each `FontKind` slot
    string[] fallbackFonts;      /// files for characters the slot fonts lack, tried in order
    bool systemFallbacks = true; /// after `fallbackFonts`, try well-known system fonts, see `systemFallbackFonts`
    string themePath;            /// theme file, reloadable with Ctrl+R
    /// Validates every style the app reads, throws on errors. By default checks `LibraryStyles` only, so app
    /// sections fail it.
    void delegate(Theme) checkTheme;
    bool hidden;                 /// do not show, for screenshots
    bool cachePaint = true;      /// reuse unchanged layers, false repaints everything every frame for comparisons
    /// Exposes the UI to screen readers, see `dentrite.access`. The SDL3 platform loads AccessKit for it at run
    /// time and goes on without it if missing.
    bool accessibility;
}

/// Framebuffer size and display density, from `Platform.metrics`.
struct Metrics
{
    int pixelW;      /// framebuffer width in physical pixels
    int pixelH;      /// framebuffer height in physical pixels
    float scale = 1; /// display scale, physical pixels per logical pixel
}

/// What happened, for `Event`.
enum EventKind
{
    none,        /// nothing the host needs
    close,       /// the user asked to close the window or quit
    resized,     /// size or scale changed, `Platform.metrics` has the new values
    exposed,     /// contents lost, draw again
    pointerLeft, /// pointer left the window
    focusLost,   /// window lost keyboard focus
    pointer,     /// pointer moved or a button changed
    wheel,       /// wheel turned
    key,         /// key pressed
    text,        /// text typed
    compose,     /// text an input method has not committed yet, empty when it ends
    wake,        /// `wakeUi` from another thread
    call,        /// run `call` on the UI thread, such as a file dialog's handler
    access,      /// an assistive technology asks for `request`
}

/// Input or window event from a platform. A field doc starting with an event kind, such as `pointer:`, says which
/// kinds set it.
struct Event
{
    EventKind kind;      /// kind of event
    PointerKind pointer; /// `pointer`: move, down or up
    Point pos;           /// `pointer` and `wheel`: position in physical pixels
    ubyte button;        /// `pointer`: 1 left, 2 middle, 3 right
    ubyte clicks;        /// `pointer`: 2 for a double click
    ubyte mods;          /// `Mod` flags, combined with `|`
    float dx = 0;        /// `wheel`: notches, positive moves content left
    float dy = 0;        /// `wheel`: notches, positive moves content up
    uint key;            /// `key`: Key value or another key code
    bool repeat;         /// `key`: auto-repeat
    string text;         /// `text` and `compose`: UTF-8
    int start = -1;      /// `compose`: first code point the input method is converting, or the caret, -1 if unset
    int length = -1;     /// `compose`: code points it is converting, -1 or 0 for none
    void delegate() call; /// `call`: work for the UI thread
    AccessRequest request; /// `access`: what to do
}

/// What a file dialog asks for.
enum FileDialogKind
{
    open,     /// one existing file
    openMany, /// one or more existing files
    save,     /// a file name to write, existing or not
    folder,   /// one folder
}

/// File type offered by a file dialog: `FileFilter("Images", "png;jpg")`. `*` matches every file.
struct FileFilter
{
    string name;    /// filter name shown to the user
    string pattern; /// extensions without dots, separated by `;`
}

/// Platform with native file dialogs.
interface FileDialogs
{
    /// Shows a dialog of `kind` over the window, starting in `start` if not null. `done` gets the chosen paths
    /// later on the UI thread, through an event of kind `call`, and none if cancelled or failed.
    void fileDialog(FileDialogKind kind, const(FileFilter)[] filters, string start, void delegate(string[]) done);
}

/// Window system side of a host: window, events, clipboard, cursor, presenting.
interface Platform
{
    Metrics metrics();                        /// framebuffer size and display scale
    bool wait(ref Event e, Duration timeout); /// next event within `timeout`, no limit for `Duration.max`
    void present();                           /// shows what the renderer drew
    void setCursor(CursorShape shape);        /// pointer shape over the window
    void textInput(bool on);                  /// starts or stops text events, which drops any composition
    void textInputArea(Rect caret);           /// caret in physical pixels, where an input method shows candidates
    string clipboard();                       /// clipboard text, or null
    void setClipboard(string s);              /// sets the clipboard
    void close();                             /// closes the window and frees what the platform holds
}

/// Draws frames for a platform.
interface Renderer
{
    void render(FrameMesh mesh, GlyphAtlas atlas, Color clear); /// clears to `clear` and draws `mesh`
    ubyte[] readPixels();  /// last frame as RGBA8 rows, top row first
    string description();  /// renderer and driver, for logs
    void dispose();        /// frees what the renderer holds, before the platform closes
}

/// Wakes the UI loop from any thread. Does nothing while no platform is open.
void wakeUi() nothrow
{
    void function() nothrow w = atomicLoad(waker);
    if (w !is null)
    {
        w();
    }
}

/// Sets what `wakeUi` calls, null when the platform closes.
void setWaker(void function() nothrow w) nothrow
{
    atomicStore(waker, w);
}

/// Platform wake function, called by `wakeUi` from any thread.
private shared void function() nothrow waker;
