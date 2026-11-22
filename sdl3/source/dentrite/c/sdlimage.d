/// SDL3_image subset, loaded at run time so the library stays optional. Checked against SDL3_image 3.2 headers.
module dentrite.c.sdlimage;

import dentrite.c.sdl : SDL_IOStream, SDL_LoadFunction, SDL_LoadObject, SDL_SharedObject, SDL_Surface;

/// `IMG_Load`.
alias LoadFn = extern (C) SDL_Surface* function(const(char)* file) nothrow @nogc;
/// `IMG_Load_IO`.
alias LoadIOFn = extern (C) SDL_Surface* function(SDL_IOStream* src, bool closeio) nothrow @nogc;

// NOTE: D linkage on purpose, so a program that links SDL3_image itself keeps its own symbols.
extern (D):

__gshared
{
    LoadFn IMG_Load;      /// decodes a file into a new surface, null on failure
    LoadIOFn IMG_Load_IO; /// decodes a stream into a new surface, null on failure
}

version (Windows)
{
    /// Library file.
    private enum string libraryName = "SDL3_image.dll";
}
else version (OSX)
{
    /// Library file.
    private enum string libraryName = "libSDL3_image.0.dylib";
}
else
{
    /// Library file.
    private enum string libraryName = "libSDL3_image.so.0";
}

/// Loads the library from `path`, or the system's default name when null, once. False if it or a function is
/// missing. Safe from any thread.
bool loadSdlImage(const(char)* path)
{
    __gshared bool tried;
    __gshared bool loaded;
    synchronized
    {
        if (tried)
        {
            return loaded;
        }
        tried = true;
        SDL_SharedObject* lib = SDL_LoadObject(path !is null ? path : libraryName.ptr);
        if (lib is null)
        {
            return false;
        }
        IMG_Load = cast(LoadFn) SDL_LoadFunction(lib, "IMG_Load");
        IMG_Load_IO = cast(LoadIOFn) SDL_LoadFunction(lib, "IMG_Load_IO");
        loaded = IMG_Load !is null && IMG_Load_IO !is null;
        return loaded;
    }
}
