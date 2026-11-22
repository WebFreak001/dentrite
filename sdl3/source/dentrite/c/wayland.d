/// libwayland-client and libxkbcommon subset for reading the compositor's keymap, loaded at run time so they stay
/// optional. Checked against wayland 1.23 and xkbcommon 1.7 headers.
module dentrite.c.wayland;

import dentrite.c.sdl : SDL_LoadFunction, SDL_LoadObject, SDL_SharedObject;

extern (C) nothrow @nogc:

/// Opaque protocol object.
struct wl_proxy;
/// Opaque connection, also a proxy.
struct wl_display;
/// Opaque event queue.
struct wl_event_queue;
/// Opaque byte array.
struct wl_array;
/// Opaque xkb library context.
struct xkb_context;
/// Opaque compiled keymap.
struct xkb_keymap;
/// Opaque keyboard state.
struct xkb_state;

/// Protocol interface description. Only the name is read.
struct wl_interface
{
    const(char)* name; /// interface name, such as "wl_seat"
}

/// Events of `wl_registry`.
struct wl_registry_listener
{
    void function(void* data, wl_proxy* registry, uint name, const(char)* iface, uint version_) global; /// new global
    void function(void* data, wl_proxy* registry, uint name) globalRemove; /// global gone
}

/// Events of `wl_seat` up to version 2.
struct wl_seat_listener
{
    void function(void* data, wl_proxy* seat, uint caps) capabilities; /// devices the seat has
    void function(void* data, wl_proxy* seat, const(char)* name) name;  /// seat name
}

/// Events of `wl_keyboard` up to version 4.
struct wl_keyboard_listener
{
    void function(void* data, wl_proxy* kb, uint format, int fd, uint size) keymap; /// keymap file
    void function(void* data, wl_proxy* kb, uint serial, wl_proxy* surface, wl_array* keys) enter; /// focus in
    void function(void* data, wl_proxy* kb, uint serial, wl_proxy* surface) leave; /// focus out
    void function(void* data, wl_proxy* kb, uint serial, uint time, uint key, uint state) key; /// key change
    void function(void* data, wl_proxy* kb, uint serial, uint depressed, uint latched, uint locked,
        uint group) modifiers; /// modifier and layout change
    void function(void* data, wl_proxy* kb, int rate, int delay) repeatInfo; /// key repeat settings
}

enum uint WL_DISPLAY_GET_REGISTRY = 1;     /// wl_display request
enum uint WL_REGISTRY_BIND = 0;            /// wl_registry request
enum uint WL_SEAT_GET_KEYBOARD = 1;        /// wl_seat request
enum uint WL_SEAT_CAPABILITY_KEYBOARD = 2; /// wl_seat capability bit
enum uint WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 = 1; /// keymap format
enum uint XKB_KEYMAP_FORMAT_TEXT_V1 = 1;   /// xkb keymap format

/// Function pointer types, C calling convention.
alias MarshalFn = wl_proxy* function(wl_proxy* proxy, uint opcode, const(wl_interface)* iface, uint version_,
    uint flags, ...);
alias AddListenerFn = int function(wl_proxy* proxy, const(void)* listener, void* data); /// ditto
alias ProxyFn = void function(wl_proxy* proxy);                            /// ditto
alias VersionFn = uint function(wl_proxy* proxy);                          /// ditto
alias WrapperFn = void* function(void* proxy);                             /// ditto
alias WrapperDestroyFn = void function(void* wrapper);                     /// ditto
alias SetQueueFn = void function(wl_proxy* proxy, wl_event_queue* queue);  /// ditto
alias CreateQueueFn = wl_event_queue* function(wl_display* display);       /// ditto
alias QueueFn = void function(wl_event_queue* queue);                      /// ditto
alias DisplayQueueFn = int function(wl_display* display, wl_event_queue* queue); /// ditto
alias ContextNewFn = xkb_context* function(int flags);                     /// ditto
alias ContextUnrefFn = void function(xkb_context* ctx);                    /// ditto
alias KeymapNewFn = xkb_keymap* function(xkb_context* ctx, const(char)* s, int format, int flags); /// ditto
alias KeymapUnrefFn = void function(xkb_keymap* map);                      /// ditto
alias StateNewFn = xkb_state* function(xkb_keymap* map);                   /// ditto
alias StateUnrefFn = void function(xkb_state* state);                      /// ditto
alias UpdateMaskFn = int function(xkb_state* state, uint depressed, uint latched, uint locked,
    uint depressedLayout, uint latchedLayout, uint lockedLayout);          /// ditto
alias OneSymFn = uint function(xkb_state* state, uint key);                /// ditto

// NOTE: D linkage on purpose. C names here would interpose on libwayland's own symbols.
extern (D):

__gshared
{
    MarshalFn wl_proxy_marshal_flags;           /// sends a request, returning the new object for constructors
    AddListenerFn wl_proxy_add_listener;        /// sets event handlers
    ProxyFn wl_proxy_destroy;                   /// frees a proxy
    VersionFn wl_proxy_get_version;             /// bound version
    WrapperFn wl_proxy_create_wrapper;          /// proxy copy for another queue
    WrapperDestroyFn wl_proxy_wrapper_destroy;  /// frees a wrapper
    SetQueueFn wl_proxy_set_queue;              /// queue for a proxy's events
    CreateQueueFn wl_display_create_queue;      /// new event queue
    QueueFn wl_event_queue_destroy;             /// frees a queue
    DisplayQueueFn wl_display_roundtrip_queue;  /// waits until the compositor answered
    DisplayQueueFn wl_display_dispatch_queue_pending; /// runs events already read
    const(wl_interface)* wl_registry_interface; /// registry description
    const(wl_interface)* wl_seat_interface;     /// seat description
    const(wl_interface)* wl_keyboard_interface; /// keyboard description
    ContextNewFn xkb_context_new;               /// new context
    ContextUnrefFn xkb_context_unref;           /// frees a context
    KeymapNewFn xkb_keymap_new_from_string;     /// compiles a keymap
    KeymapUnrefFn xkb_keymap_unref;             /// frees a keymap
    StateNewFn xkb_state_new;                   /// new state for a keymap
    StateUnrefFn xkb_state_unref;               /// frees a state
    UpdateMaskFn xkb_state_update_mask;         /// sets modifiers and layout as the compositor sent them
    OneSymFn xkb_state_key_get_one_sym;         /// keysym of an xkb key code, or 0
}

/// Loads both libraries once. False if either or a symbol is missing.
bool loadWayland()
{
    static bool tried;
    static bool loaded;
    if (tried)
    {
        return loaded;
    }
    tried = true;
    SDL_SharedObject* wl = SDL_LoadObject("libwayland-client.so.0");
    SDL_SharedObject* xkb = SDL_LoadObject("libxkbcommon.so.0");
    if (wl is null || xkb is null)
    {
        return false;
    }
    loaded = bind(wl, wl_proxy_marshal_flags, "wl_proxy_marshal_flags")
        && bind(wl, wl_proxy_add_listener, "wl_proxy_add_listener")
        && bind(wl, wl_proxy_destroy, "wl_proxy_destroy")
        && bind(wl, wl_proxy_get_version, "wl_proxy_get_version")
        && bind(wl, wl_proxy_create_wrapper, "wl_proxy_create_wrapper")
        && bind(wl, wl_proxy_wrapper_destroy, "wl_proxy_wrapper_destroy")
        && bind(wl, wl_proxy_set_queue, "wl_proxy_set_queue")
        && bind(wl, wl_display_create_queue, "wl_display_create_queue")
        && bind(wl, wl_event_queue_destroy, "wl_event_queue_destroy")
        && bind(wl, wl_display_roundtrip_queue, "wl_display_roundtrip_queue")
        && bind(wl, wl_display_dispatch_queue_pending, "wl_display_dispatch_queue_pending")
        && bind(wl, wl_registry_interface, "wl_registry_interface")
        && bind(wl, wl_seat_interface, "wl_seat_interface")
        && bind(wl, wl_keyboard_interface, "wl_keyboard_interface")
        && bind(xkb, xkb_context_new, "xkb_context_new")
        && bind(xkb, xkb_context_unref, "xkb_context_unref")
        && bind(xkb, xkb_keymap_new_from_string, "xkb_keymap_new_from_string")
        && bind(xkb, xkb_keymap_unref, "xkb_keymap_unref")
        && bind(xkb, xkb_state_new, "xkb_state_new")
        && bind(xkb, xkb_state_unref, "xkb_state_unref")
        && bind(xkb, xkb_state_update_mask, "xkb_state_update_mask")
        && bind(xkb, xkb_state_key_get_one_sym, "xkb_state_key_get_one_sym");
    return loaded;
}

/// Sets `p` to symbol `name` of `lib`, false if missing.
private bool bind(T)(SDL_SharedObject* lib, ref T p, const(char)* name)
{
    p = cast(T) SDL_LoadFunction(lib, name);
    return p !is null;
}
