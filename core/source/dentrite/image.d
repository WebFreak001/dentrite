/// Pictures to draw: premultiplied RGBA8 pixels in memory, which each renderer uploads when first drawn.
///
/// Files are decoded elsewhere, such as by `dentrite.sdlimage` in `dentrite:sdl3`. A renderer keeps a texture
/// per image while it is drawn and frees it some frames after it stops being drawn, so images need no disposing.
module dentrite.image;

import dentrite.geom : Size;
import std.algorithm.comparison : min;

/// Picture with a fixed size. Change pixels in place, then call `changed` and repaint what shows it.
final class Image
{
    ubyte[] pixels;         /// premultiplied R, G, B, A bytes, rows top first, no padding
    immutable int width;    /// pixels across
    immutable int height;   /// pixels down
    private uint revision_; /// bumped by `changed`

    /// Transparent image of `w` by `h` pixels.
    this(int w, int h)
    {
        assert(w >= 0 && h >= 0);
        width = w;
        height = h;
        pixels = new ubyte[cast(size_t) w * h * 4];
    }

    /// Image from straight alpha RGBA8 `rgba`, `pitch` bytes per row or 0 for packed rows.
    static Image fromStraight(const(ubyte)[] rgba, int w, int h, size_t pitch = 0)
    {
        Image img = new Image(w, h);
        size_t row = cast(size_t) w * 4;
        pitch = pitch == 0 ? row : pitch;
        assert(pitch >= row && rgba.length >= (h > 0 ? pitch * (h - 1) + row : 0));
        foreach (size_t y; 0 .. h)
        {
            const(ubyte)[] src = rgba[y * pitch .. y * pitch + row];
            ubyte[] dst = img.pixels[y * row .. (y + 1) * row];
            for (size_t i = 0; i < row; i += 4)
            {
                uint a = src[i + 3];
                dst[i] = premultiply(src[i], a);
                dst[i + 1] = premultiply(src[i + 1], a);
                dst[i + 2] = premultiply(src[i + 2], a);
                dst[i + 3] = cast(ubyte) a;
            }
        }
        return img;
    }

    /// Image from premultiplied RGBA8 `rgba`, `pitch` bytes per row or 0 for packed rows.
    static Image fromPremultiplied(const(ubyte)[] rgba, int w, int h, size_t pitch = 0)
    {
        Image img = new Image(w, h);
        size_t row = cast(size_t) w * 4;
        pitch = pitch == 0 ? row : pitch;
        assert(pitch >= row && rgba.length >= (h > 0 ? pitch * (h - 1) + row : 0));
        foreach (size_t y; 0 .. h)
        {
            img.pixels[y * row .. (y + 1) * row] = rgba[y * pitch .. y * pitch + row];
        }
        return img;
    }

    /// Size in pixels.
    Size size() const
    {
        return Size(width, height);
    }

    /// True if there is nothing to draw.
    bool empty() const
    {
        return width == 0 || height == 0;
    }

    /// Tells renderers the pixels changed, so they upload them again.
    void changed()
    {
        ++revision_;
    }

    /// Times `changed` was called, for renderers.
    uint revision() const
    {
        return revision_;
    }

    /// Sets pixel `x, y` to straight alpha `r, g, b, a`, for generated images.
    void set(int x, int y, ubyte r, ubyte g, ubyte b, ubyte a)
    {
        size_t i = (cast(size_t) y * width + x) * 4;
        pixels[i] = premultiply(r, a);
        pixels[i + 1] = premultiply(g, a);
        pixels[i + 2] = premultiply(b, a);
        pixels[i + 3] = a;
    }

    /// Copy of the pixels with straight alpha, for APIs that take it such as window icons.
    ubyte[] straight() const
    {
        ubyte[] s = new ubyte[pixels.length];
        for (size_t i = 0; i < pixels.length; i += 4)
        {
            uint a = pixels[i + 3];
            foreach (size_t c; 0 .. 3)
            {
                s[i + c] = a == 0 ? 0 : cast(ubyte) min(255, (pixels[i + c] * 255 + a / 2) / a);
            }
            s[i + 3] = cast(ubyte) a;
        }
        return s;
    }
}

/// Straight alpha becomes premultiplied and back, and pitch padding is dropped.
unittest
{
    ubyte[] rows = [255, 128, 0, 128, 9, 9, 9, 9, 10, 20, 30, 255, 9, 9, 9, 9];
    Image img = Image.fromStraight(rows, 1, 2, 8);
    assert(img.pixels == [128, 64, 0, 128, 10, 20, 30, 255]);
    Image same = Image.fromPremultiplied(rows, 1, 2, 8);
    assert(same.pixels == [255, 128, 0, 128, 10, 20, 30, 255]);
    uint r = img.revision;
    img.set(0, 0, 255, 255, 255, 0);
    img.changed();
    assert(img.pixels[0 .. 4] == [0, 0, 0, 0] && img.revision == r + 1);
    img.set(0, 1, 100, 50, 0, 128);
    assert(img.straight() == [0, 0, 0, 0, 100, 50, 0, 128]);
}

/// Channel `c` times alpha `a`, rounded.
private ubyte premultiply(uint c, uint a)
{
    return cast(ubyte)((c * a + 127) / 255);
}
