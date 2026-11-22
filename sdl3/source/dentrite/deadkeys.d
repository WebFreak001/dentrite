/// Accents of dead keys on Wayland, so a text box can show one until the next key commits it. Without an input
/// method the compositor sends no composition for them, and SDL's key event has no character, so a second
/// keyboard on SDL's connection reads the keymap and modifiers to find the accent.
/// NOTE: X11 without an input method sends no event at all for a dead key, so it has nothing like this.
module dentrite.deadkeys;

version (Posix)
{
    import core.sys.posix.sys.mman : MAP_FAILED, MAP_PRIVATE, PROT_READ, mmap, munmap;
    import core.sys.posix.unistd : close;
}
import dentrite.c.wayland;
import std.string : fromStringz;

/// Spacing accents for keysyms `dead_grave` (0xfe50) to `dead_semivoiced_sound`, in keysym order.
private immutable string[] accents = [
    "`", "´", "^", "~", "¯", "˘", "˙", "¨", "˚", "˝", "ˇ", "¸", "˛", "ͺ", "゛", "゜",
];

/// Keyboard on SDL's Wayland connection, on an event queue of its own so SDL never sees its events.
final class DeadKeys
{
    private wl_display* display;  /// SDL's connection
    private wl_event_queue* queue; /// queue for the objects below
    private wl_proxy* registry;   /// globals
    private wl_proxy* seat;       /// first seat
    private wl_proxy* keyboard;   /// its keyboard
    private xkb_context* context; /// xkb library state
    private xkb_keymap* keymap;   /// keymap the compositor sent last
    private xkb_state* state;     /// modifiers and layout as the compositor sent them

    /// Reader on `display`, or null when the libraries or a seat are missing. A keyboard may come later.
    static DeadKeys open(void* display)
    {
        if (display is null || loadWayland() == false)
        {
            return null;
        }
        DeadKeys d = new DeadKeys;
        d.display = cast(wl_display*) display;
        if (d.start() == false)
        {
            d.close();
            return null;
        }
        return d;
    }

    /// Binds the seat and its keyboard, waiting for the keymap. False on failure.
    private bool start()
    {
        context = xkb_context_new(0);
        queue = wl_display_create_queue(display);
        void* wrapper = queue is null ? null : wl_proxy_create_wrapper(display);
        if (context is null || wrapper is null)
        {
            return false;
        }
        wl_proxy* w = cast(wl_proxy*) wrapper;
        wl_proxy_set_queue(w, queue);
        registry = wl_proxy_marshal_flags(w, WL_DISPLAY_GET_REGISTRY, wl_registry_interface, wl_proxy_get_version(w),
            0, null);
        wl_proxy_wrapper_destroy(wrapper);
        if (registry is null)
        {
            return false;
        }
        wl_proxy_add_listener(registry, &registryListener, cast(void*) this);
        // Globals, then the seat's capabilities, then the keyboard's keymap.
        foreach (int i; 0 .. 3)
        {
            if (wl_display_roundtrip_queue(display, queue) < 0)
            {
                return false;
            }
        }
        return seat !is null;
    }

    /// Accent of the dead key at evdev key code `key` with the current modifiers, or null for other keys.
    string accent(uint key)
    {
        wl_display_dispatch_queue_pending(display, queue);
        if (state is null)
        {
            return null;
        }
        uint sym = xkb_state_key_get_one_sym(state, key + 8);
        return sym >= 0xfe50 && sym < 0xfe50 + accents.length ? accents[sym - 0xfe50] : null;
    }

    /// Frees the keyboard, the queue and the xkb state. Before SDL closes the connection.
    void close()
    {
        foreach (wl_proxy** p; [&keyboard, &seat, &registry])
        {
            if (*p !is null)
            {
                wl_proxy_destroy(*p);
                *p = null;
            }
        }
        if (queue !is null)
        {
            wl_event_queue_destroy(queue);
            queue = null;
        }
        setKeymap(null);
        if (context !is null)
        {
            xkb_context_unref(context);
            context = null;
        }
    }

    /// Replaces the keymap and its state, taking over `map`.
    private void setKeymap(xkb_keymap* map) nothrow @nogc
    {
        if (state !is null)
        {
            xkb_state_unref(state);
        }
        if (keymap !is null)
        {
            xkb_keymap_unref(keymap);
        }
        keymap = map;
        state = map is null ? null : xkb_state_new(map);
    }
}

/// Registry events.
private __gshared wl_registry_listener registryListener = wl_registry_listener(&onGlobal, &onGlobalRemove);
/// Seat events.
private __gshared wl_seat_listener seatListener = wl_seat_listener(&onCapabilities, &onSeatName);
/// Keyboard events.
private __gshared wl_keyboard_listener keyboardListener = wl_keyboard_listener(&onKeymap, &onEnter, &onLeave,
    &onKey, &onModifiers, &onRepeatInfo);

extern (C) nothrow @nogc:

/// Binds the first seat at version 1.
private void onGlobal(void* data, wl_proxy* registry, uint name, const(char)* iface, uint version_)
{
    DeadKeys d = cast(DeadKeys) data;
    if (d.seat is null && fromStringz(iface) == "wl_seat")
    {
        d.seat = wl_proxy_marshal_flags(registry, WL_REGISTRY_BIND, wl_seat_interface, 1, 0, name,
            wl_seat_interface.name, 1, null);
        if (d.seat !is null)
        {
            wl_proxy_add_listener(d.seat, &seatListener, data);
        }
    }
}

/// Ignored.
private void onGlobalRemove(void* data, wl_proxy* registry, uint name)
{
}

/// Gets the seat's keyboard once it has one.
private void onCapabilities(void* data, wl_proxy* seat, uint caps)
{
    DeadKeys d = cast(DeadKeys) data;
    if (d.keyboard is null && (caps & WL_SEAT_CAPABILITY_KEYBOARD) != 0)
    {
        d.keyboard = wl_proxy_marshal_flags(seat, WL_SEAT_GET_KEYBOARD, wl_keyboard_interface,
            wl_proxy_get_version(seat), 0, null);
        if (d.keyboard !is null)
        {
            wl_proxy_add_listener(d.keyboard, &keyboardListener, data);
        }
    }
}

/// Ignored.
private void onSeatName(void* data, wl_proxy* seat, const(char)* name)
{
}

/// Compiles the keymap file the compositor sent.
private void onKeymap(void* data, wl_proxy* kb, uint format, int fd, uint size)
{
    version (Posix)
    {
        DeadKeys d = cast(DeadKeys) data;
        scope (exit)
        {
            close(fd);
        }
        if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1)
        {
            return;
        }
        void* p = mmap(null, size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (p == MAP_FAILED)
        {
            return;
        }
        xkb_keymap* map = xkb_keymap_new_from_string(d.context, cast(const(char)*) p, XKB_KEYMAP_FORMAT_TEXT_V1, 0);
        munmap(p, size);
        if (map !is null)
        {
            d.setKeymap(map);
        }
    }
}

/// Ignored.
private void onEnter(void* data, wl_proxy* kb, uint serial, wl_proxy* surface, wl_array* keys)
{
}

/// Ignored.
private void onLeave(void* data, wl_proxy* kb, uint serial, wl_proxy* surface)
{
}

/// Ignored, SDL reports keys.
private void onKey(void* data, wl_proxy* kb, uint serial, uint time, uint key, uint state)
{
}

/// Follows modifiers and the layout, so Shift or AltGr pick their accent.
private void onModifiers(void* data, wl_proxy* kb, uint serial, uint depressed, uint latched, uint locked,
    uint group)
{
    DeadKeys d = cast(DeadKeys) data;
    if (d.state !is null)
    {
        xkb_state_update_mask(d.state, depressed, latched, locked, 0, 0, group);
    }
}

/// Ignored.
private void onRepeatInfo(void* data, wl_proxy* kb, int rate, int delay)
{
}
