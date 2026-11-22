/// Image files decoded by SDL3_image: PNG, JPEG, WebP, BMP, GIF and the other formats its build reads.
///
/// SDL3_image is loaded at run time on first use, so programs run without it and only loading fails.
/// `DENTRITE_SDL_IMAGE` names its file if it is not on the library path. Animations give their first frame.
module dentrite.sdlimage;

import dentrite.c.sdl;
import dentrite.c.sdlimage;
import dentrite.image : Image;
import std.process : environment;
import std.string : fromStringz, toStringz;

/// True if SDL3_image is there to decode files.
bool canLoadImages()
{
    string path = environment.get("DENTRITE_SDL_IMAGE");
    return loadSdlImage(path.length > 0 ? path.toStringz : null);
}

/// Decodes the image file at `path`. Throws if SDL3_image is missing or cannot read the file.
Image loadImage(string path)
{
    needLibrary();
    return fromSurface(IMG_Load(path.toStringz), path);
}

/// Decodes the bytes of an image file, such as one brought in with `import`. Throws as `loadImage` does.
Image decodeImage(const(ubyte)[] data)
{
    needLibrary();
    SDL_IOStream* io = SDL_IOFromConstMem(data.ptr, data.length);
    if (io is null)
    {
        throw new Exception("image bytes: " ~ fromStringz(SDL_GetError()).idup);
    }
    return fromSurface(IMG_Load_IO(io, true), "image bytes");
}

/// Throws if SDL3_image cannot be loaded.
private void needLibrary()
{
    if (canLoadImages() == false)
    {
        throw new Exception("SDL3_image not found, DENTRITE_SDL_IMAGE names its file");
    }
}

/// Premultiplied copy of `s`, which is freed, or throws with SDL's error about `what` if null.
private Image fromSurface(SDL_Surface* s, string what)
{
    if (s is null)
    {
        throw new Exception(what ~ ": " ~ fromStringz(SDL_GetError()).idup);
    }
    scope (exit)
    {
        SDL_DestroySurface(s);
    }
    SDL_Surface* c = SDL_ConvertSurface(s, SDL_PIXELFORMAT_ABGR8888);
    if (c is null || SDL_LockSurface(c) == false)
    {
        string why = fromStringz(SDL_GetError()).idup;
        if (c !is null)
        {
            SDL_DestroySurface(c);
        }
        throw new Exception(what ~ ": " ~ why);
    }
    scope (exit)
    {
        SDL_UnlockSurface(c);
        SDL_DestroySurface(c);
    }
    size_t bytes = c.h > 0 ? cast(size_t) c.pitch * (c.h - 1) + cast(size_t) c.w * 4 : 0;
    return Image.fromStraight((cast(const(ubyte)*) c.pixels)[0 .. bytes], c.w, c.h, c.pitch);
}

// Without SDL3_image, loading throws and says why. With it, a PNG comes back premultiplied and bad bytes
// throw.
unittest
{
    import dentrite.png : encodePNG;
    import std.algorithm.searching : canFind;
    import std.exception : collectExceptionMsg;

    ubyte[] straight = [255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 255, 255, 255, 255];
    ubyte[] png = encodePNG(straight, 2, 2);
    if (canLoadImages() == false)
    {
        assert(collectExceptionMsg(decodeImage(png)).canFind("SDL3_image not found"));
        assert(collectExceptionMsg(loadImage("none.png")).canFind("SDL3_image not found"));
        return;
    }
    Image img = decodeImage(png);
    assert(img.width == 2 && img.height == 2);
    assert(img.pixels == Image.fromStraight(straight, 2, 2).pixels);
    assert(collectExceptionMsg(decodeImage([1, 2, 3])).length > 0);
    assert(collectExceptionMsg(loadImage("no such file.png")).canFind("no such file.png"));
}
